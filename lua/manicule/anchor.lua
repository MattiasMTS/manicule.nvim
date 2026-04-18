-- manicule.nvim: buffer anchoring via extmarks.
--
-- Strategy
-- --------
-- Each comment is pinned to a buffer range with an extmark. We rely on
-- Neovim's `invalidate = true` option so that the extmark is flagged as
-- invalid when its anchor lines are deleted, allowing us to surface
-- "orphaned" comments without losing them. `undo_restore = false` keeps
-- invalidation stable across undo.
--
-- Reference call (see `:help nvim_buf_set_extmark`):
--
--   vim.api.nvim_buf_set_extmark(bufnr, ns, start_row, start_col, {
--     end_row = end_row,
--     end_col = end_col,
--     invalidate = true,
--     undo_restore = false,
--     sign_text = "☞",
--   })
--
-- The namespace is shared across all manicule anchors in a buffer so we
-- can list/clear them in bulk.

local M = {}

---Neovim namespace used for all manicule extmarks.
M.ns = vim.api.nvim_create_namespace("manicule")

---Create an anchor for a comment range.
---@param bufnr integer
---@param range {start: integer[], end_: integer[]}
---@return integer mark_id
function M.create(bufnr, range)
  -- TODO(manicule): call nvim_buf_set_extmark with invalidate=true and
  -- return the mark id so the store can persist it alongside the record.
  local _, _ = bufnr, range
  error("TODO(manicule): anchor.create not implemented")
end

---Resolve an anchor back to a live range.
---@param bufnr integer
---@param mark_id integer
---@return {range: table, invalid: boolean}
function M.resolve(bufnr, mark_id)
  -- TODO(manicule): call nvim_buf_get_extmark_by_id with details=true,
  -- translate to {start={row,col}, end_={row,col}}, and propagate the
  -- `invalid` flag so orphaned comments can be surfaced to the user.
  local _, _ = bufnr, mark_id
  error("TODO(manicule): anchor.resolve not implemented")
end

---Delete an anchor.
---@param bufnr integer
---@param mark_id integer
function M.delete(bufnr, mark_id)
  -- TODO(manicule): nvim_buf_del_extmark(bufnr, M.ns, mark_id).
  local _, _ = bufnr, mark_id
  error("TODO(manicule): anchor.delete not implemented")
end

return M
