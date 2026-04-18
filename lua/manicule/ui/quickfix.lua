-- manicule.nvim: quickfix formatter for comment records.
--
-- Ported from codediff.nvim's `ui/comments/quickfix.lua`. Adapted to
-- manicule's record shape (no `side`, `id` is a string, range carries
-- row/col pairs). Grouping follows codediff: sort by path, then by
-- start line, then by id so order is stable across reloads.

local M = {}

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
    local ap = tostring(a.path or "")
    local bp = tostring(b.path or "")
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
      filename = r.path,
      lnum = start_line(r),
      col = start_col(r),
      type = r.resolved and "N" or "I",
      text = format_text(r),
    }
    table.insert(items, item)
  end
  return items
end

--- Build quickfix items without opening. Useful for tests / external callers.
---@param records table[]
---@return table[]
function M.build_items(records)
  return build_items(records)
end

--- Populate the quickfix list and (optionally) open it.
---@param records table[]
---@param opts? { open?: boolean }
function M.show(records, opts)
  opts = opts or {}
  local items = build_items(records)
  local title = string.format("manicule (%d)", #items)
  vim.fn.setqflist({}, " ", { title = title, items = items })
  if opts.open ~= false and #items > 0 then
    vim.cmd("copen")
  end
end

return M
