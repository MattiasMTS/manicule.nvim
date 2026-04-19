-- manicule.nvim: per-project persistence.
--
-- Comment record schema (phase 1)
-- -------------------------------
--
--   {
--     id           = "unique",                            -- id.new()
--     uri          = "file:///abs/path.lua",              -- canonical URI
--     scope        = "project",                           -- only "project"
--                                                         -- exists in phase 1;
--                                                         -- phase 3 introduces
--                                                         -- scope = "session"
--     project_root = "/abs/path/to/root",                 -- absolute root
--     range        = { start = {row,col}, end_ = {row,col} },
--     body         = "text",
--     author       = "user@example.com",
--     created_at   = 1731000000,
--     updated_at   = 1731000000,
--     resolved     = false,
--     meta         = {},                                  -- free-form
--   }
--
-- Records are keyed by URI — the pre-phase-1 `path` field (project-
-- relative string) is gone so the same machinery can later anchor
-- non-file buffers (term://, scratch, …) in the session-scoped store
-- without needing a second schema. `manicule.uri.for_bufnr` runs every
-- buffer path through `fs_realpath` before encoding so opening a file
-- via a symlink still matches records saved against the real path.
--
-- On-disk layout
-- --------------
-- Records live in `stdpath("state")/manicule/` (configurable via
-- `config.store.dir`), one file per project root. Path separators in
-- the root are escaped with `[\\/:]+` → `%%` (persistence.nvim
-- convention) so every root flattens to a single filename. If
-- `config.store.branch` is true, the current git branch is appended as
-- `%%<branch>` before the extension — except for `main` and `master`,
-- which collapse to the unsuffixed filename so the common case doesn't
-- fragment.
--
-- The file is named `<escaped-root>.v2.<format>` (with the optional
-- `%%<branch>` segment inserted before `.v2`). The `.v2` suffix marks
-- the URI-identity schema — pre-v2 files written by the `(root, path)`
-- identity version are ignored entirely so a user running a mixed
-- version set up never sees a silently-truncated record list.
--
-- The envelope format is `vim.mpack` by default (`config.store.format =
-- "mpack"`); `"json"` is available for users who want a human-readable
-- file. The on-disk payload is `{ version = 2, records = [...] }`.
-- `decode()` rejects anything that doesn't match that shape (notify
-- WARN, start empty) — this includes both corrupt bytes and the old
-- bare-array schema.
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

local STORE_VERSION = 2

---@class manicule.StoreEntry
---@field records table[]
---@field dirty boolean

---@type table<string, manicule.StoreEntry>
local cache = {}

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
  -- `.v2` marks the URI-identity envelope. Old `.mpack` / `.json`
  -- files from the pre-phase-1 schema are left on disk untouched
  -- rather than silently migrated — users can delete them once they
  -- confirm the new files carry the records they care about.
  return cfg.dir .. name .. ".v2." .. cfg.format
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

---Encode records per the configured format. Wraps them in the
---`{ version = STORE_VERSION, records = [...] }` envelope.
---@param records table[]
---@return string|nil data, string? err
local function encode(records)
  local cfg = config.current.store
  local envelope = { version = STORE_VERSION, records = records }
  if cfg.format == "json" then
    local ok, encoded = pcall(vim.json.encode, envelope)
    if not ok then
      return nil, tostring(encoded)
    end
    return encoded
  end
  -- Default / "mpack".
  local ok, encoded = pcall(vim.mpack.encode, envelope)
  if not ok then
    return nil, tostring(encoded)
  end
  return encoded
end

---Decode `data` using the configured format. Expects the versioned
---`{ version = 2, records = [...] }` envelope — any other shape
---(including the pre-v2 bare-array schema) is treated as corrupt /
---incompatible and produces an empty list plus a WARN notify.
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
  -- An empty table is a valid empty store regardless of whether the
  -- decoder tags it as list/dict. (Freshly-created files can look this
  -- way before any record is persisted.)
  if next(decoded) == nil then
    return {}
  end
  if decoded.version ~= STORE_VERSION then
    vim.notify(
      ("manicule: store %s has unsupported version %s (expected %d); starting fresh"):format(
        path,
        tostring(decoded.version),
        STORE_VERSION
      ),
      vim.log.levels.WARN
    )
    return {}
  end
  local records = decoded.records
  if type(records) ~= "table" then
    vim.notify(("manicule: store %s missing records array; starting fresh"):format(path), vim.log.levels.WARN)
    return {}
  end
  if next(records) == nil then
    return {}
  end
  if vim.islist and not vim.islist(records) then
    vim.notify(("manicule: unrecognised store shape at %s; starting fresh"):format(path), vim.log.levels.WARN)
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

---Internal: exposed for tests. Resets the cache so a fresh load runs.
function M._reset()
  cache = {}
end

return M
