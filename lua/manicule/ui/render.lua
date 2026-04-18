-- manicule.nvim: per-comment floating popup renderer.
--
-- Ported from codediff.nvim's `ui/comments/render.lua` (PR #332). For
-- each live record we own a Handle that carries the anchor extmark id,
-- the popup window id, and the popup scratch buffer. `reconcile` is
-- idempotent: it creates, updates, and tears down popups based on the
-- records currently belonging to a buffer.
--
-- manicule is buffer-agnostic, so the keying is `[bufnr][comment_id]`
-- rather than codediff's `[tabpage][comment_id]` / diff-side /
-- session-keyed layout. A record "belongs to" a buffer when the
-- buffer's project-relative path equals `record.path`.
--
-- Sticky vs non-sticky is driven by `config.get().ui.sticky`:
--   * sticky  = true  -> popups are always shown for every record in
--                        the buffer (reconcile renders them)
--   * sticky  = false -> popups are only shown for records whose line
--                        is in the current viewport (update_viewport_popups)

local M = {}

local anchor = require("manicule.anchor")
local float = require("manicule.ui.float")
local config = require("manicule.config")

---@class manicule.ui.render.Handle
---@field bufnr integer Buffer the extmark is placed in
---@field extmark_id integer
---@field popup_winid? integer
---@field popup_bufnr? integer

--- handles[bufnr][comment_id] = Handle
---@type table<integer, table<string, manicule.ui.render.Handle>>
local handles = {}

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

local DEFAULT_BORDER_FG = 0xA6ADC8

local function setup_comment_highlights()
  local border_fg = DEFAULT_BORDER_FG
  local border_bg = "NONE"
  local ok_hl, normal_hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if ok_hl and normal_hl then
    if type(normal_hl.fg) == "number" then
      border_fg = normal_hl.fg
    end
    if type(normal_hl.bg) == "number" then
      border_bg = normal_hl.bg
    end
  end

  local meta_fg = border_fg
  local ok_comment_hl, comment_hl = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
  if ok_comment_hl and comment_hl and type(comment_hl.fg) == "number" then
    meta_fg = comment_hl.fg
  end

  vim.api.nvim_set_hl(0, "ManiculeCommentBorder", { fg = border_fg, bg = border_bg })
  vim.api.nvim_set_hl(0, "ManiculeCommentMeta", { fg = meta_fg, bg = border_bg })
  vim.api.nvim_set_hl(0, "ManiculeLineNr", { link = "DiagnosticSignInfo", default = true })
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

---@return string
local function comment_winhighlight()
  return "NormalFloat:NormalFloat,FloatBorder:ManiculeCommentBorder,FloatTitle:ManiculeCommentMeta,FloatFooter:ManiculeCommentMeta"
end

---@param text string?
---@return string[]
local function split_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

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

---Build the edit/delete hint shown in the popup footer. We pull from
---`config.get().keymaps` when available (user-configured), otherwise
---fall back to a hard-coded `<Plug>`-style hint that matches the
---bindings shipped in `plugin/manicule.lua`.
---@return string?
local function comment_hint_text()
  local cfg = config.get() or {}
  local keymaps = cfg.keymaps or {}
  local parts = {}
  if type(keymaps.edit) == "string" and keymaps.edit ~= "" then
    table.insert(parts, "edit " .. keymaps.edit)
  end
  if type(keymaps.delete) == "string" and keymaps.delete ~= "" then
    table.insert(parts, "delete " .. keymaps.delete)
  end
  if #parts == 0 then
    return "edit gca | delete gcd"
  end
  return table.concat(parts, " | ")
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

