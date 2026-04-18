-- manicule.nvim: per-project persistence.
--
-- Comment record schema
-- ---------------------
--
--   {
--     id         = "unique",                            -- id.new()
--     path       = "src/foo.lua",                       -- project-relative
--     range      = { start = {row,col}, end_ = {row,col} },
--     body       = "text",
--     author     = "user@example.com",
--     created_at = 1731000000,
--     updated_at = 1731000000,
--     resolved   = false,
--     meta       = {},                                  -- free-form
--   }
--
-- Records live in a JSON file at the project root, resolved via
-- `config.store.path_resolver()` and named `config.store.filename`.
--
-- Atomic write strategy
-- ---------------------
-- `save()` writes to `<path>.tmp` then `vim.uv.fs_rename`s into place.
-- A mid-write crash leaves the prior file intact.
--
-- Caching
-- -------
-- State is kept per-root in a module-local `cache` table. Writes flip a
-- dirty flag; `save()` is a no-op when the flag is clean.

local M = {}

local uv = vim.uv or vim.loop
local config = require("manicule.config")

---@class manicule.StoreEntry
---@field records table[]
---@field dirty boolean

---@type table<string, manicule.StoreEntry>
local cache = {}

---Absolute path to the store file for the given root, or nil if root is nil.
---@param root string|nil
---@return string|nil
function M.path(root)
  if not root then
    return nil
  end
  local filename = config.current.store.filename
  return vim.fs.joinpath(root, filename)
end

---Resolve the current project root using the configured resolver.
---@return string|nil
function M.root()
  local resolver = config.current.store.path_resolver
  if type(resolver) == "function" then
    return resolver()
  end
  return vim.fs.root(0, { ".git", ".hg", "package.json" })
end

---Read a file synchronously via libuv. Returns nil on any error.
---@param path string
---@return string|nil
local function read_file(path)
  local fd = uv.fs_open(path, "r", 438) -- 0o666
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

---Write `data` to `path` atomically (tmp + rename).
---@param path string
---@param data string
---@return boolean ok, string? err
local function write_atomic(path, data)
  local tmp = path .. ".tmp"
  local fd, open_err = uv.fs_open(tmp, "w", 420) -- 0o644
  if not fd then
    return false, open_err
  end
  local _, write_err = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if write_err then
    uv.fs_unlink(tmp)
    return false, write_err
  end
  local ok, rename_err = uv.fs_rename(tmp, path)
  if not ok then
    uv.fs_unlink(tmp)
    return false, rename_err
  end
  return true
end

---Load all records for `root` into the cache. No-op if already loaded.
---@param root string|nil
---@return table[]
function M.load(root)
  if not root then
    return {}
  end
  if cache[root] then
    return cache[root].records
  end
  local path = M.path(root)
  local records = {}
  if path then
    local data = read_file(path)
    if data and #data > 0 then
      local ok, decoded = pcall(vim.json.decode, data)
      if ok and type(decoded) == "table" then
        records = decoded
      else
        vim.notify(("manicule: failed to decode store %s; starting fresh"):format(path), vim.log.levels.WARN)
      end
    end
  end
  cache[root] = { records = records, dirty = false }
  return records
end

---Persist the cache entry for `root` if dirty.
---@param root string|nil
---@return boolean ok, string? err
function M.save(root)
  if not root then
    return true
  end
  local entry = cache[root]
  if not entry or not entry.dirty then
    return true
  end
  local path = M.path(root)
  if not path then
    return false, "no store path for root"
  end
  local ok, encoded = pcall(vim.json.encode, entry.records)
  if not ok then
    return false, "failed to encode records: " .. tostring(encoded)
  end
  local write_ok, err = write_atomic(path, encoded)
  if not write_ok then
    return false, err
  end
  entry.dirty = false
  return true
end

---Return all cached records for `root` (loads on first access).
---@param root string|nil
---@return table[]
function M.all(root)
  if not root then
    return {}
  end
  if not cache[root] then
    M.load(root)
  end
  return cache[root].records
end

---Return the record identified by `id`.
---@param root string|nil
---@param id string
---@return table|nil
function M.get(root, id)
  for _, r in ipairs(M.all(root)) do
    if r.id == id then
      return r
    end
  end
  return nil
end

---Insert or update a record (matched by id).
---@param root string|nil
---@param record table
function M.put(root, record)
  if not root then
    return
  end
  local records = M.all(root)
  for i, r in ipairs(records) do
    if r.id == record.id then
      records[i] = record
      cache[root].dirty = true
      return
    end
  end
  table.insert(records, record)
  cache[root].dirty = true
end

---Remove a record by id. Returns the removed record (or nil).
---@param root string|nil
---@param id string
---@return table|nil
function M.remove(root, id)
  if not root then
    return nil
  end
  local records = M.all(root)
  for i, r in ipairs(records) do
    if r.id == id then
      table.remove(records, i)
      cache[root].dirty = true
      return r
    end
  end
  return nil
end

---Return records whose `path` matches `relpath`.
---@param root string|nil
---@param relpath string
---@return table[]
function M.for_path(root, relpath)
  local out = {}
  for _, r in ipairs(M.all(root)) do
    if r.path == relpath then
      table.insert(out, r)
    end
  end
  return out
end

---Flush every dirty root in the cache. Used on VimLeavePre as a safety net.
function M.flush_all()
  for root, entry in pairs(cache) do
    if entry.dirty then
      M.save(root)
    end
  end
end

---Internal: exposed for tests.
---@return table<string, manicule.StoreEntry>
function M._cache()
  return cache
end

return M
