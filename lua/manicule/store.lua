-- manicule.nvim: persistence (project + session scopes).
--
-- Records live in `stdpath("state")/manicule/` (configurable via
-- `config.store.dir`). Two scopes share the on-disk layout:
--
--   * Project scope: one file per project root. Path separators in the
--     root are escaped with `[\\/:]+` → `%%` (persistence.nvim
--     convention) so every root flattens to a single filename. If
--     `config.store.branch` is true, the current git branch is appended
--     as `%%<branch>` before the extension — except for `main` and
--     `master`, which collapse to the unsuffixed filename. The file is
--     named `<escaped-root>[%%<branch>].<format>`.
--
--   * Session scope: one file, `session.<format>`, shared across every
--     unrooted / special-buftype buffer (terminal, help, scratch, etc).
--     Records in this store key purely off `uri`; they carry
--     `project_root = nil`.
--
-- The on-disk payload is a versioned envelope:
--
--   { version = 1, records = { ... } }
--
-- encoded with `vim.mpack.encode` (or `vim.json.encode` when
-- `config.store.format == "json"`). Legacy bare arrays are still
-- accepted and rewritten as the current envelope on the next save.
-- `save()` writes to `<path>.tmp` then renames so a mid-write crash
-- never truncates the prior file. State is kept per-root in a
-- module-local `cache` (plus a single-slot session cache); writes flip
-- a dirty flag and `save()` is a no-op when the flag is clean.

local M = {}

local uv = vim.uv or vim.loop
local config = require("manicule.config")

local STORE_VERSION = 1

---@class manicule.StoreEntry
---@field records table[]
---@field dirty boolean

---@type table<string, manicule.StoreEntry>
local cache = {}

---Single-slot session cache. Populated on first `session_load()`;
---`session_save()` is a no-op when `dirty` is false.
---@type { records: table[], dirty: boolean, loaded: boolean }
local session_cache = { records = {}, dirty = false, loaded = false }

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

---Resolve the current project root using `store.root_markers`. Returns
---nil when no marker is found — unrooted buffers land in the session
---store (see `session_put` / `all_for_uri`) rather than keying off
---`getcwd`, so multiple unrelated unrooted files share a single
---session file instead of fragmenting per-directory.
---@return string|nil
function M.root()
  local cfg = config.current.store
  return vim.fs.root(0, cfg.root_markers)
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

---Return the current on-disk store schema version.
---@return integer
function M.schema_version()
  return STORE_VERSION
end

---@param value any
---@return boolean
local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  if vim.islist then
    return vim.islist(value)
  end
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  return count == #value
end

---Encode records per the configured format as a versioned envelope.
---@param records table[]
---@return string|nil data, string? err
local function encode(records)
  local cfg = config.current.store
  local payload = {
    version = STORE_VERSION,
    records = records,
  }
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

---Decode `data` using the configured format. Expects a bare array of
---records (legacy) or the current versioned envelope. Anything else is
---treated as corrupt and produces an empty list plus a WARN notify.
---@param data string
---@param path string used purely for diagnostics
---@return table[] records
local function decode(data, path)
  local cfg = config.current.store
  local decoder = cfg.format == "json" and vim.json.decode or vim.mpack.decode
  local ok, decoded = pcall(decoder, data)
  if not ok or type(decoded) ~= "table" then
    vim.notify(("manicule: failed to decode store %s; starting fresh"):format(path), vim.log.levels.WARN)
    return {}
  end

  if is_list(decoded) then
    return decoded
  end

  local version = decoded.version
  if type(version) ~= "number" then
    vim.notify(("manicule: unrecognised store shape at %s; starting fresh"):format(path), vim.log.levels.WARN)
    return {}
  end
  if version > STORE_VERSION then
    vim.notify(("manicule: store %s uses newer schema v%d; starting fresh"):format(path, version), vim.log.levels.WARN)
    return {}
  end
  if version ~= STORE_VERSION then
    vim.notify(
      ("manicule: unsupported store schema v%d at %s; starting fresh"):format(version, path),
      vim.log.levels.WARN
    )
    return {}
  end

  local records = decoded.records
  if not is_list(records) then
    vim.notify(("manicule: unrecognised records shape at %s; starting fresh"):format(path), vim.log.levels.WARN)
    return {}
  end
  return records
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
    -- idempotent and cheap. (setup() also mkdirs once, but this guards
    -- against `setup()` never being called.)
    vim.fn.mkdir(config.current.store.dir, "p")

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

---Insert or update a record (matched by id). Flags the root dirty.
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

---Flag the cache entry for `root` as dirty so the next `save()` flushes
---it. Use after an in-place record mutation where the caller already
---holds the record table (e.g. URI rewrite on BufFilePost) and doesn't
---need the put/table-walk roundtrip.
---@param root string|nil
function M.mark_dirty(root)
  if not root then
    return
  end
  if cache[root] then
    cache[root].dirty = true
  end
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

---Return records whose `uri` matches `uri`.
---@param root string|nil
---@param uri string
---@return table[]
function M.for_uri(root, uri)
  local out = {}
  if not uri or uri == "" then
    return out
  end
  for _, r in ipairs(M.all(root)) do
    if r.uri == uri then
      table.insert(out, r)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Session-scope store
-- ---------------------------------------------------------------------------

---Absolute path to the single session-scope file.
---@return string
function M.session_path()
  local cfg = config.current.store
  return cfg.dir .. "session." .. cfg.format
end