-- ---------------------------------------------------------------------------
-- Handle lifecycle
-- ---------------------------------------------------------------------------

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

  if handle.extmark_id and handle.extmark_id ~= 0 and vim.api.nvim_buf_is_valid(handle.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, handle.bufnr, anchor.ns, handle.extmark_id)
  end
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

  local opts = {
    end_row = end_row,
    end_col = end_col,
    invalidate = true,
    undo_restore = false,
    priority = 220,
    -- number_hl_group only tints the start line; matches codediff
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
  return true
end

-- ---------------------------------------------------------------------------
-- Popup rendering
-- ---------------------------------------------------------------------------

---Render (or reconfigure) the comment popup for `record`. Returns true
---when the handle is healthy (regardless of whether the popup ended up
---visible — a missing anchor window hides the popup but keeps the
---handle alive).
---@param record table
---@param handle manicule.ui.render.Handle
---@param records table[] Current record snapshot (used for stack offset)
---@return boolean
local function render_comment_popup(record, handle, records)
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return false
  end

  local anchor_win = find_window_for_buffer(handle.bufnr)
  if not anchor_win then
    hide_popup(handle)
    return true
  end

  local hint = comment_hint_text()
  local body_lines = split_lines(record.body)

  local max_line_width = 0
  for _, line in ipairs(body_lines) do
    max_line_width = math.max(max_line_width, vim.fn.strdisplaywidth(line))
  end
  if max_line_width == 0 then
    max_line_width = 1
  end

  local win_width = vim.api.nvim_win_get_width(anchor_win)
  local max_popup_width = math.max(24, math.floor(win_width * 0.52))
  local hint_width = hint and vim.fn.strdisplaywidth(hint) or 0
  local content_width = math.min(math.max(max_line_width, hint_width), max_popup_width)

  local display_lines = {}
  for _, line in ipairs(body_lines) do
    table.insert(display_lines, truncate_text(line, content_width))
  end

  local my_line = record_start_line(record)
  local tab = handles[handle.bufnr] or {}
  local my_id = tostring(record.id or "")

  -- Same-line records with a lower id stack above us.
  local stack_offset = 0
  for _, other in ipairs(records) do
    local other_id = tostring(other.id or "")
    if other_id ~= my_id and other.path == record.path and record_start_line(other) == my_line and other_id < my_id then
      if tab[other_id] then
        stack_offset = stack_offset + 1
      end
    end
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
    row = stack_offset,
    col = math.max(2, win_width - content_width - 6),
    width = content_width,
    height = math.max(1, #display_lines),
    style = "minimal",
    focusable = false,
    zindex = 210,
    noautocmd = true,
  }

  local border = "rounded"
  win_config.border = border

  float.apply_title_footer(win_config, border, string.format(" c%s ", short_id(record.id)), "left", hint or nil, "left")

  local popup_winid = float.open_or_reconfigure(handle.popup_winid, popup_bufnr, false, win_config)
  handle.popup_winid = popup_winid

  vim.bo[popup_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup_bufnr, 0, -1, false, display_lines)
  vim.bo[popup_bufnr].modifiable = false

  float.set_float_win_options(popup_winid, comment_winhighlight())

  local opacity = ((config.get() or {}).ui or {}).opacity or 0
  if type(opacity) ~= "number" then
    opacity = 0
  end
  vim.wo[popup_winid].winblend = math.max(0, math.min(100, opacity))

  return true
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
-- Per-record reconcile helper
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@param record table
---@param records table[]
---@param tab table<string, manicule.ui.render.Handle>
local function reconcile_record(bufnr, record, records, tab)
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

  if handle.extmark_id ~= 0 then
    local pos = sync_handle_position(handle)
    if not pos then
      handle.extmark_id = 0
      if not render_extmark(record, handle) then
        clear_handle(bufnr, id)
        return
      end
    end
  else
    if not render_extmark(record, handle) then
      clear_handle(bufnr, id)
      return
    end
  end

  if is_sticky() then
    local rec = record
    local hdl = handle
    local snapshot = records
    vim.schedule(function()
      if not hdl.extmark_id or hdl.extmark_id == 0 then
        return
      end
      render_comment_popup(rec, hdl, snapshot)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Initialize highlights. Call once during setup.
function M.setup()
  setup_comment_highlights()
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
---@param bufnr integer
---@param records table[]
function M.reconcile(bufnr, records)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local tab = get_buf_handles(bufnr)
  local live = {}

  for _, record in ipairs(records or {}) do
    local id = tostring(record.id or "")
    if id ~= "" then
      live[id] = true
      reconcile_record(bufnr, record, records, tab)
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
---@param bufnr integer
---@param records table[]
function M.update_viewport_popups(bufnr, records)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local tab = handles[bufnr]
  if not tab then
    return
  end

  -- Collect visible ranges from every window currently showing this buffer.
  local ranges = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      local top = vim.fn.line("w0", winid)
      local bot = vim.fn.line("w$", winid)
      table.insert(ranges, { top = top, bot = bot })
    end
  end

  for _, record in ipairs(records or {}) do
    local id = tostring(record.id or "")
    local handle = tab[id]
    if handle then
      local line = record_start_line(record)
      local in_view = false
      for _, r in ipairs(ranges) do
        if line >= r.top and line <= r.bot then
          in_view = true
          break
        end
      end

      if in_view then
        if not handle.popup_winid or not vim.api.nvim_win_is_valid(handle.popup_winid) then
          render_comment_popup(record, handle, records)
        end
      else
        hide_popup(handle)
      end
    end
  end
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

--- Internal: reset state. Used by tests.
function M._reset_for_tests()
  M.clear_all()
end

return M
