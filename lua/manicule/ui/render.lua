-- manicule.nvim: inline comment rendering.
--
-- Ported (and trimmed) from codediff.nvim's `ui/comments/render.lua`.
-- Responsibilities:
--   * Paint a short virtual-text preview ("☞ body…") on the anchor line.
--   * Cooperate with the shared extmark namespace owned by `anchor.lua`,
--     so the sign column and preview belong to the same namespace and
--     are cleared as a pair.
--
-- manicule's `anchor.create` already owns the sign column text. Render
-- adds a virtual-text extmark that sits alongside it. We store the
-- virtual-text extmark id in a per-buffer / per-record table so edits
-- and deletes can refresh or tear it down without touching other marks.
--
-- This module intentionally does NOT know about tabpages, sessions, or
-- diff sides — those were codediff-specific concepts.

local M = {}

local anchor = require("manicule.anchor")

-- Per-buffer virtual-text extmark ids: vt_marks[bufnr][record.id] = extmark_id.
---@type table<integer, table<string, integer>>
local vt_marks = {}

local MAX_PREVIEW = 60

---@param text string
---@param max_width integer
---@return string
local function truncate_text(text, max_width)
  if #text <= max_width then
    return text
  end
  if max_width <= 3 then
    return text:sub(1, max_width)
  end
  return text:sub(1, max_width - 3) .. "..."
end

---@param body string|nil
---@return string
local function preview_text(body)
  local first = vim.split(body or "", "\n", { plain = true })[1] or ""
  first = first:gsub("^%s+", "")
  if first == "" then
    return ""
  end
  return " ☞ " .. truncate_text(first, MAX_PREVIEW)
end

---@param bufnr integer
local function ensure_table(bufnr)
  if not vt_marks[bufnr] then
    vt_marks[bufnr] = {}
  end
  return vt_marks[bufnr]
end

---Setup default highlight group. Idempotent.
local function ensure_highlights()
  vim.api.nvim_set_hl(0, "ManiculeVirt", { link = "Comment", default = true })
end

---Apply the virtual-text extmark for a single record.
---@param bufnr integer
---@param record table
local function render_one(bufnr, record)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not record or not record.range or not record.range.start then
    return
  end
  ensure_highlights()

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = record.range.start[1] or 0
  row = math.max(0, math.min(row, math.max(0, line_count - 1)))

  local text = preview_text(record.body)
  if text == "" then
    return
  end

  local tab = ensure_table(bufnr)
  local existing = tab[record.id]

  local opts = {
    virt_text = { { text, "ManiculeVirt" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
    priority = 200,
  }
  if existing then
    opts.id = existing
  end

  local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, anchor.ns, row, 0, opts)
  if ok and mark_id then
    tab[record.id] = mark_id
  end
end

--- Render virtual-text previews for every record bound to `bufnr`.
--- Called after `store.load` in the buffer-attach autocmd.
---@param bufnr integer
---@param records table[]
function M.attach_all(bufnr, records)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, r in ipairs(records or {}) do
    render_one(bufnr, r)
  end
end

--- Render (or re-render) the preview for a single record.
---@param bufnr integer
---@param record table
function M.attach_one(bufnr, record)
  render_one(bufnr, record)
end

--- Refresh an existing record's preview in place (alias for attach_one).
---@param bufnr integer
---@param record table
function M.refresh_one(bufnr, record)
  render_one(bufnr, record)
end

--- Remove the virtual-text preview for `id` (no-op if absent).
---@param bufnr integer
---@param id string
function M.detach(bufnr, id)
  local tab = vt_marks[bufnr]
  if not tab then
    return
  end
  local mark_id = tab[id]
  if not mark_id then
    return
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, anchor.ns, mark_id)
  end
  tab[id] = nil
end

--- Clear all previews we own in `bufnr`.
---@param bufnr integer
function M.clear_buffer(bufnr)
  local tab = vt_marks[bufnr]
  if not tab then
    return
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    for _, mark_id in pairs(tab) do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, anchor.ns, mark_id)
    end
  end
  vt_marks[bufnr] = nil
end

--- Internal: reset all state. Used by tests.
function M._reset_for_tests()
  vt_marks = {}
end

return M
