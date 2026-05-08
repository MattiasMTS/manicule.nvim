-- manicule.nvim: configuration defaults + merge/validate.

local M = {}

---@alias manicule.SinkPicker fun(choices: manicule.SinkChoice[], opts: table, cb: function)

---@class manicule.UIConfig
---@field width integer Floating editor width (columns)
---@field height integer Floating editor height (lines)
---@field editor_mode "insert"|"normal" Initial editor mode
---@field submit_keys string[] Keys that submit the editor
---@field cancel_keys string[] Keys that cancel the editor
---@field opacity integer winblend (0 = opaque, 100 = fully transparent)
---@field sticky boolean Always render comment popups vs only when the line is in the viewport
---@field sink_picker? manicule.SinkPicker Custom picker for choosing a send sink

---@class manicule.StoreConfig
---@field dir string Directory where per-root store files live.
---@field format "mpack"|"json" On-disk format.
---@field branch boolean Scope the filename by the current git branch (main/master skipped).
---@field persist_unrooted boolean When true (default), unrooted file buffers route into the session store.
---@field canonicalize_symlinks boolean Resolve symlinks via `fs_realpath` before encoding URIs.
---@field root_markers string[] Markers passed to `vim.fs.root`.

---@class manicule.SinksConfig
---@field clipboard boolean|table Enable the bundled clipboard sink (default true).
---@field cmux boolean|"auto"|table Enable the bundled cmux integration ("auto" by default).

---@type manicule.Config
M.defaults = {
  store = {
    -- Per-user state dir — out of the project tree, dedicated subdir.
    dir = vim.fn.stdpath("state") .. "/manicule/",
    -- "mpack" | "json". mpack is smaller/faster and tolerates Lua
    -- nil/array quirks; nothing human-inspects these files anyway.
    format = "mpack",
    -- Annotations should stay visible across branches by default; manicule
    -- stores notes the user wants anchored, not editing state.
    branch = false,
    -- When true (default), unrooted file buffers and special buftypes
    -- (terminal, help, scratch, …) route into the session-scoped
    -- store. Set to false to reject adds outside a project with a
    -- notify.
    persist_unrooted = true,
    -- Resolve symlinks through `fs_realpath` before encoding URIs so a
    -- file accessed via a symlink still matches records saved against
    -- the real path. Disable if you want URIs to reflect the access
    -- path instead.
    canonicalize_symlinks = true,
    -- Markers passed to `vim.fs.root` when resolving the project key.
    root_markers = { ".git", ".hg", "package.json" },
  },
  sinks = {
    -- `clipboard = false` disables the generic clipboard sink.
    -- `cmux = true` forces the cmux integration into the picker.
    -- `cmux = "auto"` (default) registers it only inside cmux.
  },
  -- Floating editor + popup UI options.
  ui = {
    width = 72,
    height = 6,
    editor_mode = "insert",
    submit_keys = { "<CR>" },
    cancel_keys = { "q" },
    opacity = 0,
    sticky = false, -- true = always show popups for visible records; false = only when in viewport
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
    sinks = { opts.sinks, "table", true },
    ui = { opts.ui, "table", true },
  })
  if opts.store then
    vim.validate({
      ["store.dir"] = { opts.store.dir, "string", true },
      ["store.format"] = { opts.store.format, "string", true },
      ["store.branch"] = { opts.store.branch, "boolean", true },
      ["store.persist_unrooted"] = { opts.store.persist_unrooted, "boolean", true },
      ["store.canonicalize_symlinks"] = { opts.store.canonicalize_symlinks, "boolean", true },
      ["store.root_markers"] = { opts.store.root_markers, "table", true },
    })
    if opts.store.format ~= nil and opts.store.format ~= "mpack" and opts.store.format ~= "json" then
      error(('manicule: store.format must be "mpack" or "json", got %q'):format(tostring(opts.store.format)))
    end
  end
  if opts.ui then
    vim.validate({
      ["ui.width"] = { opts.ui.width, "number", true },
      ["ui.height"] = { opts.ui.height, "number", true },
      ["ui.editor_mode"] = { opts.ui.editor_mode, "string", true },
      ["ui.submit_keys"] = { opts.ui.submit_keys, "table", true },
      ["ui.cancel_keys"] = { opts.ui.cancel_keys, "table", true },
      ["ui.opacity"] = { opts.ui.opacity, "number", true },
      ["ui.sticky"] = { opts.ui.sticky, "boolean", true },
      ["ui.sink_picker"] = { opts.ui.sink_picker, "function", true },
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
  if opts.store and opts.store.root_markers ~= nil then
    M.current.store.root_markers = opts.store.root_markers
  end

  -- Ensure the state dir exists once at setup so later saves don't race
  -- the mkdir and `:echo stdpath('state').'/manicule/'` resolves to a real
  -- directory even before the user adds a comment.
  vim.fn.mkdir(M.current.store.dir, "p")

  return M.current
end

return M
