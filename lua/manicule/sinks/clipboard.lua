-- manicule.nvim: reference sink — copies formatted comments into the
-- system clipboard register ("+"). Serves as a minimal implementation
-- template for more involved sinks (PR drafts, webhooks, etc.).

local M = {}

function M.setup()
  return M.spec
end

M.spec = {
  name = "clipboard",
  type = "sink",
  label = "Clipboard",
  description = "copy formatted comments to the + register",
  format = function(c)
    return require("manicule.sinks.helpers").format_line(c)
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
