-- manicule.nvim: configuration defaults + merge/validate.

local M = {}

---@class manicule.UIConfig
---@field width integer Floating editor width (columns)
---@field height integer Floating editor height (lines)
---@field editor_mode "insert"|"normal" Initial editor mode
---@field submit_keys string[] Keys that submit the editor
---@field cancel_keys string[] Keys that cancel the editor
---@field opacity integer winblend (0 = opaque, 100 = fully transparent)

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
  -- Floating editor UI options. Mirrors the codediff.nvim surface.
  ui = {
    width = 72,
    height = 6,
    editor_mode = "insert",
    submit_keys = { "<CR>" },
    cancel_keys = { "q" },
    opacity = 0,
  },
}

---Current, merged configuration. Populated by `M.setup`.
---@type manicule.Config
M.current = vim.deepcopy(M.defaults)

---Return the current config (read-only by convention).
---@return manicule.Config
function M.get()
  return M.current
end

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
    ui = { opts.ui, "table", true },
  })
  if opts.store then
    vim.validate({
      ["store.path_resolver"] = { opts.store.path_resolver, "function", true },
      ["store.filename"] = { opts.store.filename, "string", true },
    })
  end
  if opts.ui then
    vim.validate({
      ["ui.width"] = { opts.ui.width, "number", true },
      ["ui.height"] = { opts.ui.height, "number", true },
      ["ui.editor_mode"] = { opts.ui.editor_mode, "string", true },
      ["ui.submit_keys"] = { opts.ui.submit_keys, "table", true },
      ["ui.cancel_keys"] = { opts.ui.cancel_keys, "table", true },
      ["ui.opacity"] = { opts.ui.opacity, "number", true },
    })
  end
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- tbl_deep_extend merges tables but we want user key-lists to *replace*,
  -- not merge, the defaults. Otherwise a user-supplied `submit_keys = {"<C-s>"}`
  -- would stack on top of the default `{"<CR>"}`.
  if opts.ui then
    if opts.ui.submit_keys ~= nil then
      M.current.ui.submit_keys = opts.ui.submit_keys
    end
    if opts.ui.cancel_keys ~= nil then
      M.current.ui.cancel_keys = opts.ui.cancel_keys
    end
  end
  return M.current
end

return M
