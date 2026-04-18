-- manicule.nvim: pluggable display handlers (v2 surface).
--
-- In v1 the extmark itself carries the display — sign_text + highlight
-- are set at `anchor.create` time and there is no parallel render
-- pipeline. This module is intentionally left as a stub so the shape of
-- the v2 extension point is visible to readers and future contributors.
--
-- TODO(manicule): v2 — wire `signs` / `virtual_text` / `float` handlers
-- into a render pass invoked on buffer attach and on `ManiculeAdded` /
-- `ManiculeEdited` / `ManiculeResolved`. The shape intentionally mirrors
-- `vim.diagnostic.handlers`: each entry exposes `show` / `hide`. We
-- deliberately do NOT reuse vim.diagnostic — comments are not
-- diagnostics and we want full control over lifecycle and filtering.

local M = {}

M.handlers = {
  signs = {
    show = function(_namespace, _bufnr, _comments, _opts) end,
    hide = function(_namespace, _bufnr) end,
  },
  virtual_text = {
    show = function(_namespace, _bufnr, _comments, _opts) end,
    hide = function(_namespace, _bufnr) end,
  },
  float = {
    show = function(_namespace, _bufnr, _comments, _opts) end,
    hide = function(_namespace, _bufnr) end,
  },
}

return M
