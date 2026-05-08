-- manicule.nvim: persistence (project + session scopes).
--
-- Records live in `stdpath("state")/manicule/` (configurable via
-- `config.store.dir`). Two scopes share the local persistence layer:
--
--   * Project scope: by default, one SQLite database per project root.
--     The database uses WAL mode and stores both the current projection
--     and an append-only event log, so multiple Neovim sessions can
--     merge field-level updates without rewriting a whole store file.
--
--   * Session scope: one file, `session.<format>`, shared across every
--     unrooted / special-buftype buffer (terminal, help, scratch, etc).
--     Records in this store key purely off `uri`; they carry
--     `project_root = nil`.
--
-- Session stores use a versioned envelope:
--
--   { version = 1, records = { ... } }
--
-- encoded with `vim.mpack.encode` (or `vim.json.encode` when
-- `config.store.format == "json"`). Session saves write to
-- `<path>.tmp` then rename so a mid-write crash never truncates the
-- prior file. Project saves use SQLite `BEGIN IMMEDIATE` transactions.
-- State is kept per-root in a module-local `cache` (plus a single-slot
-- session cache); writes flip a dirty flag and `save()` is a no-op
-- when the flag is clean.

local M = {}

local uv = vim.uv or vim.loop
local config = require("manicule.config")

local STORE_VERSION = 1

---@class manicule.StoreEntry
---@field records table[]
---@field dirty boolean
---@field base_by_id? table<string, table>
---@field removed? table<string, table>
---@field last_seen_event_id? integer

---@type table<string, manicule.StoreEntry>
local cache = {}

---@type table<string, table>
local sqlite_dbs = {}

local client_id = ("%s-%d-%d"):format(tostring(vim.fn.hostname()), vim.fn.getpid(), math.random(0, 0xfffffff))

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

---@param root string
---@return string
local function store_name(root)
  local cfg = config.current.store
  local name = escape(root)
  if cfg.branch then
    local branch = git_branch(root)
    if branch and branch ~= "main" and branch ~= "master" then
      name = name .. "%%" .. escape(branch)
    end
  end
  return name
end

---@param root string|nil
---@return string|nil
local function sqlite_path(root)
  if not root or root == "" then
    return nil
  end
  local cfg = config.current.store
  return cfg.dir .. store_name(root) .. ".sqlite3"
end

---Absolute path to the project store for the given root, or nil if root is nil.
---@param root string|nil
---@return string|nil
function M.path(root)
  return sqlite_path(root)
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

---Decode `data` using the configured format. Expects the current
---versioned envelope. Anything else is treated as corrupt and produces
---an empty list plus a WARN notify.
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

---@param records table[]
---@return table<string, table>
local function by_id(records)
  local out = {}
  for _, record in ipairs(records or {}) do
    if type(record) == "table" and record.id ~= nil then
      out[tostring(record.id)] = vim.deepcopy(record)
    end
  end
  return out
end

---@param value any
---@return string|nil data, string? err
local function encode_json(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return nil, tostring(encoded)
  end
  return encoded
end

---@param data string
---@return table|nil value
local function decode_json(data)
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function sqlite_available()
  return require("manicule.sqlite").available()
end

local function sqlite_exec(db, sql)
  local ok, err = db:exec(sql)
  if not ok then
    return false, err
  end
  return true
end

---@param db table
---@return boolean ok, string? err
local function ensure_sqlite_schema(db)
  local statements = {
    "PRAGMA journal_mode=WAL",
    "PRAGMA synchronous=NORMAL",
    "PRAGMA busy_timeout=1000",
    [[CREATE TABLE IF NOT EXISTS records (
      root TEXT NOT NULL,
      id TEXT NOT NULL,
      data TEXT NOT NULL,
      deleted_at INTEGER,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (root, id)
    )]],
    [[CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      root TEXT NOT NULL,
      record_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      payload TEXT NOT NULL,
      client_id TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )]],
    "CREATE INDEX IF NOT EXISTS idx_manicule_events_root_id ON events(root, id)",
    "CREATE INDEX IF NOT EXISTS idx_manicule_records_root_deleted ON records(root, deleted_at)",
  }
  for _, sql in ipairs(statements) do
    local ok, err = sqlite_exec(db, sql)
    if not ok then
      return false, err
    end
  end
  return true
