-- manicule.nvim: review source resolvers.
--
-- Turn `:ManiculeReview` arguments into staged diff pairs. Registry is
-- open: register({name, match, resolve}) prepends, so user resolvers
-- shadow builtins.

local M = {}

local registry = {}

---@param resolver {name: string, match: fun(fargs: string[]): boolean, resolve: fun(fargs: string[], opts: table): table|nil, string|nil}
function M.register(resolver)
  table.insert(registry, 1, resolver)
end

local function is_dir(path)
  return path and vim.fn.isdirectory(path) == 1
end

local function read_all(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

local function list_files(dir)
  local out = {}
  local prefix = dir:gsub("/$", "") .. "/"
  for _, path in
    ipairs(vim.fs.find(function(name)
      return name ~= ".git"
    end, { path = dir, type = "file", limit = math.huge }))
  do
    out[path:sub(#prefix + 1)] = path
  end
  return out
end

-- Builtin: two existing directories.
M.register({
  name = "dirs",
  match = function(fargs)
    return #fargs == 2 and is_dir(fargs[1]) and is_dir(fargs[2])
  end,
  resolve = function(fargs)
    local left_dir, right_dir = fargs[1], fargs[2]
    local lefts = list_files(left_dir)
    local rights = list_files(right_dir)
    local files = {}
    local paths = {}
    for rel in pairs(lefts) do
      paths[rel] = true
    end
    for rel in pairs(rights) do
      paths[rel] = true
    end
    local sorted = vim.tbl_keys(paths)
    table.sort(sorted)
    for _, rel in ipairs(sorted) do
      local left, right = lefts[rel], rights[rel]
      if left and right then
        if read_all(left) ~= read_all(right) then
          table.insert(files, { left = left, right = right, status = "M", path = rel })
        end
      elseif left then
        table.insert(files, { left = left, right = right_dir .. "/" .. rel, status = "D", path = rel })
      else
        -- Right-only: stage an empty left so the diff shows all-added.
        local staged = vim.fn.tempname()
        vim.fn.writefile({}, staged)
        table.insert(files, { left = staged, right = right, status = "A", path = rel })
      end
    end
    return { files = files, label = "dirs" }
  end,
})

-- Builtin: git ref (or bare = HEAD).
M.register({
  name = "git",
  match = function(fargs)
    return #fargs <= 1
  end,
  resolve = function(fargs, opts)
    local G = require("manicule.review.git")
    local cwd = opts.cwd or (vim.uv or vim.loop).cwd()
    local root = G.root(cwd)
    if not root then
      return nil, "manicule: not a git repository and arguments are not directories"
    end
    local ref = fargs[1] or "HEAD"
    local base, err
    if ref == "HEAD" then
      base, err = G.rev_parse(root, "HEAD")
    else
      base, err = G.merge_base(root, "HEAD", ref)
    end
    if not base then
      return nil, err
    end
    local changed, cerr = G.changed_files(root, base)
    if not changed then
      return nil, cerr
    end
    if #changed == 0 then
      return nil, ("manicule: no changes vs %s"):format(ref)
    end
    local stage_dir = opts.stage_dir or vim.fn.tempname()
    vim.fn.mkdir(stage_dir, "p")
    return {
      files = G.stage_baseline(root, base, changed, stage_dir),
      label = ref,
    }
  end,
})

-- Builtin: GitHub PR via gh CLI (auth owned by gh, octo.nvim pattern).
M.register({
  name = "pr",
  match = function(fargs)
    return fargs[1] == "pr" and tonumber(fargs[2]) ~= nil
  end,
  resolve = function(fargs, opts)
    local G = require("manicule.review.git")
    if vim.fn.executable("gh") ~= 1 then
      return nil, "manicule: pr resolver requires the gh CLI (https://cli.github.com)"
    end
    local cwd = opts.cwd or (vim.uv or vim.loop).cwd()
    local root = G.root(cwd)
    if not root then
      return nil, "manicule: not a git repository"
    end
    local number = fargs[2]
    local result = G.run({ "gh", "pr", "view", number, "--json", "baseRefOid,headRefOid" }, { cwd = root })
    if result.code ~= 0 then
      return nil, ("manicule: gh pr view failed: %s"):format(vim.trim(result.stderr))
    end
    local ok, meta = pcall(vim.json.decode, result.stdout)
    if not ok or type(meta) ~= "table" or not meta.headRefOid then
      return nil, "manicule: unexpected gh pr view output"
    end
    -- Ensure both oids exist locally before diffing.
    for _, oid in ipairs({ meta.baseRefOid, meta.headRefOid }) do
      if not G.rev_parse(root, oid) then
        local fetch = G.run({ "git", "-C", root, "fetch", "-q", "origin", oid })
        if fetch.code ~= 0 then
          return nil, ("manicule: cannot fetch %s: %s"):format(oid, vim.trim(fetch.stderr))
        end
      end
    end
    local base, err = G.merge_base(root, meta.baseRefOid, meta.headRefOid)
    if not base then
      return nil, err
    end
    local stage_dir = opts.stage_dir or vim.fn.tempname()
    vim.fn.mkdir(stage_dir, "p")
    local head = G.rev_parse(root, "HEAD")
    local label = ("pr %s"):format(number)

    if head == meta.headRefOid then
      -- PR head is checked out: right side = worktree, normal pairs.
      local changed, cerr = G.changed_files(root, base)
      if not changed then
        return nil, cerr
      end
      -- changed_files compares vs worktree; for a clean checkout this
      -- equals base..head. Filter out entries with no content diff is
      -- unnecessary — git already did it.
      if #changed == 0 then
        return nil, ("manicule: no changes in %s"):format(label)
      end
      return { files = G.stage_baseline(root, base, changed, stage_dir), label = label }
    end

    -- Head not checked out: stage BOTH sides (comments land on staged
    -- right files as session-scope records; documented limitation).
    local diff = G.run({ "git", "-C", root, "diff", "--name-status", "--no-renames", base, meta.headRefOid })
    if diff.code ~= 0 then
      return nil, ("manicule: git diff failed: %s"):format(vim.trim(diff.stderr))
    end
    local files = {}
    for line in diff.stdout:gmatch("[^\n]+") do
      local status, path = line:match("^(%a)%s+(.+)$")
      if status and path then
        if status ~= "A" and status ~= "D" then
          status = "M"
        end
        local left = stage_dir .. "/base/" .. path
        local right = stage_dir .. "/head/" .. path
        for side, ref in pairs({ [left] = base, [right] = meta.headRefOid }) do
          vim.fn.mkdir(vim.fn.fnamemodify(side, ":h"), "p")
          local fd = assert(io.open(side, "wb"))
          fd:write(G.show_file(root, ref, path) or "")
          fd:close()
        end
        table.insert(files, { left = left, right = right, status = status, path = path })
      end
    end
    if #files == 0 then
      return nil, ("manicule: no changes in %s"):format(label)
    end
    return { files = files, label = label }
  end,
})

---@param fargs string[]
---@param opts? {cwd?: string, stage_dir?: string}
---@return {files: table[], label: string}|nil, string|nil err
function M.resolve(fargs, opts)
  opts = opts or {}
  for _, resolver in ipairs(registry) do
    if resolver.match(fargs) then
      return resolver.resolve(fargs, opts)
    end
  end
  return nil, ("manicule: cannot resolve review arguments: %s"):format(table.concat(fargs, " "))
end

return M
