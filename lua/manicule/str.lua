-- manicule.nvim: small string helpers shared across surfaces.
--
-- Centralises two formatting primitives that were duplicated byte-for-byte
-- in the renderer, the quickfix formatter, and the floating editor:
--   * `split_lines` — newline split with an empty-string guard so callers
--     always get at least one line to render.
--   * `truncate` — byte-length-based ellipsis truncation.
--
-- Note: the gmatch / CRLF-aware splitters in `sinks/helpers.lua` and
-- `sinks/cmux.lua` have deliberately different semantics (empty-line and
-- carriage-return handling) and are NOT folded in here.

local M = {}

---Split `text` on newlines, returning at least one (empty) line so the
---caller always has something to render.
---@param text string?
---@return string[]
function M.split_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

---Truncate `text` to `max_width` bytes, appending an ellipsis when the
---text is cut. Byte-length based (not display width) to match the
---historical behaviour of the call sites.
---@param text string
---@param max_width integer
---@return string
function M.truncate(text, max_width)
  if #text <= max_width then
    return text
  end
  if max_width <= 3 then
    return text:sub(1, max_width)
  end
  return text:sub(1, max_width - 3) .. "..."
end

return M
