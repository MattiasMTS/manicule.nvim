-- manicule.nvim: tiny unique id generator.
--
-- Not a UUID. Combines the high-resolution monotonic clock with 4 random
-- hex chars so collisions within a single Neovim session are unlikely
-- enough to ignore. Good enough for a single-user, per-project store.

local M = {}

---Generate a new unique id.
---@return string
function M.new()
  local hr = (vim.uv or vim.loop).hrtime()
  return string.format("%x-%04x", hr, math.random(0, 0xffff))
end

return M
