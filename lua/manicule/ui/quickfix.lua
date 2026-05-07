-- manicule.nvim: quickfix formatter for comment records.
--
-- Ported from codediff.nvim's `ui/comments/quickfix.lua`. Adapted to
-- manicule's record shape (no `side`, `id` is a string, range carries
-- row/col pairs). Grouping follows codediff: sort by path, then by
-- start line, then by id so order is stable across reloads.
--
-- Live refresh
-- ------------
-- `M.show` records the filter used to produce the current list in a
-- module-local `state` table. `M.refresh` re-queries the store with the
-- same filter and replaces the current quickfix list in place (mode
-- `"r"`), keeping the quickfix window open and the cursor on the same
-- line number. `init.lua` subscribes to `User Manicule*` autocmds and
-- calls `M.refresh` so mutations made from any surface (floating
-- editor, keymaps, API) surface in the open qf list without flicker.

local M = {}

---@class manicule.ui.quickfix.State
---@field root string|nil
---@field filter table|nil
---@field title_prefix string

---@type manicule.ui.quickfix.State
local state = {
  root = nil,
  filter = nil,
  title_prefix = "manicule",
}

---@param record table
---@return integer
local function start_line(record)
  if record and record.range and record.range.start then
    return (record.range.start[1] or 0) + 1
  end
  return 1
end

---@param record table
---@return integer
local function start_col(record)
  if record and record.range and record.range.start then
    return (record.range.start[2] or 0) + 1
  end
  return 1
end

---@param record table
---@return integer?
local function end_line(record)
  if record and record.range and record.range.end_ then
    local row = record.range.end_[1]
    if type(row) == "number" then
      return row + 1
    end
  end
  return nil
end

---@param records table[]
---@return table[]
local function sort_records(records)
  local ordered = vim.deepcopy(records)
  table.sort(ordered, function(a, b)
    local ap = tostring(a.uri or "")
    local bp = tostring(b.uri or "")
    if ap ~= bp then
      return ap < bp
    end
    local al = start_line(a)
    local bl = start_line(b)
    if al ~= bl then
      return al < bl
    end
    return tostring(a.id or "") < tostring(b.id or "")
  end)
  return ordered
end

---Resolve a record's URI back to an absolute filesystem path for the
---quickfix `filename` slot (so `:cc <n>` / `<CR>` navigation jumps to
---the right file). Returns nil for non-file URIs so the caller can
---fall back to `bufnr`.
---@param record table
---@return string?
local function filename_for(record)
  return require("manicule.uri").to_path(record.uri)
end

---@param text string
---@param max_width integer
---@return string
local function truncate(text, max_width)
  if #text <= max_width then
    return text
  end
  if max_width <= 3 then
    return text:sub(1, max_width)
  end
  return text:sub(1, max_width - 3) .. "..."
end

---@param record table
---@return string
local function format_text(record)
  local body = record.body or ""
  local first = vim.split(body, "\n", { plain = true })[1] or ""
  local marker = record.resolved and "[x] " or "[ ] "
  local line_ref
  local el = end_line(record)
  if el and el > start_line(record) then
    line_ref = string.format("L%d-%d", start_line(record), el)
  else
    line_ref = string.format("L%d", start_line(record))
  end
  return string.format("%s%s %s", marker, line_ref, truncate(first, 160))
end

---@param records table[]
---@return table[]
local function build_items(records)
  local items = {}
  for _, r in ipairs(sort_records(records or {})) do
    local item = {
      lnum = start_line(r),
      col = start_col(r),
      type = r.resolved and "N" or "I",
      text = format_text(r),
      -- Tag each item with a stable locator so qf-local mutations don't
      -- depend on the quickfix buffer's own project identity.
      user_data = {
        id = r.id,
        scope = r.scope,
        project_root = r.project_root,
      },
    }
    local fname = filename_for(r)
    if fname then
      -- Quickfix needs a real filesystem path for `<CR>`/`:cc` jumps.
      -- Non-file URIs fall through to a live-bufnr lookup so terminal,
      -- help, and unnamed scratch-buffer comments still jump somewhere
      -- sensible while the owning buffer exists.
      item.filename = fname
    else
      local bufnr = require("manicule.uri").bufnr_for_uri(r.uri)
      if bufnr then
        item.bufnr = bufnr
      end
    end
    table.insert(items, item)
  end
  return items
end

---@param records table[]
---@return string?
local function root_for_records(records)
  for _, record in ipairs(records or {}) do
    if type(record.project_root) == "string" and record.project_root ~= "" then
      return record.project_root
    end
  end
  return nil
end

--- Build quickfix items without opening. Useful for tests / external callers.
---@param records table[]
---@return table[]
function M.build_items(records)
  return build_items(records)
end

---@return string
local function current_qf_title()
  local ok, info = pcall(vim.fn.getqflist, { title = 1 })
  if ok and type(info) == "table" and type(info.title) == "string" then
    return info.title
  end
  return ""
end

---@param title string
---@return boolean
local function is_manicule_title(title)
  return type(title) == "string" and title:match("^" .. state.title_prefix) ~= nil
end

