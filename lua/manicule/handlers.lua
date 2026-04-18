-- manicule.nvim: pluggable display handlers.
--
-- The shape intentionally mirrors `vim.diagnostic.handlers`: each entry
-- exposes `show` / `hide` and is invoked by the render pipeline. We
-- deliberately do NOT reuse vim.diagnostic itself — comments are not
-- diagnostics and we want full control over lifecycle, filtering, and
-- per-comment affordances.

local M = {}

M.handlers = {
  signs = {
    -- TODO(manicule): place a sign (default glyph "☞") in the sign
    -- column for each anchored comment in the buffer.
    show = function(_namespace, _bufnr, _comments, _opts) end,
    hide = function(_namespace, _bufnr) end,
  },
  virtual_text = {
    -- TODO(manicule): render an eol/right_align virt_text chunk showing
    -- a truncated preview of the comment body.
    show = function(_namespace, _bufnr, _comments, _opts) end,
    hide = function(_namespace, _bufnr) end,
  },
  float = {
    -- TODO(manicule): open a floating window on demand with the full
    -- comment thread(s) at the cursor line.
    show = function(_namespace, _bufnr, _comments, _opts) end,
    hide = function(_namespace, _bufnr) end,
  },
}

return M
