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

---Changed files vs `base`, including untracked files as "A".
---@param root string
---@param base string
---@return {path: string, status: "M"|"A"|"D"}[]|nil, string|nil err
function M.changed_files(root, base)
  local result = git(root, "diff", "--name-status", "--no-renames", base)
  if result.code ~= 0 then
    return nil, ("manicule: git diff failed: %s"):format(trim(result.stderr))
  end
  local entries = {}
  local seen = {}
  for line in result.stdout:gmatch("[^\n]+") do
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
  local untracked = git(root, "ls-files", "--others", "--exclude-standard")
  if untracked.code == 0 then
    for path in untracked.stdout:gmatch("[^\n]+") do
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
  local files = {}
  for _, entry in ipairs(entries) do
    local left = dir .. "/" .. entry.path
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    local content = entry.status ~= "A" and M.show_file(root, base, entry.path) or nil
    local fd = assert(io.open(left, "wb"))
    fd:write(content or "")
    fd:close()
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
