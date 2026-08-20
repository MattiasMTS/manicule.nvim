-- manicule.nvim: configuration defaults + merge/validate.

local M = {}

---@alias manicule.SinkPicker fun(choices: manicule.SinkChoice[], opts: table, cb: function)

---@class manicule.UIConfig
---@field width integer Floating editor width (columns)
---@field height integer Floating editor height (lines)
---@field editor_mode "insert"|"normal" Initial editor mode
---@field submit_keys string[] Keys that submit the editor
---@field cancel_keys string[] Keys that cancel the editor
---@field opacity number Floating-window transparency (0.0 = opaque, 1.0 = fully transparent)
---@field sticky boolean Always render comment popups vs only when the line is in the viewport
---@field display "float"|"eol"|"inline"|"hidden" Startup comment display mode. "float" anchored popups, "eol" end-of-line virtual text expanding to the popup on the cursor line, "inline" bordered virtual-line boxes below commented lines (code pushed down, never covered), "hidden" anchors only. Runtime changes via `:ManiculeDisplay`.
---@field sink_picker? manicule.SinkPicker Custom picker for choosing a send sink

---@class manicule.StoreConfig
---@field dir string Directory where per-root store files live.
---@field format "mpack"|"json" Session store format.
---@field branch boolean Scope the filename by the current git branch (main/master skipped).
---@field persist_unrooted boolean When true (default), unrooted file buffers route into the session store.
---@field canonicalize_symlinks boolean Resolve symlinks via `fs_realpath` before encoding URIs.
---@field root_markers string[] Markers passed to `vim.fs.root`.
---@field poll_interval_ms integer Milliseconds between local SQLite sync polls. Set <= 0 to disable.

