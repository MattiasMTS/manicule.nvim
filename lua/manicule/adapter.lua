-- manicule.nvim: buffer identity adapter.
--
-- `identify(bufnr)` is the single source of truth for "where do
-- comments on this buffer land?". It returns a `manicule.Identity` with:
--
--   * `uri`: the URI records are keyed under. For the reference side of
--     a git diff pair this is the *working-tree* URI — comments anchor
--     to the working copy regardless of which side the user opened.
--   * `scope`: `"project"` when a project root resolves, `"session"`
--     when we need the single-file session store (unrooted buffers and
--     special buftypes like terminal/help).
--   * `project_root`: absolute root path when `scope == "project"`.
--   * `is_writable`: may `M.add` create a record against this identity?
--     False on the reference side of a git diff pair and on read-only
--     buftypes (quickfix, prompt, cmdwin).
--   * `diff_side`: `"working"`, `"reference"`, or nil. Only set when the
--     buffer participates in a diff-mode pair.
--   * `reject_reason`: human-readable message surfaced to the user via
--     notify when `is_writable == false`.
--
-- Diff-pair detection walks the current tabpage's windows, collecting
-- buffers with &diff set, and classifies each by whether its normalized
-- path sits under a temp prefix (/tmp, /var/folders/…, /private/...).
-- A 2-window pair with exactly one "real" side gives us the
-- working-tree buffer; the other is the reference side. Plain `nvim -d
-- a.lua b.lua` with no temp buffer leaves the heuristic ambiguous, so
-- each buffer is treated as its own identity (each side shows its own
-- comments, each allows add).

local M = {}

---@class manicule.Identity
---@field uri string
---@field scope "project"|"session"
---@field project_root string?
---@field is_writable boolean
---@field diff_side "working"|"reference"|nil
---@field reject_reason string?

---Prefixes that identify a "reference" side — a temp file produced by
---git difftool, a stash-blob extraction, etc. macOS symlinks `/tmp` and
---`/var/folders/...` under `/private`, so both variants are listed.
local TEMP_PREFIXES = {
  "/tmp/",
  "/private/tmp/",
  "/var/folders/",
  "/private/var/folders/",
}

---@param path string
---@return boolean
local function is_temp_path(path)
  if not path or path == "" then
    return false
  end
  for _, prefix in ipairs(TEMP_PREFIXES) do
    if path:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