end

---@param root string
---@return table? db, string? err
local function sqlite_db(root)
  local path = sqlite_path(root)
  if not path then
    return nil, "no sqlite path for root"
  end
  local existing = sqlite_dbs[path]
  if existing then
    return existing
  end
  vim.fn.mkdir(config.current.store.dir, "p")
  local db, err = require("manicule.sqlite").open(path)
  if not db then
    return nil, err
  end
  local ok, schema_err = ensure_sqlite_schema(db)
  if not ok then
    db:close()
    return nil, schema_err
  end
  sqlite_dbs[path] = db
  return db
end

---@param db table
---@param root string
---@return integer
local function sqlite_last_event_id(db, root)
  local row = db:row("SELECT COALESCE(MAX(id), 0) AS id FROM events WHERE root = ?", { root })
  return row and tonumber(row.id) or 0
end

---@param db table
---@param root string
---@param id string
---@param include_deleted boolean?
---@return table? record, integer? deleted_at
local function sqlite_get_record(db, root, id, include_deleted)
  local sql = include_deleted and "SELECT data, deleted_at FROM records WHERE root = ? AND id = ?"
    or "SELECT data, deleted_at FROM records WHERE root = ? AND id = ? AND deleted_at IS NULL"
  local row, err = db:row(sql, { root, id })
  if err or not row or not row.data then
    return nil, row and row.deleted_at or nil
  end
  return decode_json(row.data), row.deleted_at
end

---@param db table
---@param root string
---@return table[] records, string? err
local function sqlite_read_records(db, root)
  local rows, err =
    db:rows("SELECT data FROM records WHERE root = ? AND deleted_at IS NULL ORDER BY updated_at, id", { root })
  if not rows then
    return {}, err
  end
  local records = {}
  for _, row in ipairs(rows) do
    local record = row.data and decode_json(row.data)
    if type(record) == "table" then
      table.insert(records, record)
    end
  end
  return records
end

