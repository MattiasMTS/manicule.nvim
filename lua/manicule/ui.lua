-- manicule.nvim: thin wrappers over `vim.ui.input` / `vim.ui.select`
-- so the rest of the plugin stays picker-agnostic. Any UI that
-- implements the vim.ui contract (dressing.nvim, snacks.nvim, fzf-lua,
-- telescope-ui-select, …) works transparently.

local M = {}

---Prompt for a single-line comment body.
---@param opts {prompt?: string, default?: string}|nil
---@param cb fun(body: string|nil)
function M.prompt(opts, cb)
  opts = opts or {}
  vim.ui.input({
    prompt = opts.prompt or "Comment: ",
    default = opts.default or "",
  }, cb)
end

-- TODO(manicule): v2 — multi-line prompt via scratch buffer. v1 keeps
-- things single-line because `vim.ui.input` is the lowest-common-denom.

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
