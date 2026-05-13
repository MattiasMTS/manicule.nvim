-- manicule.nvim: URI helpers.
--
-- Centralises the URI logic used by the store and renderer so record
-- identity is expressed uniformly across the plugin. For file-backed
-- buffers the URI is canonicalised through `fs_realpath` before encoding
-- so that opening a file via a symlink still matches records saved
-- against the real path (and vice versa). Non-file URIs (`term://`,
-- `man://`, …) pass through untouched so the session-scope store can
-- key off them directly.
--
-- Canonicalisation can be disabled via `store.canonicalize_symlinks =
-- false` when a user prefers URIs to reflect the access path.

local M = {}

local uv = vim.uv or vim.loop

---Normalised absolute path to Neovim's per-session runtime dir
---(`stdpath('run')`). Buffers produced by plugins that stage content
---there — e.g. the user's `:DiffTool` command that writes left/right
---sides via `vim.fn.tempname()` — resolve to paths under
---`<TMPDIR>/nvim.<user>/<run-id>/<N>/...`, which change every launch.
---Persisting such a URI means the record can never re-anchor on
---reload, so we treat it as ephemeral.
local RUN_DIR_PREFIX = vim.fs.normalize(vim.fn.stdpath("run")) .. "/"

---Path prefixes we consider ephemeral. Order matters: `RUN_DIR_PREFIX`
---is listed first so reverse-map logic can peel the nvim-runtime
---`nvim.<user>/<run-id>/<N>/` segment before falling back to the plain
---`/var/folders/` case.
local TMP_PREFIXES = {
  RUN_DIR_PREFIX,
  "/tmp/",
  "/private/tmp/",
  "/var/folders/",
  "/private/var/folders/",
}

---Exposed so the adapter (reverse-map) and any other caller share the
---same list without re-declaring the ordering.
---@return string[]
function M.tmp_prefixes()
  return TMP_PREFIXES
end

---The normalised absolute path to `stdpath('run')` (trailing slash).
---@return string
function M.run_dir_prefix()
  return RUN_DIR_PREFIX
end