---@param db table
---@param root string
---@param record table
---@param deleted_at integer?
---@return boolean ok, string? err
local function sqlite_upsert_record(db, root, record, deleted_at)
  local data, encode_err = encode_json(record)
  if not data then
    return false, encode_err
  end
  local updated_at = tonumber(record.updated_at) or os.time()
  if deleted_at == nil then
    return db:execute(
      [[INSERT INTO records(root, id, data, deleted_at, updated_at)
        VALUES (?, ?, ?, NULL, ?)
        ON CONFLICT(root, id) DO UPDATE SET
          data = excluded.data,
          deleted_at = excluded.deleted_at,
          updated_at = excluded.updated_at]],
      { root, tostring(record.id), data, updated_at }
    )
  end
  return db:execute(
    [[INSERT INTO records(root, id, data, deleted_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(root, id) DO UPDATE SET
        data = excluded.data,
        deleted_at = excluded.deleted_at,
        updated_at = excluded.updated_at]],
    { root, tostring(record.id), data, deleted_at, updated_at }
  )
end

---@param db table
---@param root string
---@param record_id string
---@param kind string
---@param payload table
---@param created_at integer
---@return boolean ok, string? err
local function sqlite_insert_event(db, root, record_id, kind, payload, created_at)
  local data, encode_err = encode_json(payload)
  if not data then
    return false, encode_err
  end
  return db:execute(
    "INSERT INTO events(root, record_id, kind, payload, client_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    { root, tostring(record_id), kind, data, client_id, created_at }
  )
end

---@param record table
---@return boolean
local function is_ephemeral_record(record)
  return type(record) == "table" and type(record.meta) == "table" and record.meta.ephemeral == true
end

local RECORD_FIELDS = { "body", "range", "resolved", "uri", "meta", "author" }

---@param base table
---@param current table
---@return table<string, boolean>
local function changed_fields(base, current)
  local fields = {}
  for _, field in ipairs(RECORD_FIELDS) do
    if not vim.deep_equal(base and base[field], current and current[field]) then
      fields[field] = true
    end
  end
  return fields
end

local function has_changes(fields)
  return next(fields) ~= nil
end

local function event_kind_for_field(field, value)
  if field == "body" then
    return "comment_body_updated"
  elseif field == "range" then
    return "comment_range_updated"
  elseif field == "resolved" then
    return value and "comment_resolved" or "comment_reopened"
  elseif field == "uri" then
    return "comment_uri_updated"
  elseif field == "meta" then
    return "comment_meta_updated"
  elseif field == "author" then
    return "comment_author_updated"
  end
  return "comment_updated"
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

  local records = {}
  local db, err = sqlite_db(root)
  if not db then
    vim.notify(("manicule: failed to open sqlite store for %s: %s"):format(root, tostring(err)), vim.log.levels.ERROR)
    cache[root] = {
      records = records,
      dirty = false,
      base_by_id = {},
      removed = {},
      last_seen_event_id = 0,
    }
    return records
  end
  records = sqlite_read_records(db, root)
  cache[root] = {
    records = records,
    dirty = false,
    base_by_id = by_id(records),
    removed = {},
    last_seen_event_id = sqlite_last_event_id(db, root),
  }
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

  local db, db_err = sqlite_db(root)
  if not db then
    return false, db_err
  end
  local ok, err = db:transaction(function()
    local now = os.time()

    for id, removed in pairs(entry.removed or {}) do
      local _, deleted_at = sqlite_get_record(db, root, id, true)
      if not deleted_at then
        local event_ok, event_err =
          sqlite_insert_event(db, root, id, "comment_deleted", { deleted_at = now, previous = removed }, now)
        if not event_ok then
          return false, event_err
        end
        local tombstone = vim.deepcopy(removed or {})
        tombstone.id = tombstone.id or id
        tombstone.deleted_at = now
        tombstone.updated_at = now
        local upsert_ok, upsert_err = sqlite_upsert_record(db, root, tombstone, now)
        if not upsert_ok then
          return false, upsert_err
        end
      end
    end

    for _, record in ipairs(entry.records or {}) do
      if type(record) == "table" and record.id ~= nil and not is_ephemeral_record(record) then
        record.scope = record.scope or "project"
        record.project_root = record.project_root or root
        local id = tostring(record.id)
        local base = entry.base_by_id and entry.base_by_id[id] or nil
        if not base then
          local current = sqlite_get_record(db, root, id, true)
          if not current then
            local event_ok, event_err = sqlite_insert_event(db, root, id, "comment_created", { record = record }, now)
            if not event_ok then
              return false, event_err
            end
            local upsert_ok, upsert_err = sqlite_upsert_record(db, root, record)
            if not upsert_ok then
              return false, upsert_err
            end
          end
        else
          local fields = changed_fields(base, record)
          if has_changes(fields) then
            local projected, deleted_at = sqlite_get_record(db, root, id, true)
            if not deleted_at then
              projected = projected or vim.deepcopy(base)
              for _, field in ipairs(RECORD_FIELDS) do
                if fields[field] then
                  projected[field] = vim.deepcopy(record[field])
                  projected.updated_at = record.updated_at or now
                  local event_ok, event_err =
                    sqlite_insert_event(db, root, id, event_kind_for_field(field, record[field]), {
                      field = field,
                      value = record[field],
                      updated_at = projected.updated_at,
                    }, now)
                  if not event_ok then
                    return false, event_err
                  end
                end
              end
              local upsert_ok, upsert_err = sqlite_upsert_record(db, root, projected)
              if not upsert_ok then
                return false, upsert_err
              end
            end
          end
        end
      end
    end
    return true
  end)
  if not ok then
    return false, err
  end
  local fresh_records, read_err = sqlite_read_records(db, root)
  if read_err then
    return false, read_err
  end
  entry.records = fresh_records
  entry.base_by_id = by_id(fresh_records)
  entry.removed = {}
  entry.last_seen_event_id = sqlite_last_event_id(db, root)
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
  else
    M.sync(root)
  end
  return cache[root].records
end

---Pull externally-written SQLite events into a clean cache entry. Dirty
---entries are left alone so in-flight local edits can save field-level
---patches against their original base snapshot.
---@param root string|nil
---@return boolean changed
function M.sync(root)
  if not root then
    return false
  end
  local entry = cache[root]
  if not entry or entry.dirty then
    return false
  end
  local db = sqlite_db(root)
  if not db then
    return false
  end
  local last = sqlite_last_event_id(db, root)
  if last <= (entry.last_seen_event_id or 0) then
    return false
  end
  local records = sqlite_read_records(db, root)
  entry.records = records
  entry.base_by_id = by_id(records)
  entry.removed = {}
  entry.last_seen_event_id = last
  return true
end

---Synchronize every loaded project cache. Returns roots that changed.
---@return string[]
function M.sync_all()
  local changed = {}
  for root in pairs(cache) do
    if M.sync(root) then
      table.insert(changed, root)
    end
  end
  return changed
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
  local entry = cache[root]
  for i, r in ipairs(records) do
    if r.id == record.id then
      records[i] = record
      entry.dirty = true
      return
    end
  end
  table.insert(records, record)
  entry.dirty = true
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
  local entry = cache[root]
  for i, r in ipairs(records) do
    if r.id == id then
      table.remove(records, i)
      entry.dirty = true
      local base = (entry.base_by_id or {})[tostring(id)]
      entry.removed = entry.removed or {}
      if base then
        entry.removed[tostring(id)] = vim.deepcopy(base)
      end
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
  M.sync_all()
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

---@param root string|nil
---@return table
function M.sqlite_info(root)
  local info = {
    path = M.path(root),
  }
  local available, available_err = sqlite_available()
  info.available = available
  info.available_error = available_err
  if root and available then
    local db, err = sqlite_db(root)
    if db then
      local row = db:row("PRAGMA journal_mode")
      info.journal_mode = row and row.journal_mode
      info.event_count = (db:row("SELECT COUNT(*) AS count FROM events WHERE root = ?", { root }) or {}).count or 0
    else
      info.open_error = err
    end
  end
  return info
end

---@param root string
---@return table[]
function M.events(root)
  if not root then
    return {}
  end
  local db = sqlite_db(root)
  if not db then
    return {}
  end
  local rows = db:rows(
    "SELECT id, record_id, kind, payload, client_id, created_at FROM events WHERE root = ? ORDER BY id",
    {
      root,
    }
  ) or {}
  for _, row in ipairs(rows) do
    if row.payload then
      row.payload = decode_json(row.payload) or {}
    end
  end
  return rows
end

---Internal: exposed for tests.
---@return table<string, manicule.StoreEntry>
function M._cache()
  return cache
end

---Internal: exposed for tests. Resets the cache so a fresh load runs.
function M._reset()
  for _, db in pairs(sqlite_dbs) do
    pcall(function()
      db:close()
    end)
  end
  sqlite_dbs = {}
  cache = {}
  session_cache = { records = {}, dirty = false, loaded = false }
  client_id = ("%s-%d-%d"):format(tostring(vim.fn.hostname()), vim.fn.getpid(), math.random(0, 0xfffffff))
end

return M
