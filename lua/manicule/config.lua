-- manicule.nvim: configuration defaults + merge/validate.

local M = {}

---@type manicule.Config
M.defaults = {
  store = {
    -- Where to anchor the per-project store. Return a directory path or nil.
    path_resolver = function()
      return vim.fs.root(0, { ".git", ".hg", "package.json" })
    end,
    -- Filename written inside the resolved project root.
    filename = ".manicule.json",
  },
  handlers = {
    signs = { enabled = true },
    virtual_text = { enabled = false },
    float = { enabled = true },
  },
  sinks = {
    -- Named sink configurations populated by user/setup.
  },
}

---Current, merged configuration. Populated by `M.setup`.
---@type manicule.Config
M.current = vim.deepcopy(M.defaults)

---Merge user opts into defaults and run shallow validation.
---@param opts manicule.Config|nil
---@return manicule.Config
function M.setup(opts)
  opts = opts or {}
  vim.validate({
    opts = { opts, "table" },
    store = { opts.store, "table", true },
    handlers = { opts.handlers, "table", true },
    sinks = { opts.sinks, "table", true },
  })
  if opts.store then
    vim.validate({
      ["store.path_resolver"] = { opts.store.path_resolver, "function", true },
      ["store.filename"] = { opts.store.filename, "string", true },
    })
  end
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return M.current
end

return M
