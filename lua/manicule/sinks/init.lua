-- manicule.nvim: sink registry.
--
-- A sink is anything that accepts a list of comment records and does
-- something useful with them — copy to clipboard, open a draft PR,
-- post to a chat webhook, pipe into another tool, etc. Adapters are
-- registered via `M.register` and dispatched via `M.dispatch`.

local M = {}
local sinks = {}

local builtin_integrations = {
  clipboard = "manicule.sinks.clipboard",
  cmux = "manicule.sinks.cmux",
}

local builtin_defaults = {
  clipboard = true,
  cmux = "auto",
}

local function normalize_enabled(value, default)
  if value == nil then
    return default
  end
  if type(value) == "table" and value.enabled ~= nil then
    return value.enabled
  end
  return value
end

local function integration_opts(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

local function load_spec(module_name, opts)
  local mod = require(module_name)
  if type(mod.setup) == "function" then
    return mod.setup(opts)
  end
  if type(mod.spec) == "function" then
    return mod.spec(opts)
  end
  return mod.spec
end

---Register a sink adapter.
---@param spec {name: string, send: fun(comments, ctx, cb), type?: string, label?: string, description?: string, format?: fun(c): string, validate?: fun(ctx): boolean, string?, health?: fun(): table?, clear_on_success?: boolean}
---
---Spec fields:
---  name              string     unique sink identifier
---  type              string?    "sink" (default) or "integration"
---  label             string?    display name for pickers / health
---  description       string?    picker hint / documentation
---  send              function   function(comments, ctx, cb) — cb(ok: boolean, err: string?)
---  format            function?  per-record formatter
---  validate          function?  gate the dispatch; return false, err to reject
---  health            function?  returns optional diagnostic info for checkhealth
---  clear_on_success  boolean?   if true, core deletes every record in the batch
---                               after the sink's send callback reports ok=true.
---                               default: false (records persist).
function M.register(spec)
  vim.validate({
    name = { spec.name, "string" },
    send = { spec.send, "function" },
    type = { spec.type, "string", true },
    label = { spec.label, "string", true },
    description = { spec.description, "string", true },
    format = { spec.format, "function", true },
    validate = { spec.validate, "function", true },
    health = { spec.health, "function", true },
    clear_on_success = { spec.clear_on_success, "boolean", true },
  })
  spec.type = spec.type or "sink"
  sinks[spec.name] = spec
end

---Register all bundled sinks/integrations according to config.
---
---`sinks.clipboard` defaults to true.
---`sinks.cmux` defaults to "auto": register only inside a cmux workspace
---with a usable cmux executable. Set `sinks.cmux = true` or
---`sinks.cmux = { enabled = true }` to force it into the picker.
---@param cfg table|nil
function M.setup(cfg)
  cfg = cfg or {}
  for name in pairs(builtin_integrations) do
    sinks[name] = nil
  end
  for name, module_name in pairs(builtin_integrations) do
    local enabled = normalize_enabled(cfg[name], builtin_defaults[name])
    local opts = integration_opts(cfg[name])
    if enabled == "auto" then
      local mod = require(module_name)
      enabled = type(mod.is_available) == "function" and mod.is_available(opts) or false
    end
    if enabled then
      M.register(load_spec(module_name, opts))
    end
  end
end

---Look up a registered sink by name.
---@param name string
---@return table|nil
function M.get(name)
  return sinks[name]
end

---Return all registered sink specs keyed by name.
---@return table<string, table>
function M.all()
  return vim.deepcopy(sinks)
end

---Return bundled integration names.
---@return string[]
function M.integrations()
  local names = vim.tbl_keys(builtin_integrations)
  table.sort(names)
  return names
end

---List all registered sink names.
---@return string[]
function M.list()
  local names = vim.tbl_keys(sinks)
  table.sort(names)
  return names
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
  ctx = ctx or {}
  local function fail(err)
    if cb then
      cb(false, err)
    else
      error(err)
    end
  end
  if sink.validate then
    local ok, valid, err = pcall(sink.validate, ctx)
    if not ok then
      fail("manicule: sink " .. tostring(name) .. " validate failed: " .. tostring(valid))
      return
    end
    if not valid then
      fail(err)
      return
    end
  end
  local done = false
  local function finish(ok, err)
    if done then
      return
    end
    done = true
    if cb then
      cb(ok, err)
    elseif not ok then
      error(err)
    end
  end
  local ok, err = pcall(sink.send, comments, ctx, cb and finish or function() end)
  if not ok then
    finish(false, "manicule: sink " .. tostring(name) .. " send failed: " .. tostring(err))
  end
end

---Internal: exposed for tests.
function M._reset()
  sinks = {}
end

return M
