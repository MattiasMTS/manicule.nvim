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
-- On-disk layout
-- --------------
-- Records live in `stdpath("state")/manicule/` (configurable via
-- `config.store.dir`), one file per project root. Path separators in the
-- root are escaped with `[\\/:]+` → `%%` (persistence.nvim convention) so
-- every root flattens to a single filename. If `config.store.branch` is
-- true, the current git branch is appended as `%%<branch>` before the
-- extension — except for `main` and `master`, which collapse to the
-- unsuffixed filename so the common case doesn't fragment.
--
-- The envelope format is `vim.mpack` by default (`config.store.format =
-- "mpack"`); `"json"` is available for users who want a human-readable
-- file. The payload shape is `{ records = { record, ... } }`.
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
--
-- Migration from legacy `.manicule.json`
-- --------------------------------------
-- On first `load(root)` per root, if `<root>/.manicule.json` exists and
-- the new-location file does not, the legacy file is decoded, rewritten
-- in the configured format at the new location, and unlinked. When both
-- exist the new-location file wins and the legacy file is left in place
-- (user may be mid-branch-migration). The `User ManiculeStoreMigrated`
-- autocmd fires once per migration event.

local M = {}

local uv = vim.uv or vim.loop
local config = require("manicule.config")

---@class manicule.StoreEntry
---@field records table[]
---@field dirty boolean

---@type table<string, manicule.StoreEntry>
local cache = {}

---@type table<string, boolean>
local migrated = {}

