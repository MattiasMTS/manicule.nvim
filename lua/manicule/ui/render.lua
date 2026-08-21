-- manicule.nvim: per-comment floating popup renderer.
--
-- For each live record we own a Handle that carries the anchor extmark id,
-- the popup window id, and the popup scratch buffer. `reconcile` is
-- idempotent: it creates, updates, and tears down popups based on the
-- records currently belonging to a buffer.
--
-- manicule is buffer-agnostic, so the keying is `[bufnr][comment_id]`.
-- A record "belongs to" a buffer when the
-- buffer's canonical URI (see `manicule.uri.for_bufnr`) equals
-- `record.uri`.
--
-- Sticky vs non-sticky is driven by `config.get().ui.sticky`:
--   * sticky  = true  -> popups are always shown for every record in
--                        the buffer (reconcile renders them)
--   * sticky  = false -> popups are only shown for records whose line
--                        is in the current viewport (update_viewport_popups)
--
-- Display modes (`config.get().ui.display` is the startup default; the
-- live mode is module state, switched via `M.set_display_mode` /
-- `:ManiculeDisplay`):
--   * "float"  -> anchored popups (the sticky/viewport gating above
--                 applies). Placement is occlusion-aware and
--                 unconditional (no config): the right-margin spot is
--                 only used when every buffer line the popup would
--                 vertically span leaves it on genuinely empty cells —
--                 each spanned line's `strdisplaywidth` must end at
--                 least one cell left of the popup's left edge.
--                 Otherwise the popup falls back BELOW the anchor line,
--                 left-aligned like the inline box (one-cell gutter),
--                 or ABOVE the anchor when the window bottom leaves no
--                 room below. A same-line stack decides + falls back as
--                 a unit — never split between margin and below-line —
--                 and keeps its vertical stacking in either placement.
--                 Measurement assumes 'nowrap' and no horizontal scroll
--                 (leftcol 0), the same assumptions the margin layout
--                 math itself makes (one screen row per buffer line,
--                 cell 0 = buffer column 0). Inputs are buffer lines +
--                 window geometry only — stable while the cursor moves
--                 along a line, so a layout pass never flaps between
--                 margin and fallback. Eol's expanded popups reuse this
--                 path and inherit the same rule.
--   * "eol"    -> one collapsed end-of-line virt-text marker per record
--                 on its anchor line; the full popup(s) for a line
--                 expand while the cursor sits on it and close when it
--                 leaves. Expansion is fed by CursorMoved through
--                 init.lua's coalesced viewport refresh — chosen over
--                 CursorHold so expanding doesn't wait 'updatetime',
--                 and over a new debounced autocmd because the existing
--                 per-buffer pending flag already coalesces the burst.
--                 Sticky is a float-mode concern: eol renders markers
--                 for every record regardless (extmarks are cheap).
--   * "inline" -> each record renders as a bordered `virt_lines` box
--                 below its anchor line — code is pushed down, never
--                 covered. The box reuses the float popup's content
--                 (title with short-id + n/m counter, body, date/actions
--                 footer) via the shared `build_popup_content`, with
--                 body lines word-wrapped to the box width instead of
--                 ellipsis-truncated (there is no popup to reveal the
--                 rest). Same-line stacks render sequentially inside ONE
--                 virt_lines block owned by the stack head's handle
--                 (`record_stack_less` order), so box order never
--                 depends on sibling-extmark creation order. Like eol,
--                 boxes render for every record — no viewport/sticky
--                 gating. Unlike eol, NO popup expands under the cursor:
--                 the box already shows the full body and footer hints,
--                 and the popup is `focusable = false` anyway, so
--                 expansion would only duplicate visible content.
--                 Edit/delete stay reachable through the anchor-line
--                 cursor hit-test (`record_at_cursor`) exactly as in
--                 every other mode.
--   * "hidden" -> anchor extmarks + line-number tint only; no popups,
--                 no virtual text
--
-- The editor focus exception (BufLeave/WinLeave skip while the comment
-- editor is opening) applies in every mode, so editing from an expanded
-- eol popup does not close it mid-edit.

local M = {}

local anchor = require("manicule.anchor")
local float = require("manicule.ui.float")
local config = require("manicule.config")
local str = require("manicule.str")

---@class manicule.ui.render.Handle
---@field bufnr integer Buffer the extmark is placed in
---@field extmark_id integer
---@field number_extmark_ids? integer[] Decoration-only extmarks per row for multi-line number tint
---@field eol_extmark_id? integer Decoration-only extmark carrying the collapsed marker ("eol" display mode)
---@field inline_extmark_id? integer Decoration-only extmark carrying the below-line box block ("inline" display mode)
---@field popup_winid? integer
---@field popup_bufnr? integer

--- handles[bufnr][comment_id] = Handle
---@type table<integer, table<string, manicule.ui.render.Handle>>
local handles = {}

-- Transient visibility flag. When true, every render path is gated off
-- (reconcile / viewport update no-op). In-memory only, not persisted —
-- resets on nvim restart. Users who want visuals back after a restart
-- simply don't toggle; users who want a quiet session run `:ManiculeToggle`
-- and carry on. See `M.hide` / `M.show` / `M.toggle`.
local hidden = false

-- Display modes in :ManiculeDisplay cycle order.
local DISPLAY_MODES = { "float", "eol", "inline", "hidden" }

---@type table<string, true>
local VALID_DISPLAY_MODES = {}
for _, mode in ipairs(DISPLAY_MODES) do
  VALID_DISPLAY_MODES[mode] = true
end

-- Live display mode. `config.get().ui.display` is only the startup
-- default; runtime switches (`M.set_display_mode` / :ManiculeDisplay)
-- land here. In-memory only, like `hidden` — resets on nvim restart.
---@type string?
local display_mode = nil

---Resolve the live display mode: the runtime override when set,
---otherwise the configured startup default, otherwise "eol".
---@return "float"|"eol"|"inline"|"hidden"
local function current_display_mode()
  if display_mode then
    return display_mode
  end
  local cfg = config.get() or {}
  local configured = (cfg.ui or {}).display
  if VALID_DISPLAY_MODES[configured] then
    return configured
  end
  return "eol"
end

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

local DEFAULT_BORDER_FG = 0xA6ADC8

