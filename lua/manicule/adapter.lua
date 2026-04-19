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

---Temp-path detection lives in `manicule.uri` so the store's load-time
---cleanup, the reverse-map in this module, and the diff-pair heuristic
---all share a single list. On macOS `/tmp` and `/var/folders/...`
---symlink under `/private`, and the nvim-runtime prefix
---(`stdpath('run')`) lives under `/var/folders/...` as well — temp
---detection collapses all of these.
local function is_temp_path(path)
  return require("manicule.uri").is_temp_path(path)
end

---Normalize a buffer's name to an absolute filesystem path (no URI
---decoding). Returns nil when the buffer has no name. Thin delegate to
---`manicule.uri.abs_for_bufnr` so adapter + reverse-map + store cleanup
---all see identical normalisation.
---@param bufnr integer
---@return string?
local function bufname_abs(bufnr)
  return require("manicule.uri").abs_for_bufnr(bufnr)
end

---Attempt to reverse-map a buffer path that looks like an
---nvim-runtime staged copy back to a real, on-disk file inside the
---current project / cwd / HOME.
---
---The typical source is a plugin (e.g. the user's `:DiffTool`) that
---writes a staged copy via `vim.fn.tempname()` under
---`<stdpath('run')>/<N>/<project-relative-path>`, which normalises
---to `.../nvim.<user>/<run-id>/<N>/<project-relative-path>` on disk.
---On next launch the same file resolves to a different URI under a new
---`<run-id>`, so persisting the staged URI leaves the record
---permanently unanchored. Locating the `/nvim.<user>/<run-id>/<N>/`
---segment in the path, peeling it, and resolving the remainder against
---the real project reverses that mapping.
---
---Returns the canonicalised URI of the single on-disk candidate, or
---nil + a human-readable reason when the map is ambiguous, missing, or
---the path had no useful suffix. Caller is expected to have already
---confirmed the shape via `uri.is_nvim_runtime_staged_path`.
---@param abs string absolute, `vim.fs.normalize`d path
---@return string? uri, string? err
local function reverse_map_temp_path(abs)
  local config = require("manicule.config")
  local uv = vim.uv or vim.loop

  -- Locate the `/nvim.<user>/<run-id>/<N>/<suffix>` segment anywhere
  -- in the path. `string.match` returns the captured suffix directly.
  -- Allowed user, run-id, and N are all `[^/]+` — we don't care about
  -- their content, only that three full segments sit between us and
  -- the project-relative tail.
  local suffix = abs:match("/nvim%.[^/]+/[^/]+/[^/]+/(.+)$")
  if not suffix or suffix == "" or not suffix:find("/", 1, true) then
    return nil, "staged path has no project-relative suffix"
  end

  local candidates = {}
  local seen = {}
  local function push(base)
    if not base or base == "" then
      return
    end
    local candidate = vim.fs.normalize(base .. "/" .. suffix)
    if seen[candidate] then
      return
    end
    seen[candidate] = true
    local stat = uv.fs_stat(candidate)
    if stat and stat.type == "file" then
      table.insert(candidates, candidate)
    end
  end

  local cfg = (config.current or {}).store or {}
  push(vim.fs.root(0, cfg.root_markers or { ".git", ".hg", "package.json" }))
  push(vim.fn.getcwd())
  -- HOME fallback: only engage when the suffix looks like a dotfile /
  -- user-config path (e.g. `.config/foo/bar`). Without this guard any
  -- staged file with a common suffix (`README.md`, `Makefile`, …) would
  -- accidentally resolve under `$HOME` and mislabel a project file as
  -- personal.
  if suffix:match("^%.") then
    push(vim.env.HOME)
  end

  if #candidates == 0 then
    return nil, ("buffer is a nvim-runtime-staged path (%s); could not map to a real file"):format(abs)
  end
  if #candidates > 1 then
    return nil, "ambiguous reverse-map; open the real file directly"
  end

  local resolved = candidates[1]
  local real = uv.fs_realpath(resolved)
  return vim.uri_from_fname(real or resolved)
end

---Is `bufnr` displayed in a window with `&diff` set? Reverse-mapping
---is off-limits for diff views because the diff-pair logic owns those
---temp paths and needs the staged URI to find the sibling buffer.
---@param bufnr integer
---@return boolean
local function bufnr_in_diff_window(bufnr)
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr and vim.wo[winid].diff then
      return true
    end
  end
  return false
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

  -- Reject-only buftypes: we don't need a URI to tell the user these
  -- buffers are off-limits. Quickfix and prompt buffers typically
  -- carry no bufname, so the URI fallthrough below would drop them.
  if buftype == "quickfix" then
    return {
      uri = uri_mod.for_bufnr(bufnr) or "",
      scope = "session",
      project_root = nil,
      is_writable = false,
      diff_side = nil,
      reject_reason = "quickfix buffers don't accept comments",
    }
  end

  -- Reverse-map staged buffers BEFORE any other path resolution. The
  -- source of these is typically a user command that writes a staged
  -- copy (e.g. `:DiffTool`'s `vim.fn.tempname()` pairs) under
  -- `stdpath('run')` / `/var/folders/...`. Diff-mode buffers skip this
  -- branch — the diff-pair detection below owns the staged-URI case
  -- for them and needs the raw path to pair sibling buffers.
  local abs = bufname_abs(bufnr)
  if not abs then
    return nil, "buffer has no bufname"
  end
  local uri
  local reverse_mapped_path ---@type string? absolute path we mapped to (nil when not reverse-mapped)
  -- Only reverse-map paths that look like an nvim-runtime staged copy
  -- (`.../nvim.<user>/<run-id>/<N>/...`): these are known to be
  -- per-session-ephemeral (the `<run-id>` rotates every launch) so a
  -- persisted URI can never re-anchor. A plain `/tmp/foo.txt` the user
  -- opened as a scratch is *not* ephemeral from manicule's perspective
  -- — the URI is stable across launches — so it still flows through
  -- the normal session-scope path. Diff-mode buffers also skip this
  -- branch; the diff-pair detection below owns them and needs the raw
  -- staged path to pair sibling buffers.
  if buftype == "" and uri_mod.is_nvim_runtime_staged_path(abs) and not bufnr_in_diff_window(bufnr) then
    local mapped, map_err = reverse_map_temp_path(abs)
    if not mapped then
      return nil, map_err
    end
    uri = mapped
    reverse_mapped_path = uri_mod.to_path(mapped)
  else
    uri = uri_mod.for_bufnr(bufnr)
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
    -- When we reverse-mapped a staged buffer, resolve the project root
    -- from the *mapped* path rather than the current buffer: the
    -- staged path lives under `/var/folders/...`, whose parents never
    -- contain a `.git` marker, so `store.root()` (which runs against
    -- the current buffer) would always return nil and route the
    -- record into session scope instead of the real project store.
    local root
    if reverse_mapped_path then
      root = vim.fs.root(reverse_mapped_path, config.current.store.root_markers)
    else
      root = store.root()
    end
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
