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