---Escape a path string so it is usable as a flat filename. Each run of
---path separators (`/`, `\`, `:`) is replaced by the literal two-char
---sequence `%%`. We deviate from persistence.nvim's single-`%` output
---here because manicule doubles up to keep root/branch segment
---boundaries visually distinct (e.g. `%Users%me%repo%%feature%%x.mpack`).
---@param s string
---@return string
local function escape(s)
  -- In gsub's replacement string, `%%` stands for one literal `%`, so
  -- `%%%%` is required to emit two literal `%` characters.
  return (s:gsub("[\\/:]+", "%%%%"))
end

---Return the current git branch for `root`, or nil if none / not a repo.
---@param root string
---@return string|nil
local function git_branch(root)
  if not root or root == "" then
    return nil
  end
  if not uv.fs_stat(root .. "/.git") then
    return nil
  end
  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", root, "branch", "--show-current" })
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  local branch = out and out[1]
  if not branch or branch == "" then
    return nil
  end
  return branch
end

---Absolute path to the store file for the given root, or nil if root is nil.
---@param root string|nil
---@return string|nil
function M.path(root)
  if not root or root == "" then
    return nil
  end
  local cfg = config.current.store
  local name = escape(root)
  if cfg.branch then
    local branch = git_branch(root)
    if branch and branch ~= "main" and branch ~= "master" then
      name = name .. "%%" .. escape(branch)
    end
  end
  return cfg.dir .. name .. "." .. cfg.format
end

---Absolute path to the legacy `<root>/.manicule.json` store for `root`.
---@param root string|nil
---@return string|nil
local function legacy_path(root)
  if not root or root == "" then
    return nil
  end
  return vim.fs.joinpath(root, ".manicule.json")
end

---Resolve the current project root using `store.root_markers`. Falls back
---to `vim.fn.getcwd()` when `persist_unrooted` is enabled so unrooted
---buffers still persist; otherwise returns nil.
---@return string|nil
function M.root()
  local cfg = config.current.store
  local root = vim.fs.root(0, cfg.root_markers)
  if root then
    return root
  end
  if cfg.persist_unrooted then
    return vim.fn.getcwd()
  end
  return nil
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

---Encode records per the configured format.
---@param records table[]
---@return string|nil data, string? err
local function encode(records)
  local cfg = config.current.store
  local payload = { records = records }
  if cfg.format == "json" then
    local ok, encoded = pcall(vim.json.encode, payload)
    if not ok then
      return nil, tostring(encoded)
    end
    return encoded
  end
  -- Default / "mpack".
  local ok, encoded = pcall(vim.mpack.encode, payload)
  if not ok then
    return nil, tostring(encoded)
  end
  return encoded
end

---Decode `data` using the configured format. Returns records table (may
---be empty) and a boolean indicating whether decode succeeded.
---@param data string
---@param path string used purely for diagnostics
---@return table[] records, boolean ok
local function decode(data, path)
  local cfg = config.current.store
  local decoder = cfg.format == "json" and vim.json.decode or vim.mpack.decode
  local ok, decoded = pcall(decoder, data)
  if not ok or type(decoded) ~= "table" then
    vim.notify(("manicule: failed to decode store %s; starting fresh"):format(path), vim.log.levels.WARN)
    return {}, false
  end
  -- Accept both the new envelope `{ records = {...} }` and a bare list of
  -- records for forward-compat with any hand-edited file.
  if decoded.records and type(decoded.records) == "table" then
    return decoded.records, true
  end
  if vim.islist and vim.islist(decoded) then
    return decoded, true
  end
  if #decoded > 0 or next(decoded) == nil then
    return decoded, true
  end
  vim.notify(("manicule: unrecognised store envelope at %s; starting fresh"):format(path), vim.log.levels.WARN)
  return {}, false
end

---Fire `User ManiculeStoreMigrated` once.
---@param root string
---@param legacy string
---@param new string
local function fire_migrated(root, legacy, new)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ManiculeStoreMigrated",
    data = { root = root, legacy = legacy, new = new },
  })
end

---One-shot migration from `<root>/.manicule.json`. Runs at most once per
---root per session (cached in `migrated[root]`).
---@param root string
---@param new_path string
local function maybe_migrate(root, new_path)
  if migrated[root] then
    return
  end
  migrated[root] = true

  local legacy = legacy_path(root)
  if not legacy then
    return
  end
  if not uv.fs_stat(legacy) then
    return
  end

  -- Both exist: prefer the new location, leave the legacy file alone so
  -- the user can decide what to delete (they may be on a branch).
  if uv.fs_stat(new_path) then
    vim.notify(
      ("manicule: legacy store %s found but %s already exists; leaving legacy file in place"):format(legacy, new_path),
      vim.log.levels.INFO
    )
    return
  end

  local data = read_file(legacy)
  if not data or #data == 0 then
    return
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" then
    vim.notify(("manicule: failed to decode legacy store %s; leaving it alone"):format(legacy), vim.log.levels.WARN)
    return
  end

  -- The legacy file held a bare array of records. Wrap it in the new
  -- envelope when writing out.
  local records = decoded
  if decoded.records and type(decoded.records) == "table" then
    records = decoded.records
  end

  local encoded, err = encode(records)
  if not encoded then
    vim.notify(
      ("manicule: failed to encode migrated store for %s: %s"):format(root, tostring(err)),
      vim.log.levels.ERROR
    )
    return
  end

  vim.fn.mkdir(config.current.store.dir, "p")
  local write_ok, write_err = write_atomic(new_path, encoded)
  if not write_ok then
    vim.notify(
      ("manicule: failed to write migrated store %s: %s"):format(new_path, tostring(write_err)),
      vim.log.levels.ERROR
    )
    return
  end

  uv.fs_unlink(legacy)
  fire_migrated(root, legacy, new_path)
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
    -- Ensure the state dir exists before reading/writing. `mkdir -p` is
    -- idempotent and cheap.
    vim.fn.mkdir(config.current.store.dir, "p")

    -- One-shot: migrate `<root>/.manicule.json` into the new location
    -- if it is present and the new file is not yet written.
    maybe_migrate(root, path)

    local data = read_file(path)
    if data and #data > 0 then
      records = decode(data, path)
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
  -- Make sure the dir exists every time — cheap enough and guards against
  -- the user nuking ~/.local/state/nvim/manicule between sessions.
  vim.fn.mkdir(config.current.store.dir, "p")

  local encoded, err = encode(entry.records)
  if not encoded then
    return false, "failed to encode records: " .. tostring(err)
  end
  local write_ok, write_err = write_atomic(path, encoded)
  if not write_ok then
    return false, write_err
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

---Internal: exposed for tests. Resets both caches so a fresh load runs
---migration logic again.
function M._reset()
  cache = {}
  migrated = {}
end

return M
