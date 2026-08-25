-- manicule.nvim: git plumbing for review mode.
--
-- Thin, synchronous wrappers around `git` used to resolve baselines and
-- stage baseline file versions for diff pairs. No global state.

local M = {}

local uv = vim.uv

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

---Spawn `argv` WITHOUT waiting, so independent subprocesses can run
---concurrently; callers `:wait()` the returned handle (see M.wait for
---the normalized result). A module function, like `M.run`, so tests can
---observe subprocess fan-out. Throws when the executable is missing —
---the same loud failure `M.run` has.
---@param argv string[]
---@param opts? {cwd?: string}
---@return vim.SystemObj
function M.spawn(argv, opts)
  opts = opts or {}
  return vim.system(argv, { text = true, cwd = opts.cwd })
end

---Join a handle from `M.spawn`, normalizing the result like `M.run`.
---@param handle vim.SystemObj
---@return {code: integer, stdout: string, stderr: string}
function M.wait(handle)
  local result = handle:wait()
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

---Entries from NUL-separated `git diff --name-status -z` output
---(`STATUS\0path\0STATUS\0path\0...`). Without `-z`, core.quotePath=true
---(the default) C-quotes non-ASCII paths (`"\303\245.txt"`) and the
---quoted string would leak into entry.path, so callers MUST pass `-z`.
---Rename/copy statuses (`R<score>`/`C<score>`) carry TWO paths
---(`old\0new\0`); the destination is kept so the stream stays aligned
---even though callers pass `--no-renames` today.
---Rare statuses (T, R, C, ...) collapse into "M"; we only branch on A/D.
---@param stdout string
---@return {path: string, status: "M"|"A"|"D"}[]
function M.parse_name_status(stdout)
  local tokens = {}
  for token in (stdout or ""):gmatch("[^%z]+") do
    tokens[#tokens + 1] = token
  end
  local entries = {}
  local i = 1
  while i < #tokens do
    local status = tokens[i]:sub(1, 1)
    local path = tokens[i + 1]
    i = i + 2
    if (status == "R" or status == "C") and i <= #tokens then
      -- Two-path record: source first, then the destination.
      path = tokens[i]
      i = i + 1
    end
    if status ~= "A" and status ~= "D" then
      status = "M"
    end
    entries[#entries + 1] = { path = path, status = status }
  end
  return entries
end

---Changed files vs `base`, including untracked files as "A".
---@param root string
---@param base string
---@return {path: string, status: "M"|"A"|"D"}[]|nil, string|nil err
function M.changed_files(root, base)
  -- Run diff and status concurrently; each costs ~100ms on large repos
  -- and they are independent.
  local diff_job = vim.system(
    { "git", "-C", root, "diff", "--name-status", "--no-renames", "-z", base },
    { text = true }
  )
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
  for _, entry in ipairs(M.parse_name_status(result.stdout)) do
    if not seen[entry.path] then
      seen[entry.path] = true
      table.insert(entries, entry)
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

---mkdir -p via libuv; `known_dirs` caches directories already confirmed
---to exist so repeated calls stay cheap.
---@param path string
---@param known_dirs table<string, boolean>
local function mkdir_p(path, known_dirs)
  if known_dirs[path] then
    return
  end
  if uv.fs_stat(path) then
    known_dirs[path] = true
    return
  end
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and parent ~= path then
    mkdir_p(parent, known_dirs)
  end
  local ok, err = uv.fs_mkdir(path, 493) -- 0755, filtered by umask
  assert(ok, ("manicule: cannot create staging directory %s: %s"):format(path, tostring(err)))
  known_dirs[path] = true
end

---Write `content` to `path` as a regular file, creating parent
---directories and replacing any non-file already there (e.g. a symlink
---tar extracted from an archive).
---@param path string
---@param content string
---@param known_dirs table<string, boolean>
local function write_regular(path, content, known_dirs)
  local parent = path:match("^(.*)/[^/]+$")
  if parent then
    mkdir_p(parent, known_dirs)
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

---Materialize the blob contents of `paths` at `ref` under `dir`,
---mirroring relative paths. Batched: chunked `git archive` + `tar`
---subprocesses instead of one `git show` fork per file (numbers in
---docs/performance.md) — archives for all chunks fan out concurrently,
---extractions join them in order — with a per-file `git show` self-heal
---for anything archive missed. Paths absent at `ref` become empty regular
---files; symlink blobs become regular files holding the link target.
---Requires the `tar` executable and fails loudly when it is missing.
---@param root string
---@param ref string
---@param paths string[]
---@param dir string
function M.materialize(root, ref, paths, dir)
  local known_dirs = {}
  mkdir_p(dir, known_dirs)

  -- `git archive` has no pathspec-from-file support (including Git 2.55),
  -- so keep each argv comfortably below platform ARG_MAX instead. Bound
  -- path count too: archive's pathspec matching slows sharply with a huge
  -- flat argv even below ARG_MAX (200-path chunks benchmark faster).
  local max_argv_bytes = 64 * 1024
  local max_paths_per_chunk = 200
  local base_bytes = #root + #ref + #dir + 1024
  local chunks = {}
  local chunk = {}
  local chunk_bytes = base_bytes

  for _, path in ipairs(paths) do
    local path_bytes = #path + 1
    if #chunk > 0 and (chunk_bytes + path_bytes > max_argv_bytes or #chunk >= max_paths_per_chunk) then
      chunks[#chunks + 1] = chunk
      chunk = {}
      chunk_bytes = base_bytes
    end
    table.insert(chunk, path)
    chunk_bytes = chunk_bytes + path_bytes
  end
  if #chunk > 0 then
    chunks[#chunks + 1] = chunk
  end

  -- Chunks are independent (distinct pathspecs, distinct archive
  -- tempfiles, one shared output dir): fan out ALL `git archive`
  -- subprocesses first, then join each and extract its tar, so
  -- archives N+1.. run while tar N extracts instead of serializing
  -- archive/tar pairs. Extraction itself stays sequential — concurrent
  -- tars into one tree would race on shared parent directories.
  -- `tar` must exist: M.run throws when it is missing.
  local failed_paths = {}
  local jobs = {}
  for i, chunk_paths in ipairs(chunks) do
    local archive_path = vim.fn.tempname() .. ".tar"
    local archive_argv = {
      "git",
      "-C",
      root,
      "--literal-pathspecs",
      "archive",
      "-o",
      archive_path,
      ref,
      "--",
    }
    vim.list_extend(archive_argv, chunk_paths)
    jobs[i] = { paths = chunk_paths, archive = archive_path, handle = M.spawn(archive_argv) }
  end
  for _, job in ipairs(jobs) do
    local archive_result = M.wait(job.handle)
    local tar_result = M.run({ "tar", "-xf", job.archive, "-C", dir })
    pcall(uv.fs_unlink, job.archive)

    if archive_result.code ~= 0 or tar_result.code ~= 0 then
      for _, path in ipairs(job.paths) do
        failed_paths[path] = true
      end
    end
  end

  for _, path in ipairs(paths) do
    local staged = dir .. "/" .. path
    local stat = uv.fs_lstat(staged)
    if failed_paths[path] or not stat or stat.type ~= "file" then
      write_regular(staged, M.show_file(root, ref, path) or "", known_dirs)
    end
  end
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
  local tracked = {}
  for _, entry in ipairs(entries) do
    if entry.status ~= "A" then
      table.insert(tracked, entry.path)
    end
  end
  M.materialize(root, base, tracked, dir)

  local known_dirs = {}
  local files = {}
  for _, entry in ipairs(entries) do
    local left = dir .. "/" .. entry.path
    if entry.status == "A" then
      -- Added: stage an empty left so the diff shows all-added.
      write_regular(left, "", known_dirs)
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