---@param record table
---@return boolean
local function is_ephemeral_record(record)
  return type(record) == "table" and type(record.meta) == "table" and record.meta.ephemeral == true
end

---Load the session records into `session_cache`. No-op after the first
---call; use `_reset()` to invalidate from tests.
---@return table[]
function M.session_load()
  if session_cache.loaded then
    return session_cache.records
  end
  vim.fn.mkdir(config.current.store.dir, "p")
  local path = M.session_path()
  local records = {}
  local data = read_file(path)
  if data and #data > 0 then
    records = decode(data, path)
  end
  session_cache.records = records
  session_cache.dirty = false
  session_cache.loaded = true
  return records
end

---Flush the session cache if dirty.
---@return boolean ok, string? err
function M.session_save()
  if not session_cache.dirty then
    return true
  end
  vim.fn.mkdir(config.current.store.dir, "p")
  local persisted = {}
  for _, record in ipairs(session_cache.records) do
    if not is_ephemeral_record(record) then
      table.insert(persisted, record)
    end
  end
  local encoded, err = encode(persisted)
  if not encoded then
    return false, "failed to encode session records: " .. tostring(err)
  end
  local write_ok, write_err = write_atomic(M.session_path(), encoded)
  if not write_ok then
    return false, write_err
  end
  session_cache.dirty = false
  return true
end

---Return all session-scope records (loads on first access).
---@return table[]
function M.session_all()
  if not session_cache.loaded then
    M.session_load()
  end
  return session_cache.records
end

---Return session records whose `uri` matches.
---@param uri string
---@return table[]
function M.session_for_uri(uri)
  local out = {}
  if not uri or uri == "" then
    return out
  end
  for _, r in ipairs(M.session_all()) do
    if r.uri == uri then
      table.insert(out, r)
    end
  end
  return out
end

---Insert or update a session record.
---@param record table
function M.session_put(record)
  local records = M.session_all()
  for i, r in ipairs(records) do
    if r.id == record.id then
      records[i] = record
      session_cache.dirty = true
      return
    end
  end
  table.insert(records, record)
  session_cache.dirty = true
end

---Remove a session record by id. Returns the removed record or nil.
---@param id string
---@return table|nil
function M.session_remove(id)
  local records = M.session_all()
  for i, r in ipairs(records) do
    if r.id == id then
      table.remove(records, i)
      session_cache.dirty = true
      return r
    end
  end
  return nil
end

---Flag the session cache as dirty so the next save flushes it.
function M.session_mark_dirty()
  if session_cache.loaded then
    session_cache.dirty = true
  end
end

-- ---------------------------------------------------------------------------
-- Polymorphic dispatcher
-- ---------------------------------------------------------------------------

---Return all records that match `uri` across both stores. Project
---records are only included if the record's `project_root` matches the
---given project root. When no project root argument is passed, the
---current buffer's root is used for backwards compatibility with older
---callers. Passing nil explicitly means "session records only".
---@param uri string
---@param project_root? string|nil Optional explicit root for project records.
---@return table[]
function M.all_for_uri(uri, ...)
  local out = {}
  if not uri or uri == "" then
    return out
  end
  local current_root
  if select("#", ...) > 0 then
    current_root = select(1, ...)
  else
    current_root = M.root()
  end
  if current_root then
    for _, r in ipairs(M.for_uri(current_root, uri)) do
      table.insert(out, r)
    end
  end
  for _, r in ipairs(M.session_for_uri(uri)) do
    table.insert(out, r)
  end
  return out
end

---Dispatch a `put` by `record.scope`. Project records need a
---`project_root`; session records don't.
---@param record table
function M.put_record(record)
  if record.scope == "session" then
    M.session_put(record)
    return
  end
  -- Default / project: require an explicit root on the record.
  M.put(record.project_root, record)
end

---Dispatch a `remove` by scope. For project-scope, `scope_or_root` may
---be the root path directly (matching the existing API) or the literal
---string "project" — in which case the record's `project_root` is
---looked up via `get` across known caches.
---@param scope_or_root "project"|"session"|string
---@param id string
---@param project_root string? required when scope=="project"
---@return table|nil
function M.remove_record(scope_or_root, id, project_root)
  if scope_or_root == "session" then
    return M.session_remove(id)
  end
  if scope_or_root == "project" then
    return M.remove(project_root, id)
  end
  -- Treat it as a raw root path (pre-dispatcher API).
  return M.remove(scope_or_root, id)
end

---Return every record across every known store — project caches AND
---session. Used by `list` when scope-agnostic enumeration is needed.
---@return table[]
function M.all_records()
  local out = {}
  for _, entry in pairs(cache) do
    for _, r in ipairs(entry.records) do
      table.insert(out, r)
    end
  end
  if session_cache.loaded then
    for _, r in ipairs(session_cache.records) do
      table.insert(out, r)
    end
  end
  return out
end

---Flush every dirty root in the cache AND the session cache. Used on
---VimLeavePre as a safety net.
function M.flush_all()
  for root, entry in pairs(cache) do
    if entry.dirty then
      M.save(root)
    end
  end
  if session_cache.dirty then
    M.session_save()
  end
end

---Internal: exposed for tests.
---@return table<string, manicule.StoreEntry>
function M._cache()
  return cache
end

---Internal: exposed for tests. Resets the cache so a fresh load runs.
function M._reset()
  cache = {}
  session_cache = { records = {}, dirty = false, loaded = false }
end

return M
