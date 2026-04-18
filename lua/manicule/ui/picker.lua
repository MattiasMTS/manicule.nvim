-- manicule.nvim: vim.ui.select picker for the edit / delete / resolve
-- commands.
--
-- The picker renders records in the same order as `:ManiculeList` (see
-- `init.list`, which sorts by path → start line → id). Each command's
-- completion returns raw positional numbers `"1"`..`"N"`; the picker is
-- the surface where those numbers get a human face.
--
-- Items are paired `{ record = r, display = "..." }` tables so the
-- `format_item` callback is a trivial field lookup instead of doing an
-- identity-map dance, and the action callback reaches the record id via
-- `chosen.record.id`.

local M = {}

local BODY_MAX = 50
local LOCATION_MAX = 28
local ELLIPSIS = "…"
local COLUMN_SEPARATOR = " │ "
local RESOLVED_PREFIX = "[✓] "

---Strip control characters and collapse whitespace so a single body line
---is safe to render in `vim.ui.select` (which forbids newlines).
---@param s string
---@return string
local function sanitize(s)
  if not s or s == "" then
    return ""
  end
  -- Tabs → spaces, then drop remaining C0 control bytes. Keep it ASCII-
  -- safe; Neovim's select backends handle UTF-8 transparently.
  s = s:gsub("\t", " ")
  s = s:gsub("[%z\1-\8\11\12\14-\31\127]", "")
  return s
end

---Return the first non-empty line of `body`.
---@param body string|nil
---@return string
local function first_nonempty_line(body)
  if not body or body == "" then
    return ""
  end
  for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    if trimmed ~= "" then
      return trimmed
    end
  end
  return ""
end

---Compute the display width of a string in cells (treats any non-ASCII
---byte as width 1 because `vim.fn.strdisplaywidth` isn't available in
---every test harness and the picker target widths are approximate).
---@param s string
---@return integer
local function width(s)
  return vim.fn.strdisplaywidth(s)
end

---Right-truncate `s` to `max` display cells, appending an ellipsis when
---the input exceeds the budget. No-op when already short enough.
---@param s string
---@param max integer
---@return string
local function truncate_right(s, max)
  if width(s) <= max then
    return s
  end
  if max <= 1 then
    return s:sub(1, max)
  end
  -- Greedy shrink: keep popping bytes until width fits with an ellipsis.
  local budget = max - width(ELLIPSIS)
  while width(s) > budget and #s > 0 do
    s = s:sub(1, -2)
  end
  return s .. ELLIPSIS
end

---Left-truncate `s` to `max` display cells, prepending an ellipsis when
---the input exceeds the budget. Used for paths so the filename stays
---visible.
---@param s string
---@param max integer
---@return string
local function truncate_left(s, max)
  if width(s) <= max then
    return s
  end
  if max <= 1 then
    return s:sub(-max)
  end
  local budget = max - width(ELLIPSIS)
  while width(s) > budget and #s > 0 do
    s = s:sub(2)
  end
  return ELLIPSIS .. s
end

---Pad `s` on the right with spaces up to `w` display cells.
---@param s string
---@param w integer
---@return string
local function rpad(s, w)
  local delta = w - width(s)
  if delta <= 0 then
    return s
  end
  return s .. string.rep(" ", delta)
end

---Pad `s` on the left with spaces up to `w` display cells.
---@param s string
---@param w integer
---@return string
local function lpad(s, w)
  local delta = w - width(s)
  if delta <= 0 then
    return s
  end
  return string.rep(" ", delta) .. s
end

---Build the `<path>:<line>` or `<path>:<start>-<end>` string for a
---record, applying the left-truncation budget so the column stays
---aligned.
---@param record table
---@return string
local function location_for(record)
  local path = tostring(record.path or "")
  local line
  if record.range and record.range.start then
    local sl = (record.range.start[1] or 0) + 1
    local el_row
    if record.range.end_ and type(record.range.end_[1]) == "number" then
      el_row = record.range.end_[1] + 1
    end
    if el_row and el_row > sl then
      line = string.format("%d-%d", sl, el_row)
    else
      line = tostring(sl)
    end
  else
    line = "1"
  end
  local suffix = ":" .. line
  local path_budget = LOCATION_MAX - width(suffix)
  if path_budget < 1 then
    path_budget = 1
  end
  return truncate_left(path, path_budget) .. suffix
end

---Build the body column for a record, prefixing resolved entries with
---`[✓] ` so they're visibly done.
---@param record table
---@return string
local function body_for(record)
  local text = sanitize(first_nonempty_line(record.body))
  if record.resolved then
    text = RESOLVED_PREFIX .. text
  end
  return truncate_right(text, BODY_MAX)
end

---Format `records` into display strings, parallel-indexed to `records`.
---Callers can zip into `{ record, display }` tables or map over the
---result directly.
---@param records table[]
---@return string[]
function M.format_items(records)
  local out = {}
  local count = #records
  local idx_width = #tostring(math.max(count, 1))
  for i, r in ipairs(records) do
    local idx = lpad(tostring(i), idx_width)
    local loc = rpad(location_for(r), LOCATION_MAX)
    local body = body_for(r)
    out[i] = idx .. COLUMN_SEPARATOR .. loc .. COLUMN_SEPARATOR .. body
  end
  return out
end

---Open `vim.ui.select` for `records` and invoke
---`require("manicule")[action](chosen.id)` on the picked record. No-op
---with an INFO notification when there are no records.
---@param action "edit"|"delete"|"resolve"
---@param records table[]
function M.pick(action, records)
  if not records or #records == 0 then
    vim.notify("manicule: no comments", vim.log.levels.INFO)
    return
  end
  local formatted = M.format_items(records)
  local items = {}
  for i, r in ipairs(records) do
    items[i] = { record = r, display = formatted[i] }
  end
  vim.ui.select(items, {
    prompt = ("Manicule: %s comment"):format(action),
    format_item = function(item)
      return item.display
    end,
  }, function(chosen)
    if not chosen then
      return
    end
    require("manicule")[action](chosen.record.id)
  end)
end

return M
