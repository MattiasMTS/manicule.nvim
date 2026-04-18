-- manicule.nvim: sink registry.
--
-- A sink is anything that accepts a list of comment records and does
-- something useful with them — copy to clipboard, open a draft PR,
-- post to a chat webhook, pipe into another tool, etc. Adapters are
-- registered via `M.register` and dispatched via `M.dispatch`.

local M = {}
local sinks = {}

---Register a sink adapter.
---@param spec {name: string, send: fun(comments, ctx, cb), format?: fun(c): string, validate?: fun(ctx): boolean, string?}
function M.register(spec)
  vim.validate({
    name = { spec.name, "string" },
    send = { spec.send, "function" },
    format = { spec.format, "function", true },
    validate = { spec.validate, "function", true },
  })
  sinks[spec.name] = spec
end

---Look up a registered sink by name.
---@param name string
---@return table|nil
function M.get(name)
  return sinks[name]
end

---List all registered sink names.
---@return string[]
function M.list()
  return vim.tbl_keys(sinks)
end

---Dispatch a comment list to a named sink.
---@param name string
---@param comments table
---@param ctx table|nil
---@param cb fun(ok: boolean, err: string?)|nil
function M.dispatch(name, comments, ctx, cb)
  local sink = sinks[name]
  if not sink then
    local err = "manicule: unknown sink: " .. tostring(name)
    if cb then
      cb(false, err)
    else
      error(err)
    end
    return
  end
  if sink.validate then
    local ok, err = sink.validate(ctx or {})
    if not ok then
      if cb then
        cb(false, err)
      else
        error(err)
      end
      return
    end
  end
  sink.send(comments, ctx or {}, cb or function() end)
end

return M
