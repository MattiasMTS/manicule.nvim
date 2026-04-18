-- manicule.nvim: reference sink — copies formatted comments into the
-- system clipboard register ("+"). Serves as a minimal implementation
-- template for more involved sinks (PR drafts, webhooks, etc.).

local M = {}

M.spec = {
  name = "clipboard",
  format = function(c)
    local line = (c.range and c.range.start and c.range.start[1] or 0) + 1
    return string.format("%s:%d: %s", c.path or "?", line, c.body or "")
  end,
  send = function(comments, _ctx, cb)
    local lines = {}
    for _, c in ipairs(comments) do
      table.insert(lines, M.spec.format(c))
    end
    vim.fn.setreg("+", table.concat(lines, "\n"))
    if cb then
      cb(true)
    end
  end,
}

return M
