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
-- The extmark itself carries the display (sign_text + hl_group) — there
-- is no parallel render pipeline in v1. See `handlers.lua` for the v2
-- shape sketched behind stubs.
--
-- The namespace is shared across all manicule anchors in a buffer so we
-- can list/clear them in bulk.

local M = {}

---Neovim namespace used for all manicule extmarks.
M.ns = vim.api.nvim_create_namespace("manicule")

-- Default sign highlight. Linked to Comment with `default = true` so a
-- user colorscheme override wins.
vim.api.nvim_set_hl(0, "ManiculeSign", { link = "Comment", default = true })

---Create an anchor for a comment range.
---@param bufnr integer
---@param range {start: integer[], end_: integer[]}
---@return integer mark_id
function M.create(bufnr, range)
  local start_row, start_col = range.start[1], range.start[2] or 0
  local end_row, end_col = range.end_[1], range.end_[2] or 0
  return vim.api.nvim_buf_set_extmark(bufnr, M.ns, start_row, start_col, {
    end_row = end_row,
    end_col = end_col,
    invalidate = true,
    undo_restore = false,
    sign_text = "☞",
    sign_hl_group = "ManiculeSign",
    hl_mode = "combine",
  })
end

---Resolve an anchor back to a live range.
---@param bufnr integer
---@param mark_id integer
---@return {range: {start: integer[], end_: integer[]}, invalid: boolean}|nil
function M.resolve(bufnr, mark_id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, mark_id, { details = true })
  if not pos or #pos == 0 then
    return nil
  end
  local row, col, details = pos[1], pos[2], pos[3] or {}
  return {
    range = {
      start = { row, col },
      end_ = { details.end_row or row, details.end_col or col },
    },
    invalid = details.invalid == true,
  }
end

---Delete an anchor.
---@param bufnr integer
---@param mark_id integer
function M.delete(bufnr, mark_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, mark_id)
end

return M