--- Return the winid of a quickfix window in the current tab whose
--- underlying list is a manicule-titled list, or nil. Used by the
--- `User Manicule*` autocmd to decide whether a refresh is warranted.
---@return integer|nil
function M.is_manicule_qf_open()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].buftype == "quickfix" then
      -- `getqflist` is global, but a qf window in the current tab can
      -- only show the current qflist, so querying without a winid is
      -- correct here. (Location lists are `loclist`, not `quickfix`.)
      if is_manicule_title(current_qf_title()) then
        return winid
      end
    end
  end
  return nil
end

--- Resolve the record id at the cursor in the current quickfix window.
--- Reads `user_data` off the qf item indexed by the cursor row. Returns
--- nil if the current buffer isn't a quickfix or the item has no id.
---@return { id: string, scope?: "project"|"session", project_root?: string }|nil
function M.record_locator_at_cursor()
  if vim.bo.buftype ~= "quickfix" then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local ok, info = pcall(vim.fn.getqflist, { items = 1 })
  if not ok or type(info) ~= "table" or type(info.items) ~= "table" then
    return nil
  end
  local item = info.items[row]
  if not item then
    return nil
  end
  local data = item.user_data
  if type(data) == "table" and type(data.id) == "string" and data.id ~= "" then
    return {
      id = data.id,
      scope = data.scope,
      project_root = data.project_root,
    }
  end
  if type(data) == "string" and data ~= "" then
    return { id = data }
  end
  return nil
end

---Compatibility helper for callers that only need the id.
---@return string|nil
function M.record_id_at_cursor()
  local locator = M.record_locator_at_cursor()
  if locator then
    return locator.id
  end
  return nil
end

--- Populate the quickfix list and (optionally) open it.
---@param records table[]
---@param opts? { open?: boolean, filter?: table }
function M.show(records, opts)
  opts = opts or {}
  local items = build_items(records)
  local title = string.format("%s (%d)", state.title_prefix, #items)
  -- Record the filter + root that produced this list so a later
  -- `M.refresh` can regenerate it without knowing who called `show`.
  state.root = opts.filter and opts.filter._root or root_for_records(records) or require("manicule.store").root()
  state.filter = opts.filter and vim.deepcopy(opts.filter) or nil
  vim.fn.setqflist({}, " ", { title = title, items = items })
  if opts.open ~= false and #items > 0 then
    vim.cmd("copen")
    -- `FileType qf` only fires on the first qf-buffer creation per
    -- session; subsequent `:copen`s reuse the existing buffer and
    -- would miss the attach sweep. Re-run the keymap wiring here so
    -- the runtime opt-out toggle also gets honoured on every open.
    local qf_winid = M.is_manicule_qf_open()
    if qf_winid then
      require("manicule.ui.quickfix_keymaps").attach(vim.api.nvim_win_get_buf(qf_winid))
    end
  end
end

--- Regenerate the current manicule quickfix list in place.
---
--- Re-queries `manicule.list` with the cached filter and replaces the
--- current qflist with mode `"r"` so the open qf window stays open and
--- the cursor keeps its line number (Neovim clamps automatically if
--- the new list is shorter). Aborts silently if the current qflist
--- title no longer starts with `manicule` — we must never stomp on
--- somebody else's quickfix (grep results, diagnostic list, …).
function M.refresh()
  -- Title-prefix guard: if the user swapped to a different quickfix
  -- between the triggering `User Manicule*` event and this refresh
  -- call (e.g. `:grep`), leave it alone.
  if not is_manicule_title(current_qf_title()) then
    return
  end

  -- Capture cursor row of the qf window (if any) so we can restore it
  -- after the replace — `setqflist` mode `"r"` updates the buffer but
  -- in some Neovim versions resets the cursor to line 1. Look up the
  -- qf window inside the current tab.
  local qf_winid, saved_row
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].buftype == "quickfix" then
      qf_winid = winid
      saved_row = vim.api.nvim_win_get_cursor(winid)[1]
      break
    end
  end

  -- Re-run the same filter through the public `list` API so any
  -- filter semantics (unresolved, orphaned, path, author) stay in
  -- sync with the non-refresh path. `_quiet = true` suppresses the
  -- implicit `show` call inside `list` so we don't recurse.
  local filter = state.filter and vim.deepcopy(state.filter) or {}
  filter._quiet = true
  filter._root = state.root
  local records = require("manicule").list(filter)
  local items = build_items(records)
  local title = string.format("%s (%d)", state.title_prefix, #items)
  -- Mode `"r"` replaces the current list in place; the quickfix window
  -- stays open.
  vim.fn.setqflist({}, "r", { title = title, items = items })

  -- Restore the cursor row, clamped to the new list length. Neovim
  -- normally preserves the row in `"r"` mode but real-world reports
  -- say this regresses when items become shorter or the list empties
  -- — clamp explicitly.
  if qf_winid and saved_row and vim.api.nvim_win_is_valid(qf_winid) then
    local max_row = math.max(1, #items)
    local target = math.min(saved_row, max_row)
    if #items > 0 then
      pcall(vim.api.nvim_win_set_cursor, qf_winid, { target, 0 })
    end
  end
end

return M
