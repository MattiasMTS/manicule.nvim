-- manicule.nvim: per-project persistence.
--
-- Comment record schema
-- ---------------------
--
--   {
--     id = "uuid",
--     path = "src/foo.lua",
--     range = { start = {row,col}, end_ = {row,col} },
--     body = "text",
--     author = "email",
--     created_at = 1731000000,
--     updated_at = 1731000000,
--     resolved = false,
--     meta = {},
--   }
--
-- Records live in a JSON file at the project root, resolved via
-- `config.store.path_resolver()` and named `config.store.filename`.
--
-- TODO(manicule): atomic write strategy — serialize to `<path>.tmp`
-- then `vim.uv.fs_rename(tmp, path)` so a crash mid-write never leaves
-- a truncated store file. Consider an `fsync` on the tmp fd first on
-- platforms where durability matters.

local M = {}

---Absolute path to the store file for the current project, or nil
---if no project root can be resolved.
---@return string|nil
function M.path()
  -- TODO(manicule): combine config.store.path_resolver() with
  -- config.store.filename and return via vim.fs.joinpath.
  error("TODO(manicule): store.path not implemented")
end

---Load all comment records from disk. Returns an empty list if the
---store does not exist yet.
---@return table[]
function M.load()
  -- TODO(manicule): read M.path(), vim.json.decode, validate shape.
  error("TODO(manicule): store.load not implemented")
end

---Persist comment records to disk atomically.
---@param records table[]
function M.save(records)
  -- TODO(manicule): write `.tmp` then vim.uv.fs_rename into place.
  local _ = records
  error("TODO(manicule): store.save not implemented")
end

return M