---@class manicule.ReviewConfig
---@field mode "split"|"unified" Diff rendering for `:ManiculeReview`. "split" opens a side-by-side `:diffsplit` pair; "unified" paints the diff inline on the worktree buffer.
---@field fold_unchanged boolean Unified mode only: collapse unchanged regions into folds.
---@field context integer Unified mode only: lines of context kept around each hunk (and the fold's minimum size).

---@class manicule.SinksConfig
---@field clipboard boolean|table Enable the bundled clipboard sink (default true).
---@field cmux boolean|table Enable the bundled cmux integration (defaults to `{ enabled = true }`). Built-in text sinks accept optional `pre_text` and `post_text` strings. cmux also accepts `auto_submit` and `submit_delay_ms`.
---@field github boolean|table Enable the bundled GitHub PR review sink (default true; registers only when `gh` is executable). Accepts `event` ("COMMENT"|"REQUEST_CHANGES"|"APPROVE"), `clear_on_success`, and `pre_text`.
---@field socket boolean|table Enable the bundled socket sink (default true). Accepts `ack_timeout_ms`.

---@type manicule.Config
M.defaults = {
  store = {
    -- Per-user state dir — out of the project tree, dedicated subdir.
    dir = vim.fn.stdpath("state") .. "/manicule/",
    -- "mpack" | "json". mpack is smaller/faster and tolerates Lua
    -- nil/array quirks. Used by the session store.
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
    -- SQLite-backed project stores are polled for external events from
    -- other Neovim sessions. Polling is intentionally boring and local.
    poll_interval_ms = 750,
  },
  sinks = {
    -- `clipboard = false` disables the generic clipboard sink.
    -- `cmux.enabled = false` disables the bundled cmux integration.
    -- When enabled, cmux registers only when the integration is available.
  },
  -- Review session (`:ManiculeReview`) rendering.
  review = {
    -- "split"   — side-by-side `:diffsplit`: read-only baseline left,
    --             worktree file right (comments go on the right).
    -- "unified" — one window showing the worktree file with the diff
    --             painted on: added lines highlighted, removed lines
    --             drawn as virtual text where they used to sit. The
    --             buffer IS the file, so comments anchor natively; the
    --             cost is that removed lines are not commentable
    --             (same as the read-only baseline side in split mode).
    mode = "split",
    -- Unified mode: collapse everything outside a hunk into a fold.
    fold_unchanged = true,
    -- Unified mode: context lines kept around each hunk.
    context = 3,
  },
  -- Floating editor + popup UI options.
  ui = {
    width = 72,
    height = 6,
    editor_mode = "insert",
    submit_keys = { "<CR>" },
    cancel_keys = { "q" },
    opacity = 0.0,
    sticky = false, -- true = always show popups for visible records; false = only when in viewport
    -- How comment records paint: "float" anchored popups, "eol"
    -- end-of-line virtual text that expands to the full popup while the
    -- cursor is on the line, "inline" bordered virtual-line boxes below
    -- commented lines (code pushed down, never covered), "hidden"
    -- anchors/line-number tint only. "eol" is the default because floats
    -- cover code on long lines; this is only the startup mode — cycle
    -- live with `:ManiculeDisplay`.
    display = "eol",
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
    review = { opts.review, "table", true },
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
      ["store.poll_interval_ms"] = { opts.store.poll_interval_ms, "number", true },
    })
    if opts.store.format ~= nil and opts.store.format ~= "mpack" and opts.store.format ~= "json" then
      error(('manicule: store.format must be "mpack" or "json", got %q'):format(tostring(opts.store.format)))
    end
  end
  if opts.sinks then
    vim.validate({
      -- Both sinks may be a boolean (enable/disable) or a table of sink
      -- options; allow both forms.
      ["sinks.clipboard"] = { opts.sinks.clipboard, { "boolean", "table" }, true },
      ["sinks.cmux"] = { opts.sinks.cmux, { "boolean", "table" }, true },
      ["sinks.github"] = { opts.sinks.github, { "boolean", "table" }, true },
      ["sinks.socket"] = { opts.sinks.socket, { "boolean", "table" }, true },
    })
  end
  if opts.review then
    vim.validate({
      ["review.mode"] = { opts.review.mode, "string", true },
      ["review.fold_unchanged"] = { opts.review.fold_unchanged, "boolean", true },
      ["review.context"] = { opts.review.context, "number", true },
    })
    if opts.review.mode ~= nil and opts.review.mode ~= "split" and opts.review.mode ~= "unified" then
      error(('manicule: review.mode must be "split" or "unified", got %q'):format(tostring(opts.review.mode)))
    end
    local context = opts.review.context
    if context ~= nil and (context ~= context or context < 0 or context ~= math.floor(context)) then
      error(("manicule: review.context must be a non-negative integer, got %s"):format(tostring(context)))
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
      ["ui.display"] = { opts.ui.display, "string", true },
      ["ui.sink_picker"] = { opts.ui.sink_picker, "function", true },
    })
    local opacity = opts.ui.opacity
    if opacity ~= nil and (opacity ~= opacity or opacity < 0 or opacity > 1) then
      error(("manicule: ui.opacity must be between 0.0 and 1.0, got %s"):format(tostring(opacity)))
    end
    local display = opts.ui.display
    if display ~= nil and display ~= "float" and display ~= "eol" and display ~= "inline" and display ~= "hidden" then
      error(('manicule: ui.display must be "float", "eol", "inline", or "hidden", got %q'):format(tostring(display)))
    end
  end
  -- `tbl_deep_extend("force", …)` replaces list/array values wholesale
  -- rather than concatenating them, so a user-supplied `submit_keys`,
  -- `cancel_keys`, or `root_markers` fully *replaces* the defaults — which
  -- is the behaviour users expect for key-lists and root markers.
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)

  -- Ensure the state dir exists once at setup so later saves don't race
  -- the mkdir and `:echo stdpath('state').'/manicule/'` resolves to a real
  -- directory even before the user adds a comment.
  vim.fn.mkdir(M.current.store.dir, "p")

  return M.current
end

return M