---Normalize a buffer's name to an absolute filesystem path (no URI
---decoding). Returns nil when the buffer has no name.
---@param bufnr integer
---@return string?
local function bufname_abs(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

---Detect whether `bufnr` is the reference side of a git-difftool pair.
---
---The heuristic: look at every window in the current tab with `&diff`
---on. If two such windows exist and exactly one has a temp-prefix
---bufname, that temp side is the reference and the other is the
---working tree. Zero/one diff windows, both temp, or both non-temp all
---return nil (caller falls through to plain project resolution).
---@param bufnr integer
---@return { working_uri: string, working_bufnr: integer, reference_bufnr: integer }?, string? err
function M.resolve_diff_pair(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local diff_bufs = {}
  for _, winid in ipairs(wins) do
    if vim.api.nvim_win_is_valid(winid) and vim.wo[winid].diff then
      local b = vim.api.nvim_win_get_buf(winid)
      local seen = false
      for _, existing in ipairs(diff_bufs) do
        if existing == b then
          seen = true
          break
        end
      end
      if not seen then
        table.insert(diff_bufs, b)
      end
    end
  end

  if #diff_bufs < 2 then
    return nil
  end

  local temp_bufs = {}
  local real_bufs = {}
  for _, b in ipairs(diff_bufs) do
    local path = bufname_abs(b)
    if path and is_temp_path(path) then
      table.insert(temp_bufs, b)
    else
      table.insert(real_bufs, b)
    end
  end

  if #real_bufs == 1 and #temp_bufs >= 1 then
    local working_bufnr = real_bufs[1]
    local working_uri = require("manicule.uri").for_bufnr(working_bufnr)
    if not working_uri then
      return nil, "working-tree buffer has no URI"
    end
    -- Pair *this* bufnr with the working-tree side. The caller already
    -- knows which side `bufnr` is; we just need to expose both sides.
    local reference_bufnr
    for _, b in ipairs(temp_bufs) do
      if b == bufnr then
        reference_bufnr = b
        break
      end
    end
    -- If `bufnr` itself isn't one of the temp diff bufs but is the
    -- working one, still report the pair so the caller sees diff_side
    -- context.
    if not reference_bufnr then
      reference_bufnr = temp_bufs[1]
    end
    return {
      working_uri = working_uri,
      working_bufnr = working_bufnr,
      reference_bufnr = reference_bufnr,
    }
  end

  if #real_bufs >= 2 or #temp_bufs >= 2 and #real_bufs == 0 then
    -- Both sides real (plain `nvim -d`) → no pairing; or both sides
    -- temp (rare, but nothing useful we can do). Caller treats each
    -- buffer as its own identity.
    return nil, "ambiguous diff pair"
  end

  return nil
end

---Which buftypes we accept under session scope and whether they're
---writable. Returning a tuple keeps the reject reason collocated with
---the mapping.
---@param buftype string
---@return boolean writable, string? reject_reason
local function session_policy_for_buftype(buftype)
  if buftype == "" or buftype == "acwrite" or buftype == "help" or buftype == "nofile" or buftype == "nowrite" then
    return true
  end
  if buftype == "terminal" then
    return true
  end
  if buftype == "prompt" then
    return false, "prompt buffers don't accept comments"
  end
  if buftype == "quickfix" then
    return false, "quickfix buffers don't accept comments"
  end
  return false, ("buftype %q doesn't accept comments"):format(buftype)
end

---Is the user currently looking at the command-line window (cmdwin)?
---The idiomatic check is `vim.fn.getcmdwintype()` — a non-empty return
---means the cmdwin is active.
---@return boolean
local function in_cmdwin()
  local ok, ty = pcall(vim.fn.getcmdwintype)
  if not ok then
    return false
  end
  return type(ty) == "string" and ty ~= ""
end

---Resolve the identity for a buffer. Returns nil only when the buffer
---cannot be identified at all (no bufname AND no special buftype that
---we can describe).
---@param bufnr integer
---@return manicule.Identity?, string? err
function M.identify(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid buffer"
  end

  local uri_mod = require("manicule.uri")
  local store = require("manicule.store")
  local config = require("manicule.config")

  local buftype = vim.bo[bufnr].buftype
  local uri = uri_mod.for_bufnr(bufnr)

  -- Reject-only buftypes: we don't need a URI to tell the user these
  -- buffers are off-limits. Quickfix and prompt buffers typically
  -- carry no bufname, so the URI fallthrough below would drop them.
  if buftype == "quickfix" then
    return {
      uri = uri or "",
      scope = "session",
      project_root = nil,
      is_writable = false,
      diff_side = nil,
      reject_reason = "quickfix buffers don't accept comments",
    }
  end

  if not uri then
    return nil, "buffer has no bufname"
  end

  -- Cmdwin is its own weird thing: we refuse to touch it regardless of
  -- buftype. Detection runs before any other branch.
  if in_cmdwin() then
    return {
      uri = uri,
      scope = "session",
      project_root = nil,
      is_writable = false,
      diff_side = nil,
      reject_reason = "command-line window doesn't accept comments",
    }
  end

  -- Diff-pair handling: only meaningful for regular file buffers. A
  -- terminal with &diff on (which shouldn't exist) has no working/ref
  -- semantics worth talking about.
  if buftype == "" and uri_mod.is_file(uri) then
    local pair = M.resolve_diff_pair(bufnr)
    if pair then
      local store_mod = require("manicule.store")
      if bufnr == pair.reference_bufnr then
        local working_path = bufname_abs(pair.working_bufnr)
        local reject = string.format(
          "this is a reference view of %s; add comments on the working-tree side",
          working_path or pair.working_uri
        )
        -- Resolve project root against the working-tree buffer so the
        -- reference side still routes records to the right project.
        local root
        if pair.working_bufnr and vim.api.nvim_buf_is_valid(pair.working_bufnr) then
          root = vim.fs.root(pair.working_bufnr, config.current.store.root_markers)
        end
        return {
          uri = pair.working_uri,
          scope = root and "project" or "session",
          project_root = root,
          is_writable = false,
          diff_side = "reference",
          reject_reason = reject,
        }
      elseif bufnr == pair.working_bufnr then
        local root = store_mod.root()
        return {
          uri = uri,
          scope = root and "project" or "session",
          project_root = root,
          is_writable = true,
          diff_side = "working",
        }
      end
    end
    -- Fall through when pair is nil (not in diff, or both-real/both-temp).
  end

  if uri_mod.is_file(uri) and buftype == "" then
    local root = store.root()
    if root then
      return {
        uri = uri,
        scope = "project",
        project_root = root,
        is_writable = true,
        diff_side = nil,
      }
    end
    -- Unrooted plain file buffer: route to session if the user allows.
    if config.current.store.persist_unrooted then
      return {
        uri = uri,
        scope = "session",
        project_root = nil,
        is_writable = true,
        diff_side = nil,
      }
    end
    return {
      uri = uri,
      scope = "session",
      project_root = nil,
      is_writable = false,
      diff_side = nil,
      reject_reason = "buffer is not in a project (enable store.persist_unrooted to use the session store)",
    }
  end

  -- Special buftype / non-file URI: session scope.
  local writable, reason = session_policy_for_buftype(buftype)
  return {
    uri = uri,
    scope = "session",
    project_root = nil,
    is_writable = writable,
    diff_side = nil,
    reject_reason = (not writable) and reason or nil,
  }
end

return M
