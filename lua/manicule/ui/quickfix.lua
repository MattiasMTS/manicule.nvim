-- manicule.nvim: quickfix formatter for comment records.
--
-- Groups comments by path and sorts by line and id so order is stable
-- across reloads and consistent across quickfix, pickers, and command
-- completion.
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

local str = require("manicule.str")
local range = require("manicule.range")

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

---Sort a copy of `records` by the canonical `uri → start line → id`
---ordering (see `manicule.range.compare`). Deep-copies first so the
---caller's list is never mutated.
---@param records table[]
---@return table[]
local function sort_records(records)
  local ordered = vim.deepcopy(records)
  table.sort(ordered, range.compare)
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

---@param record table
---@return string
local function format_text(record)
  local body = record.body or ""
  local first = vim.split(body, "\n", { plain = true })[1] or ""
  local marker = record.resolved and "[x] " or "[ ] "
  local line_ref
  local el = range.end_line(record)
  if el and el > range.start_line(record) then
    line_ref = string.format("L%d-%d", range.start_line(record), el)
  else
    line_ref = string.format("L%d", range.start_line(record))
  end
  return string.format("%s%s %s", marker, line_ref, str.truncate(first, 160))
end

---@param records table[]
---@return table[]
local function build_items(records)
  local items = {}
  for _, r in ipairs(sort_records(records or {})) do
    local item = {
      lnum = range.start_line(r),
      col = range.start_col(r),
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

---Format the quickfix list title for `n` items. Single source of truth
---so the format string and the `is_manicule_title` prefix match can't
---drift apart.
---@param n integer
---@return string
local function make_title(n)
  return string.format("%s (%d)", state.title_prefix, n)
end

---@param title string
---@return boolean
local function is_manicule_title(title)
  -- Match the exact `make_title` shape (`<prefix> (N)`), not a bare
  -- prefix: review-mode panels are titled `manicule-review (...)` and
  -- must never be claimed (and stomped) by this module's refresh.
  return type(title) == "string" and title:match("^" .. vim.pesc(state.title_prefix) .. " %(") ~= nil
end

---Read the title of the list ACTUALLY displayed in `winid`. Unlike a
---bare `getqflist({title=1})` (the GLOBAL current stack entry), this
---reflects what the window shows even after `:colder`/`:cnewer` walk
---the qf history, so detection never targets the wrong window.
---@param winid integer
---@return string
local function qf_title_for_win(winid)
  local ok, info = pcall(vim.fn.getqflist, { winid = winid, title = 1 })
  if ok and type(info) == "table" and type(info.title) == "string" then
    return info.title
  end
  return ""
end

--- Find a quickfix window in the current tab whose DISPLAYED list is a
--- manicule-titled list. Returns `(winid, bufnr)` or nil.
---
--- Both quickfix and location-list windows report
--- `buftype == "quickfix"`. Discriminate via `getwininfo().loclist`: a
--- true quickfix window has `loclist == 0`, a location list has
--- `loclist == 1`. We only ever own the global quickfix list. The title
--- is read per-window (`qf_title_for_win`) rather than from the global
--- current stack entry, so qf history (`:colder`/`:cnewer`) can't make
--- us match a window that's actually showing somebody else's list.
---@return integer|nil winid
---@return integer|nil bufnr
local function find_manicule_qf_win()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].buftype == "quickfix" then
      local wininfo = vim.fn.getwininfo(winid)[1]
      if wininfo and wininfo.loclist == 0 and is_manicule_title(qf_title_for_win(winid)) then
        return winid, bufnr
      end
    end
  end
  return nil, nil
end

--- Return the winid of a quickfix window in the current tab whose
--- displayed list is a manicule-titled list, or nil. Used by the
--- `User Manicule*` autocmd to decide whether a refresh is warranted.
---@return integer|nil
function M.is_manicule_qf_open()
  return (find_manicule_qf_win())
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
  -- `build_items` always writes `user_data` as a table, and it
  -- round-trips as a table through setqflist/getqflist, so we only
  -- handle the table form here.
  local data = item.user_data
  if type(data) == "table" and type(data.id) == "string" and data.id ~= "" then
    return {
      id = data.id,
      scope = data.scope,
      project_root = data.project_root,
    }
  end
  return nil
end

--- Populate the quickfix list and (optionally) open it.
---@param records table[]
---@param opts? { open?: boolean, filter?: table }
function M.show(records, opts)
  opts = opts or {}
  local items = build_items(records)
  local title = make_title(#items)
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
--- the new list is shorter). Aborts silently if no quickfix window in
--- the current tab is actually displaying a manicule-titled list — we
--- must never stomp on somebody else's quickfix (grep results,
--- diagnostic list, …), even when qf history (`:colder`/`:cnewer`) has
--- left the global current stack entry pointing elsewhere.
function M.refresh()
  -- Per-window manicule guard + cursor capture in one walk. If the
  -- user swapped the visible qf to a different list between the
  -- triggering `User Manicule*` event and this refresh call (e.g.
  -- `:grep`, `:colder`), leave it alone.
  --
  -- Capture the cursor row of the qf window so we can restore it after
  -- the replace — `setqflist` mode `"r"` updates the buffer but in some
  -- Neovim versions resets the cursor to line 1.
  local qf_winid = find_manicule_qf_win()
  if not qf_winid then
    return
  end
  local saved_row = vim.api.nvim_win_get_cursor(qf_winid)[1]

  -- Resolve the stack entry actually DISPLAYED in `qf_winid` so the
  -- in-place replace targets that list specifically. Otherwise a bare
  -- `setqflist({}, "r", ...)` writes the GLOBAL current stack entry,
  -- which qf history (`:colder`/`:cnewer`) may have moved off our list
  -- — we'd stomp the wrong list and never update the open window.
  local target_id = 0
  local ok_id, id_info = pcall(vim.fn.getqflist, { winid = qf_winid, id = 0 })
  if ok_id and type(id_info) == "table" and type(id_info.id) == "number" then
    target_id = id_info.id
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
  local title = make_title(#items)
  -- Mode `"r"` replaces the list in place; the quickfix window stays
  -- open. Pass `id` so we replace the entry shown in `qf_winid` even
  -- when it isn't the global current stack entry (qf history).
  vim.fn.setqflist({}, "r", { id = target_id, title = title, items = items })

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