---@param name string
---@return table
local function get_highlight(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then
    return hl
  end
  return {}
end

local function setup_comment_highlights()
  local border_fg = DEFAULT_BORDER_FG
  local normal_hl = get_highlight("Normal")
  local normal_float_hl = get_highlight("NormalFloat")
  local float_border_hl = get_highlight("FloatBorder")

  if type(float_border_hl.fg) == "number" then
    border_fg = float_border_hl.fg
  elseif type(normal_float_hl.fg) == "number" then
    border_fg = normal_float_hl.fg
  elseif type(normal_hl.fg) == "number" then
    border_fg = normal_hl.fg
  end

  local float_bg = normal_float_hl.bg
  if type(float_bg) ~= "number" and type(normal_hl.bg) == "number" then
    float_bg = normal_hl.bg
  end

  local meta_fg = border_fg
  local comment_hl = get_highlight("Comment")
  if type(comment_hl.fg) == "number" then
    meta_fg = comment_hl.fg
  end

  local border_hl = { fg = border_fg }
  local meta_hl = { fg = meta_fg }
  if type(float_bg) == "number" then
    border_hl.bg = float_bg
    meta_hl.bg = float_bg
  end

  vim.api.nvim_set_hl(0, "ManiculeCommentBorder", border_hl)
  vim.api.nvim_set_hl(0, "ManiculeCommentMeta", meta_hl)
  vim.api.nvim_set_hl(0, "ManiculeLineNr", { link = "DiagnosticSignInfo", default = true })
  -- "eol" display-mode marker: accent bullet, dim id/counter, dim body.
  -- `default` links so user overrides win.
  vim.api.nvim_set_hl(0, "ManiculeEolBullet", { link = "DiagnosticSignInfo", default = true })
  vim.api.nvim_set_hl(0, "ManiculeEolMeta", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "ManiculeEolBody", { link = "Comment", default = true })
  -- "inline" display-mode box: border/meta reuse the float popup's
  -- computed groups so both modes share one look; body text sits on the
  -- float's NormalFloat. `default` links so user overrides win.
  vim.api.nvim_set_hl(0, "ManiculeInlineBorder", { link = "ManiculeCommentBorder", default = true })
  vim.api.nvim_set_hl(0, "ManiculeInlineMeta", { link = "ManiculeCommentMeta", default = true })
  vim.api.nvim_set_hl(0, "ManiculeInlineBody", { link = "NormalFloat", default = true })
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

---@return string
local function comment_winhighlight()
  return "NormalFloat:NormalFloat,FloatBorder:ManiculeCommentBorder,FloatTitle:ManiculeCommentMeta,FloatFooter:ManiculeCommentMeta"
end

-- `split_lines` (newline split with empty-line guard) and `truncate_text`
-- (byte-length ellipsis) are shared with the quickfix formatter and the
-- floating editor via `manicule.str`.
local split_lines = str.split_lines
local truncate_text = str.truncate

---Truncate `text` to at most `max_cells` display cells, appending a
---single-cell ellipsis when cut. `str.truncate` is byte-based; fitting
---virtual text into leftover window columns needs display width
---(`strdisplaywidth` — tabs, doublewidth glyphs), hence the char walk.
---@param text string
---@param max_cells integer
---@return string
local function truncate_display(text, max_cells)
  if max_cells <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max_cells then
    return text
  end
  local budget = max_cells - 1 -- reserve the ellipsis cell
  local out = ""
  for i = 0, vim.fn.strchars(text) - 1 do
    local next_out = out .. vim.fn.strcharpart(text, i, 1)
    if vim.fn.strdisplaywidth(next_out) > budget then
      break
    end
    out = next_out
  end
  return out .. "…"
end

---Word-wrap `text` into lines of at most `max_cells` display cells.
---Breaks at spaces when possible; a single word wider than the whole
---budget is hard-broken with the same char walk `truncate_display`
---uses. Always returns at least one line.
---@param text string
---@param max_cells integer
---@return string[]
local function wrap_display(text, max_cells)
  if max_cells <= 0 or vim.fn.strdisplaywidth(text) <= max_cells then
    return { text }
  end
  local lines = {}
  local current = ""
  for word in text:gmatch("%S+") do
    local candidate = current == "" and word or (current .. " " .. word)
    if vim.fn.strdisplaywidth(candidate) <= max_cells then
      current = candidate
    else
      if current ~= "" then
        table.insert(lines, current)
        current = ""
      end
      -- Hard-break a word longer than the whole budget.
      while vim.fn.strdisplaywidth(word) > max_cells do
        local head = ""
        local taken = 0
        for i = 0, vim.fn.strchars(word) - 1 do
          local next_head = head .. vim.fn.strcharpart(word, i, 1)
          if vim.fn.strdisplaywidth(next_head) > max_cells then
            break
          end
          head = next_head
          taken = i + 1
        end
        if head == "" then
          -- Budget below one glyph: bail rather than spin.
          break
        end
        table.insert(lines, head)
        word = vim.fn.strcharpart(word, taken)
      end
      current = word
    end
  end
  if current ~= "" then
    table.insert(lines, current)
  end
  if #lines == 0 then
    lines = { text }
  end
  return lines
end

---Short display id from the record's string id (first 6 chars).
---@param record_id string
---@return string
local function short_id(record_id)
  local s = tostring(record_id or "")
  if #s <= 6 then
    return s
  end
  return s:sub(1, 6)
end

---Edit/delete hint shown in the popup footer. Matches the default
---`gca` / `gcd` bindings shipped in `plugin/manicule.lua`; there is no
---user-facing keymap-hint config.
local COMMENT_HINT = "edit gca | delete gcd"

---Compose the popup footer: "<Mon DD HH:MM> · <hint>", or just the hint
---when the record carries no timestamp.
---@param record table
---@return string
local function comment_footer_text(record)
  local ts = record and (record.updated_at or record.created_at)
  local ts_str = type(ts) == "number" and os.date("%b %d %H:%M", ts) or nil
  if ts_str then
    return ts_str .. " · " .. COMMENT_HINT
  end
  return COMMENT_HINT
end

---Find any window (in any tab) currently showing `bufnr`.
---@param bufnr integer
---@return integer?
local function find_window_for_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end
  return nil
end

---@param bufnr integer
---@return table<string, manicule.ui.render.Handle>
local function get_buf_handles(bufnr)
  if not handles[bufnr] then
    handles[bufnr] = {}
  end
  return handles[bufnr]
end

---Return the 1-indexed start line of the record.
---@param record table
---@return integer
local function record_start_line(record)
  local start = record and record.range and record.range.start
  if type(start) == "table" and type(start[1]) == "number" then
    return start[1] + 1
  end
  return 1
end

---Return the 1-indexed end line of the record (may equal start).
---@param record table
---@return integer?
local function record_end_line(record)
  local end_ = record and record.range and record.range.end_
  if type(end_) == "table" and type(end_[1]) == "number" then
    return end_[1] + 1
  end
  return nil
end

---@param a table
---@param b table
---@return boolean
local function record_layout_less(a, b)
  local al = record_start_line(a)
  local bl = record_start_line(b)
  if al ~= bl then
    return al < bl
  end
  local ac = a.range and a.range.start and a.range.start[2] or 0
  local bc = b.range and b.range.start and b.range.start[2] or 0
  if ac ~= bc then
    return ac < bc
  end
  local at = tonumber(a.created_at) or 0
  local bt = tonumber(b.created_at) or 0
  if at ~= bt then
    return at < bt
  end
  return tostring(a.id or "") < tostring(b.id or "")
end

---@param a table
---@param b table
---@return boolean
local function record_counter_less(a, b)
  local au = tostring(a.uri or "")
  local bu = tostring(b.uri or "")
  if au ~= bu then
    return au < bu
  end
  return record_layout_less(a, b)
end

---Ordering of a same-line popup stack: creation time, then id. Shared
---by the float stack layout and the eol marker's n/m counter so both
---agree on which comment is "2/3" on a line.
---@param a table
---@param b table
---@return boolean
local function record_stack_less(a, b)
  local ac = tonumber(a.created_at) or 0
  local bc = tonumber(b.created_at) or 0
  if ac ~= bc then
    return ac < bc
  end
  return tostring(a.id or "") < tostring(b.id or "")
end

---Same-line stack position for `record`: 1-based index among the
---records sharing its uri + start line (in `record_stack_less` order)
---and the stack's total size — the n/m the popup title and the eol
---marker show.
---@param record table
---@param records table[]
---@return integer index, integer total
local function same_line_stack_position(record, records)
  local my_line = record_start_line(record)
  local my_id = tostring(record.id or "")
  local stack = {}
  for _, other in ipairs(records or {}) do
    if other.uri == record.uri and record_start_line(other) == my_line then
      table.insert(stack, other)
    end
  end
  table.sort(stack, record_stack_less)
  for index, other in ipairs(stack) do
    if tostring(other.id or "") == my_id then
      return index, #stack
    end
  end
  return 1, math.max(1, #stack)
end

---@param record table
---@param candidate table
---@return boolean
local function same_counter_scope(record, candidate)
  if record.scope == "project" or record.project_root then
    return candidate.scope ~= "session"
      and tostring(candidate.project_root or "") == tostring(record.project_root or "")
  end
  if record.scope == "session" then
    return candidate.scope == "session"
  end
  return candidate.uri == record.uri
end

---@param record table
---@param records table[]
---@return integer index, integer total
local function record_display_position(record, records)
  local id = tostring(record.id or "")
  local ordered = {}
  for _, other in ipairs(records or {}) do
    if same_counter_scope(record, other) then
      table.insert(ordered, other)
    end
  end
  table.sort(ordered, record_counter_less)
  for index, other in ipairs(ordered) do
    if tostring(other.id or "") == id then
      return index, #ordered
    end
  end
  return 1, math.max(1, #ordered)
end

---Precompute `{ index, total }` display positions for a set of records
---against `counter_records`, sharing each counter-scope group's sort
---across every record that belongs to it. `record_display_position`
---re-scans + re-sorts `counter_records` per call, which makes the
---per-record popup render O(counter_records) — over a viewport of N
---records that is O(N · counter_records). This builds the same answer
---once: one sort per distinct scope group, then O(1) lookups.
---@param records table[] records that will be rendered
---@param counter_records table[]
---@return table<string, {index: integer, total: integer}>
local function precompute_display_positions(records, counter_records)
  local pool = counter_records or records
  -- Cache an ordered scope group by a stable scope key so records that
  -- share a counter scope reuse the same sorted list + index map.
  ---@type table<string, table<string, integer>>
  local group_index = {}
  ---@type table<string, integer>
  local group_total = {}
  local out = {}
  for _, record in ipairs(records or {}) do
    local id = tostring(record.id or "")
    -- Scope key mirrors `same_counter_scope`'s three branches so two
    -- records land in the same group iff they would for that predicate.
    local key
    if record.scope == "project" or record.project_root then
      key = "p:" .. tostring(record.project_root or "")
    elseif record.scope == "session" then
      key = "s:"
    else
      key = "u:" .. tostring(record.uri or "")
    end
    if not group_index[key] then
      local ordered = {}
      for _, other in ipairs(pool) do
        if same_counter_scope(record, other) then
          table.insert(ordered, other)
        end
      end
      table.sort(ordered, record_counter_less)
      local index_map = {}
      for index, other in ipairs(ordered) do
        index_map[tostring(other.id or "")] = index
      end
      group_index[key] = index_map
      group_total[key] = #ordered
    end
    local index = group_index[key][id] or 1
    local total = math.max(1, group_total[key])
    out[id] = { index = index, total = total }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Handle lifecycle
-- ---------------------------------------------------------------------------

---Tear down the decoration-only per-line number-highlight extmarks.
---@param handle manicule.ui.render.Handle
local function clear_number_extmarks(handle)
  if not handle.number_extmark_ids then
    return
  end
  if vim.api.nvim_buf_is_valid(handle.bufnr) then
    for _, id in ipairs(handle.number_extmark_ids) do
      pcall(vim.api.nvim_buf_del_extmark, handle.bufnr, anchor.ns, id)
    end
  end
  handle.number_extmark_ids = nil
end

---Tear down the decoration-only eol virt-text extmark (the "eol"
---display mode's collapsed marker).
---@param handle manicule.ui.render.Handle
local function clear_eol_extmark(handle)
  if not handle.eol_extmark_id then
    return
  end
  if vim.api.nvim_buf_is_valid(handle.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, handle.bufnr, anchor.ns, handle.eol_extmark_id)
  end
  handle.eol_extmark_id = nil
end

---Tear down the decoration-only virt_lines extmark (the "inline"
---display mode's below-line box block).
---@param handle manicule.ui.render.Handle
local function clear_inline_extmark(handle)
  if not handle.inline_extmark_id then
    return
  end
  if vim.api.nvim_buf_is_valid(handle.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, handle.bufnr, anchor.ns, handle.inline_extmark_id)
  end
  handle.inline_extmark_id = nil
end

---@param handle manicule.ui.render.Handle
local function close_handle(handle)
  if handle.popup_winid and vim.api.nvim_win_is_valid(handle.popup_winid) then
    pcall(vim.api.nvim_win_close, handle.popup_winid, true)
  end
  handle.popup_winid = nil

  if handle.popup_bufnr and vim.api.nvim_buf_is_valid(handle.popup_bufnr) then
    pcall(vim.api.nvim_buf_delete, handle.popup_bufnr, { force = true })
  end
  handle.popup_bufnr = nil

  clear_number_extmarks(handle)
  clear_eol_extmark(handle)
  clear_inline_extmark(handle)

  if handle.extmark_id and handle.extmark_id ~= 0 and vim.api.nvim_buf_is_valid(handle.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, handle.bufnr, anchor.ns, handle.extmark_id)
  end
  -- Zero the id after deletion so a stale scheduled sticky render (whose
  -- guard checks `extmark_id ~= 0`) becomes a no-op. Every reader
  -- (`capture_position_patches`, `mark_ids_for_buffer`,
  -- `sync_handle_position`, `record_at_cursor`) already treats
  -- `extmark_id == 0` as "no mark", so this is safe across the module.
  handle.extmark_id = 0
end

---@param bufnr integer
---@param comment_id string
local function clear_handle(bufnr, comment_id)
  local tab = handles[bufnr]
  if not tab then
    return
  end
  local handle = tab[comment_id]
  if not handle then
    return
  end
  close_handle(handle)
  tab[comment_id] = nil
end

---@param handle manicule.ui.render.Handle
local function hide_popup(handle)
  if handle.popup_winid and vim.api.nvim_win_is_valid(handle.popup_winid) then
    pcall(vim.api.nvim_win_close, handle.popup_winid, true)
  end
  handle.popup_winid = nil
end

---Tear down every visual owned by `handle` while leaving the anchor
---extmark itself alive (but stripped of its `number_hl_group`). The
---anchor must persist so `invalidate = true` keeps tracking line
---deletions for orphan detection; only the popup + decoration extmarks
---(extra number-column tints, eol marker, inline box block, start-line
---number_hl_group) are removed.
---@param handle manicule.ui.render.Handle
local function strip_handle_visuals(handle)
  hide_popup(handle)
  clear_number_extmarks(handle)
  clear_eol_extmark(handle)
  clear_inline_extmark(handle)

  if not handle.extmark_id or handle.extmark_id == 0 then
    return
  end
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return
  end

  -- Re-set the anchor extmark in place, preserving the id + range +
  -- `invalidate` contract but dropping `number_hl_group` so the start
  -- line's number column loses its tint too. `nvim_buf_get_extmark_by_id`
  -- gives us the current row/col so a mid-edit hide matches the live
  -- position, not the original record range.
  local ok, pos =
    pcall(vim.api.nvim_buf_get_extmark_by_id, handle.bufnr, anchor.ns, handle.extmark_id, { details = true })
  if not ok or not pos or #pos == 0 then
    return
  end
  local row, col, details = pos[1], pos[2], pos[3] or {}
  if details.invalid then
    return
  end

  pcall(vim.api.nvim_buf_set_extmark, handle.bufnr, anchor.ns, row, col, {
    id = handle.extmark_id,
    end_row = details.end_row or row,
    end_col = details.end_col or col,
    invalidate = true,
    undo_restore = false,
    priority = 220,
  })
end

-- ---------------------------------------------------------------------------
-- Extmark rendering
-- ---------------------------------------------------------------------------

---Render (or refresh) the anchor extmark owned by `handle` for the
---current `record`. The extmark anchors the comment and tints the
---line number via `ManiculeLineNr` so `sync_handle_position` can
---detect line moves and users see which lines carry comments.
---@param record table
---@param handle manicule.ui.render.Handle
---@return boolean
local function render_extmark(record, handle)
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return false
  end

  local start_row = record.range and record.range.start and record.range.start[1] or 0
  local start_col = record.range and record.range.start and record.range.start[2] or 0
  local end_row = record.range and record.range.end_ and record.range.end_[1] or start_row
  local end_col = record.range and record.range.end_ and record.range.end_[2] or start_col

  local line_count = vim.api.nvim_buf_line_count(handle.bufnr)
  start_row = math.max(0, math.min(start_row, math.max(0, line_count - 1)))
  end_row = math.max(start_row, math.min(end_row, math.max(0, line_count - 1)))

  -- Linewise-visual records can arrive with col = v:maxcol (INT_MAX),
  -- which `nvim_buf_set_extmark` rejects. Clamp both cols to the actual
  -- line length so pre-fix records heal on next render.
  local function clamp_col(row, col)
    local line = vim.api.nvim_buf_get_lines(handle.bufnr, row, row + 1, false)[1] or ""
    return math.max(0, math.min(col, #line))
  end
  start_col = clamp_col(start_row, start_col)
  end_col = clamp_col(end_row, end_col)

  local opts = {
    end_row = end_row,
    end_col = end_col,
    invalidate = true,
    undo_restore = false,
    priority = 220,
    -- number_hl_group only tints the start line.
    number_hl_group = "ManiculeLineNr",
  }

  if handle.extmark_id and handle.extmark_id ~= 0 then
    opts.id = handle.extmark_id
  end

  local ok, extmark_id = pcall(vim.api.nvim_buf_set_extmark, handle.bufnr, anchor.ns, start_row, start_col, opts)
  if not ok then
    return false
  end

  handle.extmark_id = extmark_id

  -- For multi-line ranges, paint the number column on every subsequent
  -- row via decoration-only extmarks. `number_hl_group` on the primary
  -- anchor only covers the start row — without these, a visual-range
  -- comment only tints one line number.
  clear_number_extmarks(handle)
  if end_row > start_row then
    local ids = {}
    for row = start_row + 1, end_row do
      local dok, did = pcall(vim.api.nvim_buf_set_extmark, handle.bufnr, anchor.ns, row, 0, {
        number_hl_group = "ManiculeLineNr",
        priority = 220,
        -- Pure decoration — no `invalidate`, no `undo_restore`, no
        -- end range. Orphan detection still uses the primary anchor.
      })
      if dok then
        table.insert(ids, did)
      end
    end
    if #ids > 0 then
      handle.number_extmark_ids = ids
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Popup rendering
-- ---------------------------------------------------------------------------

-- Left text-column offset of a fallback-placed float (the below/above
-- placement of the occlusion-aware float mode): one cell right of the
-- anchor line's column 0, mirroring the inline box's one-cell gutter.
local FLOAT_FALLBACK_COL = 1

---Popup body height in content rows (borders add 2). Shared by the
---stack layout, the viewport cascade, and the occlusion measurement so
---they all agree on how tall a record's popup is.
---@param record table
---@return integer
local function popup_body_height(record)
  return math.max(1, #split_lines(record.body))
end

---Widest content a float popup may take in a `win_width`-cell window.
---Shared by the popup renderer, the viewport layout pass, and the
---inline box's cap so every mode sizes content identically.
---@param win_width integer
---@return integer
local function popup_width_cap(win_width)
  return math.max(24, math.floor(win_width * 0.52))
end

---Content display width of `record`'s popup: the widest body/footer
---line clamped to `max_width` — a short comment stays narrow. Shared by
---`build_popup_content` and the float placement measurement (which
---needs widths for a whole stack without building every popup's
---content).
---@param record table
---@param max_width integer Content-width cap in display cells
---@return integer
local function popup_content_width(record, max_width)
  local max_line_width = 0
  for _, line in ipairs(split_lines(record.body)) do
    max_line_width = math.max(max_line_width, vim.fn.strdisplaywidth(line))
  end
  if max_line_width == 0 then
    max_line_width = 1
  end
  local footer = comment_footer_text(record)
  local footer_width = footer and vim.fn.strdisplaywidth(footer) or 0
  return math.min(math.max(max_line_width, footer_width), math.max(1, max_width))
end

---Left column of a margin-placed popup (cells right of the anchor
---line's column 0): right-aligned to the window edge with a fixed
---inset, staggered left by `col_shift`. One formula shared by the
---renderer and the placement measurement so the measured spot is the
---placed spot.
---@param win_width integer
---@param content_width integer
---@param col_shift integer
---@return integer
local function margin_col(win_width, content_width, col_shift)
  return math.max(2, win_width - content_width - 6 - col_shift)
end

---Measure whether a same-line stack's right-margin spot rests on
---genuinely empty cells. `entries` describe each member's would-be
---margin rectangle: `row` (top offset in screen rows from the anchor
---line — 0 means the popup's top border sits ON the anchor row),
---`height` (content rows; the border adds 2 more), and `col` (left edge
---in cells right of the anchor line's column 0). A spanned buffer line
---occludes when its display width reaches past the rectangle's left
---edge minus a 1-cell gap; rows past the last buffer line are empty and
---never occlude.
---
---Assumes 'nowrap' and no horizontal scroll (leftcol 0) — the same
---assumptions the margin layout math itself makes (one screen row per
---buffer line, cell 0 = buffer column 0). Inputs are buffer lines and
---the precomputed rectangles only, both stable while the cursor moves
---along a line, so a layout pass never flaps between placements.
---@param bufnr integer
---@param anchor_line integer 1-indexed buffer line the stack anchors to
---@param entries { row: integer, height: integer, col: integer }[]
---@return boolean
local function margin_spot_is_clear(bufnr, anchor_line, entries)
  local min_row, max_row
  for _, entry in ipairs(entries) do
    local top = entry.row
    local bottom = entry.row + entry.height + 1
    min_row = math.min(min_row or top, top)
    max_row = math.max(max_row or bottom, bottom)
  end
  if not min_row then
    return true
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local first = anchor_line + min_row
  local last = math.min(anchor_line + max_row, line_count)
  if first > last then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)

  for _, entry in ipairs(entries) do
    local top = anchor_line + entry.row
    local bottom = math.min(anchor_line + entry.row + entry.height + 1, line_count)
    for lnum = top, bottom do
      local line = lines[lnum - first + 1] or ""
      if vim.fn.strdisplaywidth(line) + 1 > entry.col then
        return false
      end
    end
  end
  return true
end

---Direction of the fallback placement for a stack of `total_height`
---popup rows (borders included) anchored at `anchor_line`: BELOW the
---anchor when the whole stack fits between the anchor row and the
---window bottom, otherwise ABOVE. Depends only on the window's topline
---and height — stable while the cursor moves along a line.
---@param anchor_win integer
---@param anchor_line integer 1-indexed buffer line
---@param total_height integer
---@return "below"|"above"
local function fallback_direction(anchor_win, anchor_line, total_height)
  local top = vim.fn.line("w0", anchor_win)
  local win_height = vim.api.nvim_win_get_height(anchor_win)
  local anchor_row = anchor_line - top -- 0-based window row of the anchor
  if anchor_row + 1 + total_height <= win_height then
    return "below"
  end
  return "above"
end

---@class manicule.ui.render.PopupContent
---@field title string Title: " c<short-id> <n>/<m> "
---@field footer string? Timestamp + edit/delete hint (nil when both absent)
---@field lines string[] Body lines fitted to `width` display cells
---@field width integer Content width in display cells

---Build the formatted comment content shared by the float popup and the
---inline virt_lines box: the title (short id + display counter), body
---lines fitted to a width cap, and the date/actions footer. The content
---width is the widest body/footer line clamped to `max_width` — so a
---short comment stays narrow. `wrap = false` ellipsis-truncates each
---body line (float popups keep one row per body line); `wrap = true`
---word-wraps long lines across rows instead (the inline box has no
---expanded popup to reveal the rest, so it must show the whole body).
---@param record table
---@param max_width integer Content-width cap in display cells
---@param display_index integer
---@param display_total integer
---@param wrap boolean
---@return manicule.ui.render.PopupContent
local function build_popup_content(record, max_width, display_index, display_total, wrap)
  local footer = comment_footer_text(record)
  local body_lines = split_lines(record.body)
  local content_width = popup_content_width(record, max_width)

  local fitted = {}
  for _, line in ipairs(body_lines) do
    if wrap then
      vim.list_extend(fitted, wrap_display(line, content_width))
    else
      table.insert(fitted, truncate_text(line, content_width))
    end
  end

  return {
    title = string.format(" c%s %d/%d ", short_id(record.id), display_index, display_total),
    footer = footer,
    lines = fitted,
    width = content_width,
  }
end

---Render (or reconfigure) the comment popup for `record`. Returns true
---when the handle is healthy (regardless of whether the popup ended up
---visible — a missing anchor window hides the popup but keeps the
---handle alive).
---@param record table
---@param handle manicule.ui.render.Handle
---@param records table[] Current record snapshot (used for stack offset)
---@param counter_records? table[] Current project/session snapshot (used for title count)
---@param layout? {winid?: integer, placement?: "margin"|"below"|"above", row?: integer, col_shift?: integer, index?: integer, total?: integer, display?: {index: integer, total: integer}}
---@return boolean
local function render_comment_popup(record, handle, records, counter_records, layout)
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return false
  end
  layout = layout or {}

  local anchor_win = layout.winid
  if not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
    anchor_win = find_window_for_buffer(handle.bufnr)
  end
  if not anchor_win then
    hide_popup(handle)
    return true
  end

  -- Title counter position: reuse the caller's precomputed value when it
  -- threaded one through (`update_viewport_popups` builds them once for
  -- the whole viewport), otherwise compute it for this single record.
  local display_index, display_total
  if layout.display then
    display_index, display_total = layout.display.index, layout.display.total
  else
    display_index, display_total = record_display_position(record, counter_records or records)
  end

  local win_width = vim.api.nvim_win_get_width(anchor_win)
  local width_cap = popup_width_cap(win_width)
  local content = build_popup_content(record, width_cap, display_index, display_total, false)

  local my_line = record_start_line(record)
  local my_id = tostring(record.id or "")

  -- Placement + stack geometry. The non-sticky viewport path supplies
  -- everything precomputed (`layout.placement`/`row`/`col_shift` — it
  -- lays out whole viewports at once), so skip the O(records) stack
  -- scan + sort entirely in that case. The sticky path (no layout)
  -- computes the same-line stack here and makes the same
  -- occlusion-aware placement decision `update_viewport_popups` makes:
  -- margin only when every buffer line the stack would span leaves the
  -- spot on empty cells, otherwise below/above the anchor — always for
  -- the stack as a unit, so same-line popups never split placements.
  local placement = layout.placement
  local stack_offset = 0
  local stack_index = 1
  local fallback_row = 1
  if not placement then
    local stack = {}
    for _, other in ipairs(records or {}) do
      if other.uri == record.uri and record_start_line(other) == my_line then
        table.insert(stack, other)
      end
    end
    table.sort(stack, record_stack_less)
    if #stack == 0 then
      stack = { record }
    end

    local entries = {}
    local total = 0
    for index, other in ipairs(stack) do
      local height = popup_body_height(other)
      if tostring(other.id or "") == my_id then
        stack_index = index
        stack_offset = total
      end
      table.insert(entries, {
        row = total,
        height = height,
        col = margin_col(win_width, popup_content_width(other, width_cap), math.min((index - 1) * 2, 12)),
      })
      total = total + height + 2
    end

    if margin_spot_is_clear(handle.bufnr, my_line, entries) then
      placement = "margin"
    else
      placement = fallback_direction(anchor_win, my_line, total)
      fallback_row = (placement == "below" and 1 or -total) + stack_offset
    end
  end

  local popup_row, popup_col
  if placement == "margin" then
    popup_row = layout.row or stack_offset
    popup_col = margin_col(win_width, content.width, layout.col_shift or math.min((stack_index - 1) * 2, 12))
  else
    popup_row = layout.row or fallback_row
    popup_col = FLOAT_FALLBACK_COL
  end

  local popup_bufnr = handle.popup_bufnr
  if not popup_bufnr or not vim.api.nvim_buf_is_valid(popup_bufnr) then
    popup_bufnr = float.create_scratch_buf()
    handle.popup_bufnr = popup_bufnr
  end

  local win_config = {
    relative = "win",
    win = anchor_win,
    bufpos = { my_line - 1, 0 },
    row = popup_row,
    col = popup_col,
    width = content.width,
    height = math.max(1, #content.lines),
    style = "minimal",
    focusable = false,
    zindex = 210,
    noautocmd = true,
  }

  local border = "rounded"
  win_config.border = border

  float.apply_title_footer(win_config, border, content.title, "left", content.footer or nil, "left")

  local popup_winid = float.open_or_reconfigure(handle.popup_winid, popup_bufnr, false, win_config)

  -- `open_or_reconfigure` pcalls `nvim_open_win`/`nvim_win_set_config` and
  -- returns nil on failure (e.g. the anchor window vanished between layout
  -- and open). Don't leave a half-open handle: drop any stale winid via
  -- `hide_popup` and bail. The scratch buffer is `bufhidden=wipe` but,
  -- having never been shown, it isn't wiped — `handle.popup_bufnr` survives
  -- and the next render reuses it instead of leaking a fresh one.
  if not popup_winid or not vim.api.nvim_win_is_valid(popup_winid) then
    hide_popup(handle)
    return false
  end
  handle.popup_winid = popup_winid

  -- Tag the float so `prune_orphan_popups` can recognize a manicule
  -- comment popup that no live handle tracks anymore (e.g. a handle whose
  -- `popup_winid` got overwritten/nil'd, or the whole handle table reset
  -- on plugin reload) and close it. A window var (not a buffer var) is
  -- used because the scratch popup buffer can be wiped/reused.
  pcall(vim.api.nvim_win_set_var, popup_winid, "manicule_popup", true)

  vim.bo[popup_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup_bufnr, 0, -1, false, content.lines)
  vim.bo[popup_bufnr].modifiable = false

  float.set_float_win_options(popup_winid, comment_winhighlight())

  local opacity = ((config.get() or {}).ui or {}).opacity or 0
  float.set_float_transparency(popup_winid, opacity)

  return true
end

---Close every tagged manicule popup float that no live handle tracks.
---Builds the set of popup winids owned by a handle (across all buffers),
---then walks `nvim_list_wins()` and closes any window carrying the
---`manicule_popup` win-var that isn't in that set. This self-heals
---orphans: floats whose handle lost track of them (`popup_winid`
---overwritten/nil'd) or whose handle table was reset on plugin reload,
---which nothing else would ever close. It can never close a legitimate
---popup because every tracked float's winid is in `tracked`.
local function prune_orphan_popups()
  local tracked = {}
  for _, tab in pairs(handles) do
    for _, handle in pairs(tab) do
      if handle.popup_winid then
        tracked[handle.popup_winid] = true
      end
    end
  end

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and not tracked[winid] then
      -- Most windows won't carry the var, so pcall + guard on the result.
      local ok, tagged = pcall(vim.api.nvim_win_get_var, winid, "manicule_popup")
      if ok and tagged then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
  end
end

---Collapse duplicate *tracked* popup floats so a given record id shows
---at most ONE visible popup across every buffer/window. A codediff
---buffer (`codediff://...`) maps to the SAME working-tree URI as the
---real file, so the same record id ends up tracked in two buffers'
---handle tables — each rendering its own float (one per diff side).
---This keeps one and hides the rest.
---
---Complementary to `prune_orphan_popups` (which closes UNtracked tagged
---floats): this only touches floats that ARE tracked by a live handle.
---It can never over-close because it only collapses entries that share a
---record id AND each carry a live tracked popup, always keeping one —
---the loser's anchor extmark + line tint survive (only `hide_popup`,
---which nils `popup_winid` and leaves the extmark, runs on them).
---
---Winner preference: the entry in the current buffer (so the popup
---follows focus to the side the user is in); otherwise the entry with
---the lowest bufnr (deterministic/stable). O(total tracked popups).
local function dedup_popups()
  local current_buf = vim.api.nvim_get_current_buf()

  -- by_id[id] = { { bufnr = ..., handle = ... }, ... } for every live
  -- tracked popup float keyed under that record id.
  local by_id = {}
  for bufnr, tab in pairs(handles) do
    for id, handle in pairs(tab) do
      if handle.popup_winid and vim.api.nvim_win_is_valid(handle.popup_winid) then
        local entries = by_id[id]
        if not entries then
          entries = {}
          by_id[id] = entries
        end
        table.insert(entries, { bufnr = bufnr, handle = handle })
      end
    end
  end

  for _, entries in pairs(by_id) do
    if #entries > 1 then
      -- Pick the winner: current buffer first, else lowest bufnr.
      local winner = entries[1]
      for _, entry in ipairs(entries) do
        if entry.bufnr == current_buf then
          winner = entry
          break
        end
        if entry.bufnr < winner.bufnr then
          winner = entry
        end
      end
      for _, entry in ipairs(entries) do
        if entry ~= winner then
          hide_popup(entry.handle)
        end
      end
    end
  end
end

-- "A popup sweep (prune + dedup) is already scheduled" flag. The sticky
-- reconcile path schedules one render closure per record, and each used
-- to run both sweeps — O(N × sweeps) for a buffer with N comments. These
-- sweeps are global (they walk every window / every handle, not just one
-- buffer), so a single coalesced run after the batch produces the same
-- final popup set. Mirrors init.lua's `viewport_refresh_pending`: the
-- first scheduler sets the flag, later ones in the same burst no-op, and
-- the scheduled body clears it then runs the sweeps once.
local popup_sweep_pending = false

---Coalesce the post-render orphan-prune + dedup sweeps so a batch of
---scheduled sticky renders triggers them ONCE (after the batch) instead
---of per-record. The sweeps must run AFTER the renders so every freshly
---opened float is tracked (its winid is on a live handle) before pruning,
---which is preserved because both the renders and this sweep run via
---`vim.schedule` and the sweep is scheduled last each time.
local function schedule_popup_sweeps()
  if popup_sweep_pending then
    return
  end
  popup_sweep_pending = true
  vim.schedule(function()
    popup_sweep_pending = false
    -- Sweep any orphan left beside the just-rendered floats (e.g. a stale
    -- float from before an edit). Every popup rendered this batch is
    -- tracked, so only untracked tagged floats are closed.
    prune_orphan_popups()
    -- Collapse duplicate tracked popups (e.g. a codediff buffer mapping to
    -- the same URI rendered its own float for a record); keeps one,
    -- following focus to the current buffer.
    dedup_popups()
  end)
end

-- ---------------------------------------------------------------------------
-- Position sync
-- ---------------------------------------------------------------------------

---@param handle manicule.ui.render.Handle
---@return { start_line: integer, end_line: integer? }?
local function sync_handle_position(handle)
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return nil
  end
  if not handle.extmark_id or handle.extmark_id == 0 then
    return nil
  end

  local ok, pos =
    pcall(vim.api.nvim_buf_get_extmark_by_id, handle.bufnr, anchor.ns, handle.extmark_id, { details = true })
  if not ok or not pos or #pos == 0 then
    return nil
  end

  local details = pos[3]
  if details and details.invalid then
    return nil
  end

  local result = { start_line = pos[1] + 1 }
  if details and details.end_row then
    result.end_line = details.end_row + 1
  end
  return result
end

---@return boolean
local function is_sticky()
  local cfg = config.get() or {}
  local ui_opts = cfg.ui or {}
  return ui_opts.sticky == true
end

-- ---------------------------------------------------------------------------
-- Eol virt-text rendering ("eol" display mode's collapsed marker)
-- ---------------------------------------------------------------------------

-- Minimum leftover cells the full marker form needs. Below this the
-- marker degrades to just `● <short-id>` — a tighter budget would
-- truncate the body into unreadable noise.
local EOL_MIN_WIDTH = 20

---Render (or refresh) the collapsed end-of-line marker for `record`:
---`● <short-id> <n>/<m> · <body first line>` as eol virtual text on the
---anchor's current line, via a sibling decoration-only extmark tracked
---as `handle.eol_extmark_id`. n/m is the record's same-line stack
---position; single-record lines omit it.
---
---Truncation: the marker's budget is the window width minus the line's
---display width (minus one gap cell Neovim leaves before eol virt
---text). The body is display-width truncated to fit; when the whole
---budget drops below `EOL_MIN_WIDTH` the marker degrades to just
---`● <short-id>` and the window edge clips whatever still overflows.
---@param record table
---@param handle manicule.ui.render.Handle
---@param records table[] Current record snapshot (same-line stack counter)
local function render_eol_virt_text(record, handle, records)
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return
  end

  -- Follow the live anchor rather than the stored range so the marker
  -- tracks mid-edit line moves the same way popups do.
  local row = record_start_line(record) - 1
  local live = sync_handle_position(handle)
  if live then
    row = live.start_line - 1
  end
  local line_count = vim.api.nvim_buf_line_count(handle.bufnr)
  row = math.max(0, math.min(row, math.max(0, line_count - 1)))

  -- Budget: leftover cells after the line, in the window that shows the
  -- buffer (falls back to the full screen width for hidden buffers —
  -- the next reconcile after the buffer surfaces re-truncates).
  local win_width = vim.o.columns
  local anchor_win = find_window_for_buffer(handle.bufnr)
  if anchor_win then
    win_width = vim.api.nvim_win_get_width(anchor_win)
  end
  local line = vim.api.nvim_buf_get_lines(handle.bufnr, row, row + 1, false)[1] or ""
  local avail = win_width - vim.fn.strdisplaywidth(line) - 1

  local chunks = {
    { "● ", "ManiculeEolBullet" },
    { "c" .. short_id(record.id), "ManiculeEolMeta" },
  }
  if avail >= EOL_MIN_WIDTH then
    local stack_index, stack_total = same_line_stack_position(record, records)
    if stack_total > 1 then
      table.insert(chunks, { (" %d/%d"):format(stack_index, stack_total), "ManiculeEolMeta" })
    end
    local prefix_width = 0
    for _, chunk in ipairs(chunks) do
      prefix_width = prefix_width + vim.fn.strdisplaywidth(chunk[1])
    end
    local separator = " · "
    local body_budget = avail - prefix_width - vim.fn.strdisplaywidth(separator)
    local body = truncate_display(split_lines(record.body)[1] or "", body_budget)
    if body ~= "" then
      table.insert(chunks, { separator, "ManiculeEolBody" })
      table.insert(chunks, { body, "ManiculeEolBody" })
    end
  end

  local opts = {
    virt_text = chunks,
    virt_text_pos = "eol",
    priority = 220,
    -- Pure decoration — no `invalidate`, no `undo_restore`, no end
    -- range. Orphan detection stays on the primary anchor; this mark
    -- only carries the collapsed marker text.
  }
  if handle.eol_extmark_id then
    opts.id = handle.eol_extmark_id
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, handle.bufnr, anchor.ns, row, 0, opts)
  if ok then
    handle.eol_extmark_id = id
  end
end

-- ---------------------------------------------------------------------------
-- Inline virt_lines rendering ("inline" display mode's below-line boxes)
-- ---------------------------------------------------------------------------

-- One-cell gutter between the text column and the box's left edge.
local INLINE_INDENT = " "

-- Display cells the box frame consumes around the content on every
-- rendered line: indent (1) + left border (1) + inner padding (1 each
-- side) + right border (1). The content-width budget subtracts this so
-- the whole box fits the window.
local INLINE_FRAME_CELLS = 5

---Append one record's bordered box to `out` (a virt_lines list — each
---entry is one virtual line as `[text, hl]` chunks):
---  ┌ c<short-id> <n>/<m> ─────────────┐
---  │ body line (wrapped to width)     │
---  │ <Mon DD HH:MM> · edit … | delete…│
---  └──────────────────────────────────┘
---@param content manicule.ui.render.PopupContent
---@param out table[]
local function append_inline_box(content, out)
  local inner = content.width + 2
  local title = truncate_display(content.title, inner)
  table.insert(out, {
    { INLINE_INDENT, "NonText" },
    { "┌", "ManiculeInlineBorder" },
    { title, "ManiculeInlineMeta" },
    { string.rep("─", math.max(0, inner - vim.fn.strdisplaywidth(title))) .. "┐", "ManiculeInlineBorder" },
  })

  local function body_row(text, hl)
    local pad = math.max(0, content.width - vim.fn.strdisplaywidth(text))
    table.insert(out, {
      { INLINE_INDENT, "NonText" },
      { "│", "ManiculeInlineBorder" },
      { " " .. text .. string.rep(" ", pad) .. " ", hl },
      { "│", "ManiculeInlineBorder" },
    })
  end
  for _, line in ipairs(content.lines) do
    body_row(line, "ManiculeInlineBody")
  end
  if content.footer then
    body_row(truncate_display(content.footer, content.width), "ManiculeInlineMeta")
  end

  table.insert(out, {
    { INLINE_INDENT, "NonText" },
    { "└" .. string.rep("─", inner) .. "┘", "ManiculeInlineBorder" },
  })
end

---Render (or refresh) the below-line box block for `record`'s anchor
---line, as `virt_lines` on a sibling decoration-only extmark tracked as
---`handle.inline_extmark_id`. Renders for every record — no viewport or
---sticky gating (extmarks are cheap, like the eol marker).
---
---Same-line stacks: only the stack HEAD (first record on the line in
---`record_stack_less` order) owns the block — it renders every stack
---member's box sequentially in ONE virt_lines extmark, so box order is
---the comparator's, never sibling-extmark creation order. Non-head
---records get their inline extmark cleared. `M.reconcile` feeds every
---record of the buffer through here, so the head re-renders whenever
---any member changes, and deleting the head promotes the next record on
---the same reconcile pass.
---
---Anchoring: the block follows the live anchor extmark (mid-edit line
---moves) and sits at the record's range START line — a multi-line
---(visual-range) comment shows its box between the first commented line
---and the rest of the range, matching where the eol marker sits.
---@param record table
---@param handle manicule.ui.render.Handle
---@param records table[] Current record snapshot (stack + counter fallback)
---@param counter_records? table[] Current project/session snapshot (title count)
local function render_inline_virt_lines(record, handle, records, counter_records)
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return
  end

  local my_line = record_start_line(record)
  local my_id = tostring(record.id or "")
  local stack = {}
  for _, other in ipairs(records or {}) do
    if other.uri == record.uri and record_start_line(other) == my_line then
      table.insert(stack, other)
    end
  end
  table.sort(stack, record_stack_less)
  if #stack == 0 then
    stack = { record }
  end
  if tostring(stack[1].id or "") ~= my_id then
    -- Not the stack head: the head's handle owns the line's block.
    clear_inline_extmark(handle)
    return
  end

  -- Follow the live anchor rather than the stored range so the block
  -- tracks mid-edit line moves the same way popups and eol markers do.
  local row = my_line - 1
  local live = sync_handle_position(handle)
  if live then
    row = live.start_line - 1
  end
  local line_count = vim.api.nvim_buf_line_count(handle.bufnr)
  row = math.max(0, math.min(row, math.max(0, line_count - 1)))

  -- Content width: the float popup's width logic, additionally capped so
  -- the box frame fits the window that shows the buffer (falls back to
  -- the full screen width for hidden buffers — the next reconcile after
  -- the buffer surfaces re-fits).
  local win_width = vim.o.columns
  local anchor_win = find_window_for_buffer(handle.bufnr)
  if anchor_win then
    win_width = vim.api.nvim_win_get_width(anchor_win)
  end
  local max_width = math.max(8, math.min(popup_width_cap(win_width), win_width - INLINE_FRAME_CELLS))

  local virt_lines = {}
  for _, member in ipairs(stack) do
    local display_index, display_total = record_display_position(member, counter_records or records)
    append_inline_box(build_popup_content(member, max_width, display_index, display_total, true), virt_lines)
  end

  local opts = {
    virt_lines = virt_lines,
    priority = 220,
    -- Pure decoration — no `invalidate`, no `undo_restore`, no end
    -- range. Orphan detection stays on the primary anchor; this mark
    -- only carries the box block.
  }
  if handle.inline_extmark_id then
    opts.id = handle.inline_extmark_id
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, handle.bufnr, anchor.ns, row, 0, opts)
  if ok then
    handle.inline_extmark_id = id
  end
end

-- ---------------------------------------------------------------------------
-- Per-record reconcile helper
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@param record table
---@param records table[]
---@param counter_records? table[]
---@param tab table<string, manicule.ui.render.Handle>
local function reconcile_record(bufnr, record, records, counter_records, tab)
  local id = tostring(record.id or "")
  if id == "" then
    return
  end

  local handle = tab[id]

  if handle and handle.bufnr ~= bufnr then
    clear_handle(handle.bufnr, id)
    handle = nil
  end

  local is_new = not handle
  if not handle then
    ---@type manicule.ui.render.Handle
    handle = { bufnr = bufnr, extmark_id = 0 }
    tab[id] = handle
  end

  -- Invalidate existing popup so it re-renders with fresh content (e.g. after edit).
  if not is_new then
    hide_popup(handle)
  end

  -- (Re)create the anchor extmark unless an existing one is still
  -- tracking a live position. A stale extmark (sync returns nil) is
  -- reset so render_extmark places a fresh one.
  local needs_render = handle.extmark_id == 0
  if not needs_render and not sync_handle_position(handle) then
    handle.extmark_id = 0
    needs_render = true
  end
  if needs_render and not render_extmark(record, handle) then
    clear_handle(bufnr, id)
    return
  end

  -- Display-mode dispatch. The anchor extmark above renders in every
  -- mode; what else the record gets depends on the live mode:
  --   float  -> sticky schedules the popup below; non-sticky popups
  --             come from `update_viewport_popups` (today's behavior)
  --   eol    -> collapsed marker here (for every record — viewport /
  --             sticky is a float concern); the full popup expands from
  --             the viewport pass while the cursor sits on the line
  --   inline -> below-line box block here (for every record, like eol);
  --             no popups ever — see the header
  --   hidden -> nothing beyond the anchor
  local mode = current_display_mode()
  if mode == "eol" then
    render_eol_virt_text(record, handle, records)
  else
    clear_eol_extmark(handle)
  end
  if mode == "inline" then
    render_inline_virt_lines(record, handle, records, counter_records)
  else
    clear_inline_extmark(handle)
  end

  if mode == "float" and is_sticky() then
    local hdl = handle
    vim.schedule(function()
      -- A stale scheduled render must do nothing if, by the time it
      -- runs, the buffer was unloaded/wiped (BufUnload/BufDelete ->
      -- clear_buffer) or the handle was cleared/replaced (record deleted
      -- or re-keyed) between the schedule and the callback. Without these
      -- guards `render_comment_popup` would open an orphaned float over a
      -- dead/detached handle that nothing tears down.
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local live = handles[bufnr]
      if not live or live[id] ~= hdl then
        return
      end
      if not hdl.extmark_id or hdl.extmark_id == 0 then
        return
      end
      render_comment_popup(record, hdl, records, counter_records)
      -- Coalesce the orphan-prune + dedup sweeps to ONCE per reconcile
      -- batch instead of per-record. The sweeps are global and run on a
      -- later scheduled tick, so every record's float in this batch is
      -- rendered (and thus tracked) before they fire — same final popup
      -- set as the old per-record sweep, without the O(N) repeat work.
      schedule_popup_sweeps()
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Initialize highlights. Call once during setup.
function M.setup()
  setup_comment_highlights()
  -- On a plugin reload the Lua module reloads with a fresh empty
  -- `handles`, but the OLD instance's tagged popup windows are still open
  -- and now untracked — close them here. On a normal first load there are
  -- no tagged floats, so this is a no-op.
  prune_orphan_popups()
end

--- Close every tagged manicule popup float that no live handle tracks.
--- Self-heals orphaned/duplicate popups (handle lost track of the float,
--- or the handle table was reset on plugin reload). Cannot close a
--- legitimately-tracked popup because tracked floats are always retained.
function M.prune_orphan_popups()
  prune_orphan_popups()
end

--- Collapse duplicate *tracked* popup floats so a record id shows at most
--- one popup across all buffers/windows. Used when a file is open in two
--- same-URI buffers (e.g. the working file + a codediff view) so the
--- comment popup doesn't render once per diff side. Keeps the entry in
--- the current buffer (follows focus), else the lowest bufnr; the loser's
--- anchor extmark + line tint are untouched.
function M.dedup_popups()
  dedup_popups()
end

--- Reapply highlights after colorscheme change.
function M.refresh_highlights()
  setup_comment_highlights()
end

--- Winhighlight string shared by popups and the editor.
---@return string
function M.winhighlight()
  return comment_winhighlight()
end

--- Reconcile rendered state for a buffer. Shows/updates/hides popups
--- based on `records`. Handles whose ids no longer appear in `records`
--- are torn down. Idempotent — safe to call from any autocmd.
---
--- When visuals are suppressed via `M.hide()`, this function no-ops so
--- mutations that arrive while hidden (e.g. a `ManiculeAdded` that
--- kicks off reconcile) don't paint. The next `M.show()` rebuilds
--- everything from the store snapshot.
---@param bufnr integer
---@param records table[]
---@param counter_records? table[]
function M.reconcile(bufnr, records, counter_records)
  if hidden then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local tab = get_buf_handles(bufnr)
  local live = {}

  for _, record in ipairs(records or {}) do
    local id = tostring(record.id or "")
    if id ~= "" then
      live[id] = true
      reconcile_record(bufnr, record, records, counter_records, tab)
    end
  end

  for id, _ in pairs(tab) do
    if not live[id] then
      clear_handle(bufnr, id)
    end
  end
end

--- Non-sticky viewport update: show popups only for records whose line
--- is currently visible in some window showing `bufnr`. Records outside
--- the viewport have their popup hidden (the handle + extmark survive).
---
--- Display-mode aware: under "eol" the visibility test is the cursor
--- line instead of the viewport (expand-on-demand — see the header);
--- under "inline" and "hidden" every popup is torn down (inline's boxes
--- already show the full comment and are owned by reconcile, not this
--- pass). "float" keeps the viewport behavior.
---
--- Gated on `M.is_hidden()` — returns immediately so scroll / resize
--- autocmds that fire while visuals are suppressed don't re-paint.
---@param bufnr integer
---@param records table[]
---@param counter_records? table[]
function M.update_viewport_popups(bufnr, records, counter_records)
  if hidden then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local tab = handles[bufnr]
  if not tab then
    return
  end

  local mode = current_display_mode()
  if mode == "hidden" or mode == "inline" then
    -- No popups in these modes, ever: hidden renders anchors only, and
    -- inline's virt_lines boxes (rendered by reconcile) already show the
    -- full comment — a cursor-line popup would only duplicate visible
    -- content (and, being `focusable = false`, add no interaction;
    -- edit/delete go through `record_at_cursor` on the anchor line).
    -- Sweep untracked tagged floats too so a mode switch clears strays.
    for _, handle in pairs(tab) do
      hide_popup(handle)
    end
    prune_orphan_popups()
    return
  end

  -- Pick the window that should own this buffer's transient popups. The
  -- renderer currently has one popup handle per record, so when a buffer is
  -- visible in multiple windows we prefer the current window and otherwise
  -- fall back to the first matching window.
  local ranges = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      local top = vim.fn.line("w0", winid)
      local bot = vim.fn.line("w$", winid)
      table.insert(ranges, { winid = winid, top = top, bot = bot })
    end
  end
  local active_range = ranges[1]
  local current_win = vim.api.nvim_get_current_win()
  for _, range in ipairs(ranges) do
    if range.winid == current_win then
      active_range = range
      break
    end
  end

  local layouts = {}
  if active_range then
    local visible = {}
    if mode == "eol" then
      -- Expand-on-demand: only records covering the cursor line (in the
      -- window that owns this buffer's popups) show their full popup;
      -- everything else stays a collapsed eol marker. CursorMoved feeds
      -- this through init.lua's coalesced viewport refresh, so moving
      -- onto a line expands and moving off closes.
      local cursor_line = vim.api.nvim_win_get_cursor(active_range.winid)[1]
      for _, record in ipairs(records or {}) do
        local start_line = record_start_line(record)
        local end_line = record_end_line(record) or start_line
        if cursor_line >= start_line and cursor_line <= end_line then
          table.insert(visible, record)
        end
      end
    else
      for _, record in ipairs(records or {}) do
        local line = record_start_line(record)
        if line >= active_range.top and line <= active_range.bot then
          table.insert(visible, record)
        end
      end
    end
    table.sort(visible, record_layout_less)

    -- Precompute title-counter positions ONCE for the whole viewport
    -- (sharing each scope group's sort) instead of letting every
    -- per-record `render_comment_popup` re-scan + re-sort the counter set.
    local display = precompute_display_positions(visible, counter_records or records)

    -- Group the visible records by anchor line (adjacent after the
    -- sort): the occlusion-aware placement decision is made per
    -- same-line stack, and a stack relocates as a unit — never split
    -- between the margin and the below-anchor spot.
    local groups = {}
    for _, record in ipairs(visible) do
      local line = record_start_line(record)
      local group = groups[#groups]
      if not group or group.line ~= line then
        group = { line = line, records = {} }
        table.insert(groups, group)
      end
      table.insert(group.records, record)
    end

    local win_width = vim.api.nvim_win_get_width(active_range.winid)
    local width_cap = popup_width_cap(win_width)

    local next_top
    local stagger = 0
    for _, group in ipairs(groups) do
      -- The group's would-be margin geometry: today's cascade rows +
      -- stagger columns, computed against trial copies of the cascade
      -- state so a group that relocates leaves the margin cascade
      -- untouched (its rows/stagger stay available to later margin
      -- popups — a relocated stack no longer occupies the margin).
      local entries = {}
      local group_next_top = next_top
      local group_stagger = stagger
      local natural_top = group.line - active_range.top
      for _, record in ipairs(group.records) do
        group_stagger = group_stagger + 1
        local body_height = popup_body_height(record)
        local row = 0
        if group_next_top and natural_top < group_next_top then
          row = group_next_top - natural_top
        end
        group_next_top = natural_top + row + body_height + 2
        local col_shift = math.min((group_stagger - 1) * 2, 12)
        table.insert(entries, {
          record = record,
          row = row,
          height = body_height,
          col_shift = col_shift,
          col = margin_col(win_width, popup_content_width(record, width_cap), col_shift),
        })
      end

      if margin_spot_is_clear(bufnr, group.line, entries) then
        -- Margin spot rests on empty cells: place exactly as before and
        -- advance the cascade.
        next_top = group_next_top
        stagger = group_stagger
        for _, entry in ipairs(entries) do
          layouts[tostring(entry.record.id or "")] = {
            winid = active_range.winid,
            placement = "margin",
            row = entry.row,
            col_shift = entry.col_shift,
            display = display[tostring(entry.record.id or "")],
          }
        end
      else
        -- The margin would cover code: the whole stack falls back below
        -- the anchor line (above when the window bottom leaves no room),
        -- left-aligned like the inline box, still vertically stacked.
        local total = 0
        for _, entry in ipairs(entries) do
          total = total + entry.height + 2
        end
        local direction = fallback_direction(active_range.winid, group.line, total)
        local offset = direction == "below" and 1 or -total
        for _, entry in ipairs(entries) do
          layouts[tostring(entry.record.id or "")] = {
            winid = active_range.winid,
            placement = direction,
            row = offset,
            col_shift = 0,
            display = display[tostring(entry.record.id or "")],
          }
          offset = offset + entry.height + 2
        end
      end
    end
  end

  for _, record in ipairs(records or {}) do
    local id = tostring(record.id or "")
    local handle = tab[id]
    if handle then
      local layout = layouts[id]
      if layout then
        render_comment_popup(record, handle, records, counter_records, layout)
      else
        hide_popup(handle)
      end
    end
  end

  -- Sweep orphans after the render/hide loop so duplicates self-heal on
  -- the next viewport update. Every popup just rendered above is tracked
  -- (its winid is on a live handle), so only untracked floats are closed.
  prune_orphan_popups()
  -- Then collapse duplicate *tracked* popups: a same-URI sibling buffer
  -- (e.g. a codediff view) tracks its own float for the same record id, so
  -- close all but one. This runs on every refresh_viewport (scroll/focus
  -- change) + refresh_all_loaded, so it self-heals and follows focus.
  dedup_popups()
end

--- Hide every popup owned for `bufnr`. Extmarks + handles survive so
--- the next reconcile/viewport-update can rebuild the popups.
---@param bufnr integer
function M.hide_all_popups(bufnr)
  local tab = handles[bufnr]
  if not tab then
    return
  end
  for _, handle in pairs(tab) do
    hide_popup(handle)
  end
end

--- Capture position updates from extmarks. Pure data: the caller is
--- responsible for applying the returned patches to the store.
---@param bufnr integer
---@param records table[]
---@return { updates: { id: string, range: { start: integer[], end_: integer[] } }[], stale_ids: string[] }
function M.capture_position_patches(bufnr, records)
  local tab = handles[bufnr] or {}
  local updates = {}
  local stale_ids = {}

  for _, record in ipairs(records or {}) do
    local id = tostring(record.id or "")
    local handle = tab[id]
    if not handle or not handle.extmark_id or handle.extmark_id == 0 then
      table.insert(stale_ids, id)
    else
      local pos = sync_handle_position(handle)
      if not pos then
        table.insert(stale_ids, id)
      else
        local stored_start = record_start_line(record)
        local stored_end = record_end_line(record)
        local moved = pos.start_line ~= stored_start
        if not moved and stored_end and pos.end_line and pos.end_line ~= stored_end then
          moved = true
        end
        if moved then
          local start_col = record.range and record.range.start and record.range.start[2] or 0
          local end_col = record.range and record.range.end_ and record.range.end_[2] or start_col
          local new_end_row
          if pos.end_line then
            new_end_row = pos.end_line - 1
          else
            new_end_row = pos.start_line - 1
          end
          table.insert(updates, {
            id = id,
            range = {
              start = { pos.start_line - 1, start_col },
              end_ = { new_end_row, end_col },
            },
          })
        end
      end
    end
  end

  return { updates = updates, stale_ids = stale_ids }
end

--- Resolve the comment id whose extmark covers the current cursor line
--- in `bufnr`. Used by `<Plug>(manicule-edit)` / `<Plug>(manicule-delete)`
--- and the default `gca` / `gcd` keymaps. Returns nil when no comment
--- sits on the cursor line.
---@param bufnr integer
---@return string?
function M.record_at_cursor(bufnr)
  bufnr = bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  -- `anchor.resolve` calls `nvim_buf_get_extmark_by_id` without its own
  -- buffer-validity guard, which throws "Invalid buffer id" if `bufnr`
  -- has been wiped out from under the `gca`/`gcd`/edit keymap handler.
  -- Bail to the no-match path before we reach it.
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local tab = handles[bufnr]
  if not tab or vim.tbl_isempty(tab) then
    return nil
  end
  local cur_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  for id, handle in pairs(tab) do
    if handle.extmark_id and handle.extmark_id ~= 0 then
      local resolved = anchor.resolve(bufnr, handle.extmark_id)
      if resolved and not resolved.invalid then
        local sr = resolved.range.start[1]
        local er = resolved.range.end_[1]
        if cur_line >= sr and cur_line <= er then
          return id
        end
      end
    end
  end
  return nil
end

--- Return `{ [comment_id] = extmark_id }` for a buffer. Useful for
--- cursor hit-testing in `<Plug>` maps without cracking open the
--- internal handle table.
---@param bufnr integer
---@return table<string, integer>
function M.mark_ids_for_buffer(bufnr)
  local tab = handles[bufnr]
  if not tab then
    return {}
  end
  local out = {}
  for id, handle in pairs(tab) do
    if handle.extmark_id and handle.extmark_id ~= 0 then
      out[id] = handle.extmark_id
    end
  end
  return out
end

--- Clear every handle for `bufnr`.
---@param bufnr integer
function M.clear_buffer(bufnr)
  local tab = handles[bufnr]
  if not tab then
    return
  end
  for id, _ in pairs(tab) do
    clear_handle(bufnr, id)
  end
  handles[bufnr] = nil
end

--- Reset every tracked handle across all buffers.
function M.clear_all()
  for bufnr, _ in pairs(handles) do
    M.clear_buffer(bufnr)
  end
  handles = {}
end

--- Return the current visibility flag. `true` means all visuals are
--- suppressed; popups are gone and decoration extmarks have been
--- cleared. Anchor extmarks remain (orphan detection keeps working).
---@return boolean
function M.is_hidden()
  return hidden
end

--- Suppress every manicule visual (popup + line-number tint) across
--- every tracked buffer. The store is untouched — records persist,
--- anchor extmarks stay alive (with `invalidate = true` still
--- tracking edits), only the paint is gone. Idempotent.
function M.hide()
  if hidden then
    return
  end
  hidden = true
  for bufnr, tab in pairs(handles) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, handle in pairs(tab) do
        strip_handle_visuals(handle)
      end
    end
  end
end

---Re-render every loaded buffer from the store snapshot — the same
---reconcile + viewport-refresh path used at setup. Shared by `M.show`
---and `M.set_display_mode` so a visibility restore and a live mode
---switch repaint identically. Lazy-requires `manicule.store` so the
---render module doesn't grow a hard dep on persistence.
local function repaint_all_loaded()
  local ok_store, store = pcall(require, "manicule.store")
  if not ok_store then
    return
  end
  local adapter = require("manicule.adapter")
  store.session_load()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local identity = adapter.identify(bufnr)
      if identity and identity.uri and identity.diff_side ~= "reference" then
        if identity.project_root then
          store.load(identity.project_root)
        end
        local records = store.all_for_uri(identity.uri, identity.project_root)
        local counter_records = identity.project_root and store.all(identity.project_root) or store.session_all()
        M.reconcile(bufnr, records, counter_records)
        M.update_viewport_popups(bufnr, records, counter_records)
      end
    end
  end
end

--- Restore visuals across every loaded buffer by re-running the same
--- reconcile + viewport-refresh path used at setup. Safe to call even
--- when already visible (idempotent no-op).
function M.show()
  if not hidden then
    return
  end
  hidden = false
  repaint_all_loaded()
end

--- Flip the visibility flag and apply. Fires a `User ManiculeVisibility`
--- autocmd with `data = { hidden = <bool> }` so external observers can
--- react (status line, etc).
function M.toggle()
  if hidden then
    M.show()
  else
    M.hide()
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ManiculeVisibility",
    data = { hidden = hidden },
  })
end

--- Return the live display mode (see the header for what each mode
--- renders). Falls back to `config.get().ui.display` until the first
--- runtime switch.
---@return "float"|"eol"|"inline"|"hidden"
function M.display_mode()
  return current_display_mode()
end

--- Switch the display mode and repaint every loaded buffer so the
--- change is visible immediately. `mode = nil`/`""` cycles
--- float → eol → inline → hidden → float (`:ManiculeDisplay` bare /
--- `<Plug>(manicule-display-cycle)`); an unknown mode is rejected with
--- an ERROR notify and leaves the current mode untouched.
---@param mode? "float"|"eol"|"inline"|"hidden"
---@return string? mode, string? err
function M.set_display_mode(mode)
  if mode == nil or mode == "" then
    local cur = current_display_mode()
    for index, candidate in ipairs(DISPLAY_MODES) do
      if candidate == cur then
        mode = DISPLAY_MODES[index % #DISPLAY_MODES + 1]
        break
      end
    end
  end
  if not VALID_DISPLAY_MODES[mode] then
    local err = ('manicule: display mode must be "float", "eol", "inline", or "hidden", got %q'):format(tostring(mode))
    vim.notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  display_mode = mode
  -- Repaint no-ops while visuals are toggled off (`M.hide`); the mode
  -- still sticks and the next `M.show` paints with it.
  repaint_all_loaded()
  vim.notify(("manicule: display = %s"):format(mode), vim.log.levels.INFO)
  return mode
end

--- Internal: reset state. Used by tests.
function M._reset_for_tests()
  hidden = false
  display_mode = nil
  M.clear_all()
end

return M
