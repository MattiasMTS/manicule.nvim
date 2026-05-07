local M = {}

local uv = vim.uv or vim.loop

local function path_join(...)
  return table.concat({ ... }, "/"):gsub("/+", "/")
end

local function can_write_dir(dir)
  if type(dir) ~= "string" or dir == "" then
    return false, "empty directory"
  end
  local stat = uv.fs_stat(dir)
  if not stat then
    return false, "directory does not exist"
  end
  if stat.type ~= "directory" then
    return false, "path is not a directory"
  end

  local probe = path_join(dir:gsub("/$", ""), ".manicule-health-" .. tostring(vim.fn.getpid()))
  local fd, open_err = uv.fs_open(probe, "w", 384) -- 0o600
  if not fd then
    return false, open_err or "open failed"
  end
  local _, write_err = uv.fs_write(fd, "ok", 0)
  uv.fs_close(fd)
  pcall(uv.fs_unlink, probe)
  if write_err then
    return false, write_err
  end
  return true, nil
end

local function glob_count(pattern)
  local ok, files = pcall(vim.fn.glob, pattern, false, true)
  if not ok or type(files) ~= "table" then
    return 0
  end
  return #files
end

---@return table
function M._collect()
  local config = require("manicule.config").get()
  local store = require("manicule.store")
  local sinks = require("manicule.sinks")
  local cmux = require("manicule.sinks.cmux")

  local store_cfg = config.store or {}
  local store_dir = store_cfg.dir or ""
  local store_stat = store_dir ~= "" and uv.fs_stat(store_dir) or nil
  local store_writable, store_write_err = can_write_dir(store_dir)
  local store_files = store_dir ~= "" and glob_count(store_dir:gsub("/$", "") .. "/*." .. tostring(store_cfg.format))
    or 0

  local sink_names = sinks.list()
  local sink_health = {}
  for name, spec in pairs(sinks.all()) do
    if type(spec.health) == "function" then
      local ok, result = pcall(spec.health)
      sink_health[name] = ok and result or { err = result }
    end
  end

  local cmux_cfg = (config.sinks or {}).cmux
  local cmux_opts = type(cmux_cfg) == "table" and cmux_cfg or {}

  return {
    nvim = {
      version = vim.version(),
      has_required = vim.fn.has("nvim-0.10") == 1,
      has_vim_system = type(vim.system) == "function",
      has_vim_fs_root = type(vim.fs) == "table" and type(vim.fs.root) == "function",
      has_mpack = type(vim.mpack) == "table" and type(vim.mpack.encode) == "function",
    },
    store = {
      dir = store_dir,
      exists = store_stat ~= nil and store_stat.type == "directory",
      writable = store_writable,
      write_error = store_write_err,
      format = store_cfg.format,
      schema_version = store.schema_version(),
      root_markers = store_cfg.root_markers or {},
      current_root = store.root(),
      file_count = store_files,
    },
    sinks = {
      names = sink_names,
      health = sink_health,
      clipboard_registered = sinks.get("clipboard") ~= nil,
      clipboard_available = vim.fn.has("clipboard") == 1,
      cmux_registered = sinks.get("cmux") ~= nil,
      cmux_available = cmux.is_available(cmux_opts),
    },
  }
end

local function list_join(values)
  if not values or #values == 0 then
    return "(none)"
  end
  return table.concat(values, ", ")
end

function M.check()
  local health = vim.health
  local snapshot = M._collect()

  health.start("manicule.nvim")
  if snapshot.nvim.has_required then
    local version = snapshot.nvim.version
    health.ok(("Neovim version: %d.%d.%d"):format(version.major, version.minor, version.patch))
  else
    health.error("Neovim >= 0.10 is required")
  end
  if snapshot.nvim.has_vim_system then
    health.ok("vim.system is available")
  else
    health.error("vim.system is unavailable; update Neovim")
  end
  if snapshot.nvim.has_vim_fs_root then
    health.ok("vim.fs.root is available")
  else
    health.error("vim.fs.root is unavailable; update Neovim")
  end
  if snapshot.nvim.has_mpack then
    health.ok("vim.mpack is available")
  else
    health.error("vim.mpack is unavailable; mpack stores cannot be written")
  end

  health.start("manicule store")
  health.info("store.dir: " .. tostring(snapshot.store.dir))
  health.info("store.format: " .. tostring(snapshot.store.format))
  health.info("store.schema_version: " .. tostring(snapshot.store.schema_version))
  if snapshot.store.exists then
    health.ok("store directory exists")
  else
    health.warn("store directory does not exist; call require('manicule').setup() before using the plugin")
  end
  if not snapshot.store.exists then
    health.warn("store writability skipped because the directory is missing")
  elseif snapshot.store.writable then
    health.ok("store directory is writable")
  else
    health.error("store directory is not writable: " .. tostring(snapshot.store.write_error))
  end
  if type(snapshot.store.root_markers) == "table" and #snapshot.store.root_markers > 0 then
    health.ok("root markers: " .. table.concat(snapshot.store.root_markers, ", "))
  else
    health.warn("store.root_markers is empty; project-scope records will not resolve")
  end
  if snapshot.store.current_root then
    health.info("current project root: " .. snapshot.store.current_root)
  else
    health.info("current buffer has no project root")
  end
  health.info("store files for current format: " .. tostring(snapshot.store.file_count))

  health.start("manicule sinks")
  health.info("registered sinks: " .. list_join(snapshot.sinks.names))
  if #snapshot.sinks.names == 0 then
    health.warn("no sinks registered; call require('manicule').setup()")
  end
  if snapshot.sinks.clipboard_registered then
    if snapshot.sinks.clipboard_available then
      health.ok("clipboard sink registered and + clipboard is available")
    else
      health.warn("clipboard sink registered but Neovim has no + clipboard provider")
    end
  else
    health.info("clipboard sink is not registered")
  end
  if snapshot.sinks.cmux_registered then
    local cmux_health = snapshot.sinks.health.cmux or {}
    if cmux_health.available then
      health.ok("cmux integration registered and available: " .. tostring(cmux_health.command))
    else
      health.warn("cmux integration registered but unavailable: " .. tostring(cmux_health.command or "cmux"))
    end
    if cmux_health.workspace_id then
      health.info("cmux workspace: " .. tostring(cmux_health.workspace_id))
    end
  elseif snapshot.sinks.cmux_available then
    health.info("cmux is available but the integration is not registered")
  else
    health.info("cmux integration is not registered")
  end
end

return M
