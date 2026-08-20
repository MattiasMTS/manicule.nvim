-- manicule.nvim: git plumbing for review mode.
--
-- Thin, synchronous wrappers around `git` used to resolve baselines and
-- stage baseline file versions for diff pairs. No global state.

local M = {}

---@param argv string[]
---@param opts? {cwd?: string}
---@return {code: integer, stdout: string, stderr: string}
function M.run(argv, opts)
  opts = opts or {}
  local result = vim.system(argv, { text = true, cwd = opts.cwd }):wait()
  return {
    code = result.code or -1,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

local function git(root, ...)
  return M.run({ "git", "-C", root, ... })
end

local function trim(s)
  return (tostring(s or ""):gsub("%s+$", ""))
end

---@param dir string
---@return string|nil
function M.root(dir)
  local result = M.run({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if result.code ~= 0 then
    return nil
  end
  return trim(result.stdout)
end

---@param root string
---@param ref string
---@return string|nil sha, string|nil err
function M.rev_parse(root, ref)
  local result = git(root, "rev-parse", "--verify", ref .. "^{commit}")
  if result.code ~= 0 then
    return nil, ("manicule: cannot resolve ref %q: %s"):format(ref, trim(result.stderr))
  end
  return trim(result.stdout), nil
end

---@param root string
---@param a string
---@param b string
---@return string|nil sha, string|nil err
function M.merge_base(root, a, b)
  local result = git(root, "merge-base", a, b)
  if result.code ~= 0 then
    return nil, ("manicule: merge-base %s %s failed: %s"):format(a, b, trim(result.stderr))
  end
  return trim(result.stdout), nil
end

---Untracked paths from NUL-separated `git status --porcelain=v1 -z`
---output. Preferred over `ls-files --others`: status uses the untracked
---cache and fsmonitor, ls-files always walks the worktree (~3x slower on
---large repos). Status collapses fully-untracked directories to `dir/`;
---those are expanded with a *scoped* ls-files, which is cheap because it
---only walks the collapsed directory.
---@param root string
---@param stdout string
---@return string[] paths
local function untracked_from_status(root, stdout)
  local paths = {}
  local collapsed = {}
  for record in stdout:gmatch("[^%z]+") do
    local path = record:match("^%?%? (.+)$")
    if path then
      if path:sub(-1) == "/" then
        table.insert(collapsed, path)
      else
        table.insert(paths, path)
      end
    end
  end
  -- Expand ALL collapsed directories with one scoped ls-files call; the
  -- walk only descends into those directories, and one subprocess stays
  -- cheap regardless of how many directories collapsed.
  if #collapsed > 0 then
    local argv = { "ls-files", "--others", "--exclude-standard", "--" }
    vim.list_extend(argv, collapsed)
    local expanded = git(root, unpack(argv))
    if expanded.code == 0 then
      for sub in expanded.stdout:gmatch("[^\n]+") do
        table.insert(paths, sub)
      end
    end
  end
  return paths
end

---Changed files vs `base`, including untracked files as "A".
---@param root string
---@param base string
---@return {path: string, status: "M"|"A"|"D"}[]|nil, string|nil err
function M.changed_files(root, base)
  -- Run diff and status concurrently; each costs ~100ms on large repos
  -- and they are independent.
  local diff_job = vim.system({ "git", "-C", root, "diff", "--name-status", "--no-renames", base }, { text = true })
  local status_job = vim.system(
    { "git", "-C", root, "status", "--porcelain=v1", "-z", "--no-renames" },
    { text = true }
  )
  local result = diff_job:wait()
  local untracked = status_job:wait()
  if result.code ~= 0 then
    return nil, ("manicule: git diff failed: %s"):format(trim(result.stderr or ""))
  end
  local entries = {}
  local seen = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    local status, path = line:match("^(%a)%s+(.+)$")
    if status and path and not seen[path] then
      seen[path] = true
      -- Collapse rare statuses (T, etc.) into "M"; we only branch on A/D.
      if status ~= "A" and status ~= "D" then
        status = "M"
      end
      table.insert(entries, { path = path, status = status })
    end
  end
  if untracked.code == 0 then
    for _, path in ipairs(untracked_from_status(root, untracked.stdout or "")) do
      if not seen[path] then
        seen[path] = true
        table.insert(entries, { path = path, status = "A" })
      end
    end
  end
  table.sort(entries, function(x, y)
    return x.path < y.path
  end)
  return entries, nil
end

---@param root string
---@param ref string
---@param path string
---@return string|nil content
function M.show_file(root, ref, path)
  local result = git(root, "show", ref .. ":" .. path)
  if result.code ~= 0 then
    return nil
  end
  return result.stdout
end

---Write baseline versions of `entries` under `dir`, mirroring relative
---paths. Returns diff pairs; `right` always names the worktree path even
---when the file was deleted (callers branch on `status == "D"`).
---@param root string
---@param base string
---@param entries {path: string, status: string}[]
---@param dir string
---@return {left: string, right: string, status: string, path: string}[]
function M.stage_baseline(root, base, entries, dir)
  local uv = vim.uv or vim.loop
  local known_dirs = {}
  local function mkdir_p(path)
    if known_dirs[path] then
      return
    end
    if uv.fs_stat(path) then
      known_dirs[path] = true
      return
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
      mkdir_p(parent)
    end
    local ok, err = uv.fs_mkdir(path, 493) -- 0755, filtered by umask
    assert(ok, ("manicule: cannot create staging directory %s: %s"):format(path, tostring(err)))
    known_dirs[path] = true
  end
  mkdir_p(dir)

  -- `git archive` has no pathspec-from-file support (including Git 2.55),
  -- so keep each argv comfortably below platform ARG_MAX instead. Bound
  -- path count too: archive's pathspec matching slows sharply with a huge
  -- flat argv even below ARG_MAX (200-path chunks benchmark faster).
  local max_argv_bytes = 64 * 1024
  local max_paths_per_chunk = 200
  local chunk = {}
  local chunk_bytes = #root + #base + #dir + 1024
  local failed_paths = {}

  local function extract(paths)
    if #paths == 0 then
      return
    end
    local archive_path = vim.fn.tempname() .. ".tar"
    local archive_argv = {
      "git",
      "-C",
      root,
      "--literal-pathspecs",
      "archive",
      "-o",
      archive_path,
      base,
      "--",
    }
    vim.list_extend(archive_argv, paths)
    local archive_result = M.run(archive_argv)
    local tar_result = M.run({ "tar", "-xf", archive_path, "-C", dir })
    pcall(uv.fs_unlink, archive_path)

    if archive_result.code ~= 0 or tar_result.code ~= 0 then
      for _, path in ipairs(paths) do
        failed_paths[path] = true
      end
    end
  end

  for _, entry in ipairs(entries) do
    if entry.status ~= "A" then
      local path_bytes = #entry.path + 1
      if #chunk > 0 and (chunk_bytes + path_bytes > max_argv_bytes or #chunk >= max_paths_per_chunk) then
        extract(chunk)
        chunk = {}
        chunk_bytes = #root + #base + #dir + 1024
      end
      table.insert(chunk, entry.path)
      chunk_bytes = chunk_bytes + path_bytes
    end
  end
  extract(chunk)

  local function write_regular(path, content)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then
      mkdir_p(parent)
    end
    local stat = uv.fs_lstat(path)
    if stat and stat.type ~= "file" then
      local ok, err = uv.fs_unlink(path)
      assert(ok, ("manicule: cannot replace staged baseline %s: %s"):format(path, tostring(err)))
    end
    local fd, err = uv.fs_open(path, "w", 438) -- 0666, filtered by umask
    assert(fd, ("manicule: cannot stage baseline %s: %s"):format(path, tostring(err)))
    local _, write_err = uv.fs_write(fd, content, 0)
    uv.fs_close(fd)
    assert(not write_err, ("manicule: cannot write staged baseline %s: %s"):format(path, tostring(write_err)))
  end

  local files = {}
  for _, entry in ipairs(entries) do
    local left = dir .. "/" .. entry.path
    if entry.status == "A" then
      write_regular(left, "")
    else
      local stat = uv.fs_lstat(left)
      if failed_paths[entry.path] or not stat or stat.type ~= "file" then
        write_regular(left, M.show_file(root, base, entry.path) or "")
      end
    end
    table.insert(files, {
      left = left,
      right = root .. "/" .. entry.path,
      status = entry.status,
      path = entry.path,
    })
  end
  return files
end

return M