---Does `abs` (a normalised absolute path) live in a location we
---consider ephemeral and therefore unsuitable for persisting a URI?
---@param abs string
---@return boolean
function M.is_temp_path(abs)
  if type(abs) ~= "string" or abs == "" then
    return false
  end
  for _, p in ipairs(TMP_PREFIXES) do
    if abs:sub(1, #p) == p then
      return true
    end
  end
  return false
end

---Does `abs` (a normalised absolute path) look like a path that was
---staged under Neovim's per-session runtime dir — *any* session, past
---or present?
---
---Matches by shape: either a path under the current `stdpath('run')`
---with one staging bucket before the project-relative suffix, or a
---macOS-style `nvim.<user>/<run-id>/<N>/<suffix>` segment from any
---session. Used by the adapter's reverse-map so staged buffers anchor
---to the real project file rather than the per-launch `<run-id>`.
---@param abs string
---@return string?
function M.nvim_runtime_staged_suffix(abs)
  if type(abs) ~= "string" or abs == "" then
    return nil
  end

  if abs:sub(1, #RUN_DIR_PREFIX) == RUN_DIR_PREFIX then
    local rest = abs:sub(#RUN_DIR_PREFIX + 1)
    local suffix = rest:match("^[^/]+/(.+)$")
    if suffix and suffix:find("/", 1, true) then
      return suffix
    end
  end

  local has_tmp_prefix = false
  for _, p in ipairs(TMP_PREFIXES) do
    if abs:sub(1, #p) == p then
      has_tmp_prefix = true
      break
    end
  end
  if not has_tmp_prefix then
    return nil
  end

  -- Look for a `/nvim.<user>/<run-id>/<N>/<suffix>` segment anywhere in
  -- the path. Four segments minimum after the `nvim.<user>` one.
  return abs:match("/nvim%.[^/]+/[^/]+/[^/]+/(.+)$")
end

---@param abs string
---@return boolean
function M.is_nvim_runtime_staged_path(abs)
  return M.nvim_runtime_staged_suffix(abs) ~= nil
end

---Return the normalised absolute path of `bufnr`'s bufname, or nil
---when the buffer has no name. Shared with the adapter so temp-path
---detection and URI construction see identical inputs.
---@param bufnr integer
---@return string?
function M.abs_for_bufnr(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

local EPHEMERAL_SCHEME = "manicule://buffer/"
local ephemeral_seq = 0

---Return true when `uri` is a buffer-local, current-session URI for an
---unnamed buffer. These URIs make comments usable for scratch buffers
---but are intentionally not stable across Neovim restarts.
---@param uri string?
---@return boolean
function M.is_ephemeral(uri)
  return type(uri) == "string" and uri:sub(1, #EPHEMERAL_SCHEME) == EPHEMERAL_SCHEME
end

---Return the current-session URI for an unnamed buffer, creating it on
---first use. Stored in a buffer variable so `:file` / `:saveas` can
---rewrite records from the same identity when the buffer later gains a
---real name.
---@param bufnr integer
---@return string?
local function ephemeral_for_bufnr(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, existing = pcall(vim.api.nvim_buf_get_var, bufnr, "manicule_ephemeral_uri")
  if ok and M.is_ephemeral(existing) then
    return existing
  end
  ephemeral_seq = ephemeral_seq + 1
  local uri = ("%s%s/%d"):format(EPHEMERAL_SCHEME, tostring(vim.fn.getpid()), ephemeral_seq)
  pcall(vim.api.nvim_buf_set_var, bufnr, "manicule_ephemeral_uri", uri)
  return uri
end

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

---Parse a codediff.nvim virtual file URL.
---
---codediff creates buffers named like:
---  codediff:///<git-root>///<revision>/<project-relative-path>
---
---The URL is intentionally fugitive-like but not percent-encoded. We
---treat it as a view of `<git-root>/<path>` so comments added from a
---CodeDiff buffer share identity with the working-tree file and sinks
---do not leak the virtual scheme in review payloads.
---@param value string?
---@return {git_root:string, revision:string, path:string}?
function M.codediff_parts(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local git_root, revision, path = value:match("^codediff:///(.-)///([^/]+)/(.+)$")
  if not git_root or git_root == "" or not revision or revision == "" or not path or path == "" then
    return nil
  end
  git_root = vim.fs.normalize((git_root:gsub("\\", "/"):gsub("/+$", "")))
  path = path:gsub("\\", "/"):gsub("^/+", "")
  if git_root == "" or path == "" then
    return nil
  end
  return {
    git_root = git_root,
    revision = revision,
    path = path,
  }
end

---Resolve a codediff.nvim virtual URL to the project file path it
---represents, or nil for non-CodeDiff URIs.
---@param value string?
---@return string?
function M.codediff_path(value)
  local parts = M.codediff_parts(value)
  if not parts then
    return nil
  end
  return vim.fs.normalize(parts.git_root .. "/" .. parts.path)
end

---Return the canonical URI for a buffer, as `manicule` stores it.
---For file-backed buffers with a readable path, resolves symlinks via
---`vim.uv.fs_realpath` before encoding; non-file URIs (term://, etc.)
---pass through. Unnamed buffers get a current-session-only
---`manicule://buffer/...` URI so scratch buffers can still carry
---comments until they are sent or named.
---@param bufnr integer
---@return string?
function M.for_bufnr(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return ephemeral_for_bufnr(bufnr)
  end
  local scheme = scheme_of(name)
  if scheme and scheme ~= "file" then
    -- Pass-through for term://, man://, etc. — session-scope records
    -- key off these directly.
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

---Find a loaded buffer that currently corresponds to `uri`.
---@param uri string
---@return integer?
function M.bufnr_for_uri(uri)
  if type(uri) ~= "string" or uri == "" then
    return nil
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      if M.is_ephemeral(uri) then
        local ok, existing = pcall(vim.api.nvim_buf_get_var, bufnr, "manicule_ephemeral_uri")
        if ok and existing == uri then
          return bufnr
        end
      elseif vim.api.nvim_buf_get_name(bufnr) == uri then
        return bufnr
      end
    end
  end
  return nil
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

---Extract a filesystem path from a file:// or supported virtual-file URI.
---@param uri string
---@return string?
function M.to_path(uri)
  if type(uri) ~= "string" or uri == "" then
    return nil
  end
  local codediff_path = M.codediff_path(uri)
  if codediff_path then
    return codediff_path
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
