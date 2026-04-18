-- manicule.nvim: picker-agnostic UI glue.
--
-- `M.prompt` now delegates to the floating editor at
-- `lua/manicule/ui/editor.lua` (ported from codediff.nvim). That gives
-- multi-line markdown-flavoured editing with user-configurable submit /
-- cancel keys instead of the single-line `vim.ui.input` we used in v0.
--
-- `M.select_sink` still uses `vim.ui.select` so dressing.nvim /
-- snacks.nvim / fzf-lua / telescope-ui-select continue to work out of
-- the box for sink selection.

local M = {}

---Open the floating comment editor and invoke `cb` with the body
---(or `nil` on cancel).
---@param opts { prompt?: string, default?: string, anchor_pos?: integer[], anchor_winid?: integer }|nil
---@param cb fun(body: string|nil)
function M.prompt(opts, cb)
  opts = opts or {}
  local cfg = require("manicule.config").get().ui
  require("manicule.ui.editor").open({
    title = opts.prompt or "Comment",
    default = opts.default or "",
    anchor_winid = opts.anchor_winid,
    anchor_pos = opts.anchor_pos,
    cfg = cfg,
  }, cb)
end

---Prompt for a registered sink name.
---@param cb fun(name: string|nil)
function M.select_sink(cb)
  local sinks = require("manicule.sinks").list()
  vim.ui.select(sinks, { prompt = "Sink:" }, cb)
end

local cached_email

---Best-effort author identity. Falls back to $USER or "?".
---@return string
function M.git_email()
  if cached_email then
    return cached_email
  end
  local ok, result = pcall(function()
    return vim.system({ "git", "config", "user.email" }, { text = true }):wait()
  end)
  if ok and result and result.code == 0 and result.stdout then
    local trimmed = (result.stdout:gsub("%s+$", ""))
    if trimmed ~= "" then
      cached_email = trimmed
      return cached_email
    end
  end
  cached_email = vim.env.USER or "?"
  return cached_email
end

---Internal: exposed so tests can reset between cases.
function M._reset_email_cache()
  cached_email = nil
end

return M
