-- manicule.nvim: URI helpers.
--
-- Centralises the URI logic used by the store and renderer so record
-- identity is expressed uniformly across the plugin. For file-backed
-- buffers the URI is canonicalised through `fs_realpath` before encoding
-- so that opening a file via a symlink still matches records saved
-- against the real path (and vice versa). Non-file URIs (`term://`,
-- `man://`, …) pass through untouched so scope="session" adapters in
-- phase 3 can key off them without further work.
--
-- Canonicalisation can be disabled via `store.canonicalize_symlinks =
-- false` when a user prefers URIs to reflect the access path.

local M = {}

local uv = vim.uv or vim.loop

---Return true if symlink canonicalisation is enabled (default true).
---@return boolean
local function canonicalize_symlinks()
  local ok, config = pcall(require, "manicule.config")
  if not ok then
    return true
  end
  local cfg = (config.get() or {}).store or {}
  if cfg.canonicalize_symlinks == false then
    return false
  end
  return true
end

---Extract the URI scheme from `name`, or nil if there isn't one.
---@param name string
---@return string?
local function scheme_of(name)
  return name:match("^([a-zA-Z][%w+.-]*):")
end

---Return the canonical URI for a buffer, as `manicule` stores it.
---For file-backed buffers with a readable path, resolves symlinks via
---`vim.uv.fs_realpath` before encoding; non-file URIs (term://, etc.)
---pass through.
---@param bufnr integer
---@return string?
function M.for_bufnr(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local scheme = scheme_of(name)
  if scheme and scheme ~= "file" then
    -- Pass-through for term://, man://, etc. Phase 3 will route these
    -- into the session-scoped store.
    return name
  end
  local abs = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  if canonicalize_symlinks() then
    local real = uv.fs_realpath(abs)
    if real then
      abs = real
    end
  end
  return vim.uri_from_fname(abs)
end

---Return the canonical URI for an absolute file path (post-realpath
---when canonicalisation is enabled).
---@param path string
---@return string
function M.for_path(path)
  local abs = vim.fs.normalize(path)
  if canonicalize_symlinks() then
    local real = uv.fs_realpath(abs)
    if real then
      abs = real
    end
  end
  return vim.uri_from_fname(abs)
end

---Extract a filesystem path from a URI, or nil if the URI isn't file://.
---@param uri string
---@return string?
function M.to_path(uri)
  if type(uri) ~= "string" or uri == "" then
    return nil
  end
  if not M.is_file(uri) then
    return nil
  end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if not ok then
    return nil
  end
  return path
end

---Is this URI a file:// URI?
---@param uri string
---@return boolean
function M.is_file(uri)
  if type(uri) ~= "string" or uri == "" then
    return false
  end
  return uri:sub(1, 7) == "file://"
end

return M
