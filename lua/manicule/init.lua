-- manicule.nvim
-- Public API surface. Most functions are stubs awaiting implementation;
-- sink registration routes through `manicule.sinks` which is live.

local M = {}

---@class manicule.Config
---@field store? table
---@field handlers? table
---@field sinks? table

local function unimplemented(name)
  vim.notify(("TODO(manicule): implement %s"):format(name), vim.log.levels.WARN)
end

---Initialize manicule with user options.
---@param opts manicule.Config|nil
function M.setup(opts)
  -- TODO(manicule): merge opts into config, load store, install autocmds,
  -- and register built-in sinks (clipboard at minimum).
  local _ = opts
  unimplemented("setup")
end

---Add a new comment, optionally tied to a range in the current buffer.
---@param opts {range?: table, body?: string, meta?: table}|nil
function M.add(opts)
  local _ = opts
  unimplemented("add")
end

---Edit an existing comment by id.
---@param id string
function M.edit(id)
  local _ = id
  unimplemented("edit")
end

---Delete a comment by id.
---@param id string
function M.delete(id)
  local _ = id
  unimplemented("delete")
end

---Mark a comment as resolved.
---@param id string
function M.resolve(id)
  local _ = id
  unimplemented("resolve")
end

---List comments, optionally filtered.
---@param filter {path?: string, unresolved?: boolean, orphaned?: boolean, author?: string}|nil
function M.list(filter)
  local _ = filter
  unimplemented("list")
end

---Dispatch filtered comments to a named sink.
---@param sink_name string
---@param filter table|nil
---@param ctx table|nil
function M.send(sink_name, filter, ctx)
  -- TODO(manicule): resolve `filter` into a concrete record list via store,
  -- then delegate to the sinks registry.
  local _, _, _ = sink_name, filter, ctx
  unimplemented("send")
end

---Register a sink adapter. Delegates to the sinks registry.
---@param spec {name: string, send: fun(comments: table, ctx: table, cb: fun(ok, err)), format?: fun(c): string, validate?: fun(ctx): boolean, string?}
function M.register_sink(spec)
  return require("manicule.sinks").register(spec)
end

---Subscribe to manicule lifecycle events.
---@param event "added"|"edited"|"deleted"|"resolved"|"sent"
---@param fn fun(data: table)
function M.on(event, fn)
  local _, _ = event, fn
  unimplemented("on")
end

return M
