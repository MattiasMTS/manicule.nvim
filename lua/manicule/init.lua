-- manicule.nvim
-- Public API surface. All heavy `require`s happen inside functions so
-- users with `cmd = {...}` in their lazy spec don't pay the cost on
-- startup.
--
-- Lifecycle events are emitted as native `User` autocmds — there is no
-- `M.on` helper. Subscribe via `vim.api.nvim_create_autocmd`:
--
--   vim.api.nvim_create_autocmd("User", {
--     pattern = "ManiculeAdded",
--     callback = function(ev) vim.print(ev.data) end,
--   })
--
-- Pattern catalog (see `ARCHITECTURE.md` and `doc/manicule.txt`):
--   ManiculeAdded     record
--   ManiculeEdited    record
--   ManiculeDeleted   { id, record }
--   ManiculeResolved  record (with resolved=true)
--   ManiculeSent      { sink, count, ok, err }
--   ManiculeSynced    { roots }
--   ManiculeOrphaned  { id, record }
--   ManiculeRenamed   { bufnr, old_uri, new_uri, record_count }
--
-- Rendering is owned by `lua/manicule/ui/render.lua`. `init.lua`
-- resolves records for the affected buffer on every mutation and
-- delegates to `render.reconcile(bufnr, records)`, which is idempotent.

local M = {}

local uv = vim.uv or vim.loop
local sync_timer

---@class manicule.Config
---@field store? table
---@field sinks? table
---@field ui? manicule.UIConfig

local function emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data })
end

---Return the 0-indexed range currently in play for M.add.
---@param opts {range?: table}|nil
---@return {start: integer[], end_: integer[]}
local function resolve_range(opts)
  if opts and opts.range then
    local r = opts.range
    -- Support {l1, l2} (command-line style, 1-indexed) and full 0-indexed form.
    if r.start and r.end_ then
      return r
    end
    local l1, l2 = r[1], r[2] or r[1]
    return {
      start = { l1 - 1, 0 },
      end_ = { l2 - 1, 0 },
    }
  end
  -- Visual selection: when called from select mode the marks '< and '>
  -- are set. If the cursor is currently in visual mode we use the live
  -- positions instead (the marks update only after leaving visual mode).
  local mode = vim.fn.mode()
  local was_visual = mode == "v" or mode == "V" or mode == "\022"
  if was_visual then
    vim.cmd.normal({ args = { "\27" }, bang = true }) -- leave visual so '< '> finalize
  end
  -- Only consult '<  '> when we just left visual mode. Consulting them
  -- unconditionally from normal-mode entry points picks up a stale
  -- selection from an earlier visual action — which made `<leader>ma`
  -- in normal mode anchor to the wrong lines.
  if was_visual then
    local vstart = vim.fn.getpos("'<")
    local vend = vim.fn.getpos("'>")
    if vstart[2] > 0 and vend[2] > 0 then
      local bufnr = vim.api.nvim_get_current_buf()
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      ---Clamp a 1-indexed (row, col) pair from `getpos` to valid buffer
      ---coordinates. Linewise visual sets col to `v:maxcol` (INT_MAX),
      ---which makes `nvim_buf_set_extmark` reject the range — the record
      ---is stored but never rendered.
      local function clamp(row1, col1)
        local row0 = math.max(0, math.min(row1 - 1, math.max(0, line_count - 1)))
        local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""
        local col0 = math.max(0, math.min(col1 - 1, #line))
        return row0, col0
      end
      local sr, sc = clamp(vstart[2], vstart[3])
      local er, ec = clamp(vend[2], vend[3])
      return {
        start = { sr, sc },
        end_ = { er, ec },
      }
    end
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  return { start = { cur[1] - 1, 0 }, end_ = { cur[1] - 1, 0 } }
end

---Resolve the project root that should own comments for `bufnr`. Routes
---through `adapter.identify` first so staged buffers
---(`<stdpath('run')>/nvim.<user>/<run-id>/<N>/<suffix>` — DiffToolGit
---and friends) reach the real project store via the adapter's
---reverse-map. Falls back to `vim.fs.root(bufnr, ...)` only when the
---adapter can't resolve a project identity, so scheduled autocmds operate
---on their event buffer instead of whatever happens to be current.
---@param bufnr integer
---@return string?
local function project_root_for_bufnr(bufnr)
  local adapter = require("manicule.adapter")
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local identity = adapter.identify(bufnr)
    if identity and identity.scope == "project" and identity.project_root then
      return identity.project_root
    end
    local cfg = require("manicule.config").get()
    local markers = ((cfg or {}).store or {}).root_markers
    local ok, root = pcall(vim.fs.root, bufnr, markers)
    if ok then
      return root
    end
  end
  return nil
end

---Resolve the project root for the current buffer.
---@return string?
local function current_project_root()
  return project_root_for_bufnr(vim.api.nvim_get_current_buf())
end

---Return records that belong to `bufnr` (URI equality). Merges project
---records from the currently-resolved root AND session records keyed on
---the same URI, so a session-scope comment on a scratch / terminal /
---unrooted buffer renders alongside project records. Resolves identity
---via `manicule.adapter` so the reference side of a diff pair returns
---no records (render skips the temp side per the phase-2 "working-tree
---only" policy) while plain buffers resolve via URI equality.
---@param bufnr integer
---@return table[]
local function records_for_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local store = require("manicule.store")
  local adapter = require("manicule.adapter")
  local identity = adapter.identify(bufnr)
  if not identity or not identity.uri then
    return {}
  end
  -- Phase 2 policy: do not render on the reference side of a diff pair.
  -- The reject notify on `M.add` tells the user to switch buffers.
  if identity.diff_side == "reference" then
    return {}
  end
  return store.all_for_uri(identity.uri, identity.project_root)
end

local refresh_viewport

---Run reconcile for every buffer that already has an entry in `buffer_to_path`
---or is loaded and visible. Returns the records passed in.
---@param bufnr integer
local function reconcile_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local store = require("manicule.store")
  -- Route through `current_project_root` so a staged buffer
  -- (DiffToolGit et al.) preloads the *real* project cache — raw
  -- `store.root()` would walk up the staged path under `stdpath('run')`
  -- and miss the project entirely.
  local root = project_root_for_bufnr(bufnr)
  if root then
    store.load(root)
  end
  -- Always load the session store too — a buffer may own records in
  -- either scope (or both, if the user opened the same URI in two
  -- contexts), so we cannot short-circuit on "no root".
  store.session_load()
  local records = records_for_buffer(bufnr)
  require("manicule.ui.render").reconcile(bufnr, records)

  -- For each attached record whose extmark came back invalid, emit a
  -- ManiculeOrphaned event. We resolve via the anchor module so the
  -- shape matches what users have been consuming.
  local anchor = require("manicule.anchor")
  local render = require("manicule.ui.render")
  local mark_ids = render.mark_ids_for_buffer(bufnr)
  for _, record in ipairs(records) do
    local mid = mark_ids[tostring(record.id)]
    if mid then
      local resolved = anchor.resolve(bufnr, mid)
      if resolved and resolved.invalid then
        emit("ManiculeOrphaned", { id = record.id, record = record })
      end
    end
  end
end

---Run reconcile for every loaded listed buffer. Used after mutations
---that may span multiple buffers (e.g. `delete` strips a record that
---could be visible in several windows showing different files).
local function reconcile_all_loaded()
  local render = require("manicule.ui.render")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local records = records_for_buffer(bufnr)
      render.reconcile(bufnr, records)
    end
  end
end

local function refresh_all_loaded_viewports()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      refresh_viewport(bufnr)
    end
  end
end

local function hide_popups_on_leave(bufnr)
  local ok_editor, editor = pcall(require, "manicule.ui.editor")
  if ok_editor and editor.is_opening() then
    return
  end
  require("manicule.ui.render").hide_all_popups(bufnr)
end

local function refresh_external_store_changes(roots)
  if type(roots) ~= "table" or #roots == 0 then
    return
  end
  reconcile_all_loaded()
  refresh_all_loaded_viewports()
  local quickfix = require("manicule.ui.quickfix")
  if quickfix.is_manicule_qf_open() then
    quickfix.refresh()
  end
  emit("ManiculeSynced", { roots = roots })
end

local function start_sync_timer(group)
  local cfg = require("manicule.config").get()
  local interval = tonumber((cfg.store or {}).poll_interval_ms) or 0
  if sync_timer then
    sync_timer:stop()
    sync_timer:close()
    sync_timer = nil
  end
  if interval <= 0 then
    return
  end

  local store = require("manicule.store")
  sync_timer = uv.new_timer()
  if not sync_timer then
    return
  end
  sync_timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      local roots = store.sync_all()
      refresh_external_store_changes(roots)
    end)
  )

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if sync_timer then
        sync_timer:stop()
        sync_timer:close()
        sync_timer = nil
      end
    end,
  })
end

---Run the non-sticky viewport refresh for `bufnr`. Cheap enough to fire
---from scroll / resize / cursor-moved autocmds.
---@param bufnr integer
function refresh_viewport(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local cfg = require("manicule.config").get()
  if (cfg.ui or {}).sticky then
    return
  end
  local records = records_for_buffer(bufnr)
  require("manicule.ui.render").update_viewport_popups(bufnr, records)
end

---Copy live extmark positions back into their records. Extmarks are the
---source of truth while a buffer is open; persisted ranges need to follow
---them before writes, sends, and list formatting.
---@param bufnr integer
---@return { roots: table<string, boolean>, session: boolean, count: integer }
local function sync_positions_for_buffer(bufnr)
  local touched = { roots = {}, session = false, count = 0 }
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return touched
  end

  local store = require("manicule.store")
  local adapter = require("manicule.adapter")
  local render = require("manicule.ui.render")
  local identity = adapter.identify(bufnr)
  if not identity or not identity.uri or identity.diff_side == "reference" then
    return touched
  end

  if identity.project_root then
    store.load(identity.project_root)
  end
  store.session_load()

  local records = store.all_for_uri(identity.uri, identity.project_root)
  if #records == 0 then
    return touched
  end

  local by_id = {}
  for _, record in ipairs(records) do
    by_id[tostring(record.id or "")] = record
  end

  local patches = render.capture_position_patches(bufnr, records)
  for _, patch in ipairs(patches.updates or {}) do
    local record = by_id[tostring(patch.id or "")]
    if record then
      record.range = patch.range
      touched.count = touched.count + 1
      if record.scope == "session" then
        store.session_mark_dirty()
        touched.session = true
      else
        local root = record.project_root or identity.project_root
        if root then
          store.mark_dirty(root)
          touched.roots[root] = true
        end
      end
    end
  end

  return touched
end

---Synchronise every loaded buffer and return the roots that need flushing.
---@return { roots: table<string, boolean>, session: boolean, count: integer }
local function sync_all_loaded_positions()
  local total = { roots = {}, session = false, count = 0 }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local touched = sync_positions_for_buffer(bufnr)
      total.count = total.count + touched.count
      total.session = total.session or touched.session
      for root in pairs(touched.roots) do
        total.roots[root] = true
      end
    end
  end
  return total
end

---@param action string
---@param err string?
local function notify_save_failed(action, err)
  vim.notify(
    ("manicule: failed to persist %s: %s"):format(action, tostring(err or "unknown error")),
    vim.log.levels.ERROR
  )
end

---@param target table
---@param source table
local function replace_table_contents(target, source)
  for key in pairs(target) do
    target[key] = nil
  end
  for key, value in pairs(source) do
    target[key] = value
  end
end

---Bring `bufnr` up to date with the store: reconcile extmarks/popups and
---kick the non-sticky viewport refresh so line-number tints and popups
---materialize immediately. Safe to call for buffers with no records or
---no project root (both helpers early-return). Does NOT emit User
---`Manicule*` events — those are reserved for mutations.
---@param bufnr integer
local function attach_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  reconcile_buffer(bufnr)
  refresh_viewport(bufnr)
end

---Per-bufnr snapshot of the URI that was live when `BufFilePre`
---fired. `:saveas` / `:file` mutate the buffer name before the autocmd
---dispatch chain lands on `BufFilePost`; without snapshotting in
---`BufFilePre` there is no reliable way to recover the old URI for
---the rename rewrite. Keys are cleared once the paired `BufFilePost`
---handler runs (or the buffer is wiped).
---@type table<integer, string>
local pre_rename_uris = {}

---`BufFilePre` handler — stash the buffer's current URI so the paired
---`BufFilePost` can rewrite records whose `uri` matches it.
---
---`:saveas` fires `BufFilePre`/`BufFilePost` on both the originally-
---edited buffer (loaded, listed, carries the records) and a brand-
---new alternate buffer Neovim creates for the prior name (unloaded,
---unlisted). We only care about the loaded one; otherwise the
---alternate's pair would swap the rewrite back as the second
---`BufFilePost` fires.
---@param bufnr integer
local function on_bufname_pre(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local uri = require("manicule.uri").for_bufnr(bufnr)
  if uri then
    pre_rename_uris[bufnr] = uri
  end
end

---Handle a buffer whose name just changed (`:saveas`, `:file`,
---`:Move`-style plugin renames). Looks up the pre-rename URI captured
---by `on_bufname_pre`, rewrites every record whose `uri` matches to
---the new buffer URI, marks the store dirty, saves, reconciles the
---buffer so handles re-attach under the new URI, and fires a single
---`User ManiculeRenamed` autocmd with the aggregate payload. Silent
---no-op when no matching records exist or the URI didn't change.
---@param bufnr integer
local function on_bufname_changed(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    -- Same alternate-buffer filter as `on_bufname_pre`: only the
    -- loaded, records-carrying buffer should drive the rewrite.
    return
  end
  local old_uri = pre_rename_uris[bufnr]
  pre_rename_uris[bufnr] = nil
  local store = require("manicule.store")
  local uri_mod = require("manicule.uri")
  local new_uri = uri_mod.for_bufnr(bufnr)
  if not new_uri or not old_uri or old_uri == new_uri then
    return
  end
  -- Walk both the current project's records and the session store.
  -- A `:saveas` on a session-scope scratch buffer keeps the record's
  -- `scope = "session"` but rewrites the URI — users can
  -- `:ManiculeDelete` and re-add in project scope if they want the
  -- record to move along with the file. This quirk is documented.
  local ids = {}
  local touched_project = false
  -- Use the adapter-resolved root: on a staged buffer `:saveas` is
  -- unlikely, but any read-side "which project owns this buffer?"
  -- question has to reverse-map through the adapter to reach the real
  -- store.
  local root = project_root_for_bufnr(bufnr)
  if root then
    for _, record in ipairs(store.all(root)) do
      if record.uri == old_uri then
        record.uri = new_uri
        table.insert(ids, record.id)
        touched_project = true
      end
    end
    if touched_project then
      store.mark_dirty(root)
      store.save(root)
    end
  end
  local touched_session = false
  for _, record in ipairs(store.session_all()) do
    if record.uri == old_uri then
      record.uri = new_uri
      record.meta = record.meta or {}
      record.meta.ephemeral = uri_mod.is_ephemeral(new_uri) or nil
      table.insert(ids, record.id)
      touched_session = true
    end
  end
  if touched_session then
    store.session_mark_dirty()
    store.session_save()
  end
  if #ids == 0 then
    return
  end
  -- Re-reconcile the buffer so the render layer (which keyed handles
  -- off the old URI via reconcile_buffer) rebuilds against the new
  -- URI. Without this, BufWinEnter's reconcile during the saveas
  -- flow tore down every handle before we rewrote the records.
  reconcile_buffer(bufnr)
  refresh_viewport(bufnr)
  emit("ManiculeRenamed", {
    bufnr = bufnr,
    old_uri = old_uri,
    new_uri = new_uri,
    record_count = #ids,
    ids = ids,
  })
end

---Initialize manicule with user options.
---@param opts manicule.Config|nil
function M.setup(opts)
  opts = opts or {}
  local config = require("manicule.config")
  config.setup(opts)

  -- Register bundled sinks/integrations unless the user opted out.
  require("manicule.sinks").setup(require("manicule.config").get().sinks)

  -- Initialize the render layer (highlights).
  require("manicule.ui.render").setup()

  -- Idempotent augroup: clear = true means a second setup() wins cleanly.
  local group = vim.api.nvim_create_augroup("manicule", { clear = true })
  local store = require("manicule.store")
  start_sync_timer(group)

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(ev)
      vim.schedule(function()
        attach_buffer(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    callback = function(ev)
      hide_popups_on_leave(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(ev)
      -- Avoid doing float reconfigure work from inside the autocmd;
      -- scheduling lets batched events coalesce into a single render.
      vim.schedule(function()
        refresh_viewport(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      require("manicule.ui.render").refresh_highlights()
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local touched = sync_positions_for_buffer(ev.buf)
      -- Route through the adapter-aware helper so a write from a
      -- staged buffer still flushes the right project store. `save`
      -- on nil is a no-op, so the fallback path stays safe.
      local root = project_root_for_bufnr(ev.buf)
      if root then
        local ok, err = store.save(root)
        if not ok then
          notify_save_failed("project store", err)
        end
      end
      for touched_root in pairs(touched.roots) do
        if touched_root ~= root then
          local ok, err = store.save(touched_root)
          if not ok then
            notify_save_failed("project store", err)
          end
        end
      end
      -- A write to a file that owns session-scope records (e.g. an
      -- unrooted scratch that the user `:w <path>`ed) should flush the
      -- session store too. Cheap no-op when nothing is dirty.
      local ok, err = store.session_save()
      if not ok then
        notify_save_failed("session store", err)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
    group = group,
    callback = function(ev)
      require("manicule.ui.render").clear_buffer(ev.buf)
    end,
  })

  -- `:saveas`, `:file`, and plugin-driven renames all fire
  -- BufFilePre (old name still live) → BufFilePost (new name
  -- installed). We snapshot the URI in Pre because by Post the buffer
  -- name has already been swapped, leaving no reliable way to
  -- discover the URI records were filed under. BufFilePost then
  -- rewrites matching records, saves, and fires ManiculeRenamed.
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = group,
    callback = function(ev)
      on_bufname_pre(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(ev)
      vim.schedule(function()
        on_bufname_changed(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      sync_all_loaded_positions()
      store.flush_all()
    end,
  })

  -- Buffer-local keymaps for manicule quickfix lists. `FileType qf`
  -- fires once per qf buffer; we check the list title to avoid
  -- touching grep/diagnostic/other-plugin lists.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "qf",
    callback = function(ev)
      local ok, info = pcall(vim.fn.getqflist, { title = 1 })
      if not ok or type(info) ~= "table" then
        return
      end
      if type(info.title) == "string" and info.title:match("^manicule") then
        require("manicule.ui.quickfix_keymaps").attach(ev.buf)
      end
    end,
  })

  -- Live refresh: any mutation event regenerates the open manicule qf
  -- list in place. `setqflist` mode `"r"` keeps the window open and
  -- preserves the cursor line. A single pattern-matched autocmd
  -- suffices; the refresh path no-ops when no manicule qf is visible.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = {
      "ManiculeAdded",
      "ManiculeEdited",
      "ManiculeDeleted",
      "ManiculeResolved",
      "ManiculeOrphaned",
      "ManiculeRenamed",
      "ManiculeSynced",
    },
    callback = function()
      -- Defer so a burst of events coalesces and we don't mutate the
      -- qflist from inside the autocmd dispatch.
      vim.schedule(function()
        local quickfix = require("manicule.ui.quickfix")
        if quickfix.is_manicule_qf_open() then
          quickfix.refresh()
        end
      end)
    end,
  })

  -- Lazy-load sweep: when the plugin is gated behind `cmd = {...}` /
  -- `keys = {...}` in a lazy spec, `BufReadPost` fires before
  -- `M.setup()` runs, so the autocmd above never sees the buffers the
  -- user already has open. Walk every currently-loaded buffer and run
  -- the same attach path so pre-existing records paint immediately.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      attach_buffer(bufnr)
    end
  end
end

---Build the record and wrap up add().
---@param body string
---@param bufnr integer
---@param range table
local function finalize_add(body, bufnr, range)
  if not body or body == "" then
    return
  end
  local store = require("manicule.store")
  local id_mod = require("manicule.id")
  local ui = require("manicule.ui")
  local adapter = require("manicule.adapter")

  local identity, err = adapter.identify(bufnr)
  if not identity then
    vim.notify(("manicule: %s"):format(err or "buffer has no identity"), vim.log.levels.WARN)
    return
  end
  if not identity.is_writable then
    vim.notify(("manicule: %s"):format(identity.reject_reason or "buffer is not writable"), vim.log.levels.WARN)
    return
  end

  local now = os.time()
  local record = {
    id = id_mod.new(),
    uri = identity.uri,
    scope = identity.scope,
    project_root = identity.project_root,
    range = range,
    body = body,
    author = ui.git_email(),
    created_at = now,
    updated_at = now,
    resolved = false,
    meta = identity.ephemeral and { ephemeral = true } or {},
  }
  -- Invariant canary: re-run `identify` and refuse to persist if it
  -- doesn't reproduce the URI we built the record around. Guards
  -- against regressions where the adapter's build-time and reload-time
  -- URI diverge (staged buffers, future reverse-map bugs) — without
  -- this check, a record with a non-reproducible URI would persist and
  -- never re-anchor.
  local verify, verr = adapter.identify(bufnr)
  if not verify or verify.uri ~= record.uri then
    vim.notify(
      ("manicule: URI invariant violated (expected %s, got %s: %s)"):format(
        record.uri,
        verify and verify.uri or "nil",
        verr or "no err"
      ),
      vim.log.levels.ERROR
    )
    return
  end
  store.put_record(record)
  local ok, err
  if record.scope == "session" then
    ok, err = store.session_save()
  else
    ok, err = store.save(identity.project_root)
  end
  if not ok then
    if record.scope == "session" then
      store.session_remove(record.id)
    else
      store.remove(identity.project_root, record.id)
    end
    notify_save_failed("new comment", err)
    return
  end
  -- Reconcile rebuilds extmarks + popups idempotently; no need for a
  -- per-mutation attach/detach API.
  reconcile_buffer(bufnr)
  refresh_viewport(bufnr)
  emit("ManiculeAdded", record)
end

---Add a new comment, optionally tied to a range in the current buffer.
---@param opts {range?: table, body?: string, meta?: table}|nil
function M.add(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local range = resolve_range(opts)
  if opts.body and opts.body ~= "" then
    finalize_add(opts.body, bufnr, range)
    return
  end
  require("manicule.ui").prompt({ prompt = "Comment: " }, function(body)
    if body and body ~= "" then
      finalize_add(body, bufnr, range)
    end
  end)
end

---@param bufnr integer
---@param row integer
---@param col integer
---@return integer row, integer col
local function clamp_buffer_position(bufnr, row, col)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  row = math.max(0, math.min(row or 0, math.max(0, line_count - 1)))
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  col = math.max(0, math.min(col or 0, #line))
  return row, col
end

---@param bufnr integer
---@param record table
---@param mark_ids table<string, integer>
---@return table?
local function comment_position(bufnr, record, mark_ids)
  local id = tostring(record.id or "")
  local mark_id = mark_ids[id]
  if mark_id then
    local resolved = require("manicule.anchor").resolve(bufnr, mark_id)
    if resolved and resolved.invalid then
      return nil
    end
    if resolved and resolved.range and resolved.range.start then
      local row, col = clamp_buffer_position(bufnr, resolved.range.start[1], resolved.range.start[2] or 0)
      return { id = id, row = row, col = col, record = record }
    end
  end

  if record.range and record.range.start then
    local row, col = clamp_buffer_position(bufnr, record.range.start[1] or 0, record.range.start[2] or 0)
    return { id = id, row = row, col = col, record = record }
  end
  return nil
end

---@param bufnr integer
---@param records table[]
---@return table[]
local function comment_positions_for_buffer(bufnr, records)
  local render = require("manicule.ui.render")
  local mark_ids = render.mark_ids_for_buffer(bufnr)
  local positions = {}
  for _, record in ipairs(records or {}) do
    local pos = comment_position(bufnr, record, mark_ids)
    if pos then
      table.insert(positions, pos)
    end
  end
  table.sort(positions, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return a.id < b.id
  end)
  return positions
end

---@param count any
---@return integer
local function normalized_count(count)
  count = tonumber(count) or 1
  if count ~= count or count < 1 then
    return 1
  end
  return math.floor(count)
end

---Jump to the nearest next/previous comment in the current buffer.
---@param direction "next"|"prev"|"previous"
---@param opts? { count?: integer }
---@return boolean ok
function M.jump(direction, opts)
  opts = opts or {}
  local forward
  if direction == "next" then
    forward = true
  elseif direction == "prev" or direction == "previous" then
    forward = false
  else
    vim.notify(("manicule: unknown jump direction %q"):format(tostring(direction)), vim.log.levels.ERROR)
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  attach_buffer(bufnr)

  local records = records_for_buffer(bufnr)
  if #records == 0 then
    vim.notify("manicule: no comments in this buffer", vim.log.levels.WARN)
    return false
  end

  local positions = comment_positions_for_buffer(bufnr, records)
  if #positions == 0 then
    vim.notify("manicule: no jumpable comments in this buffer", vim.log.levels.WARN)
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cur_row, cur_col = cursor[1] - 1, cursor[2]
  local count = normalized_count(opts.count)
  local target

  if forward then
    for _, pos in ipairs(positions) do
      if pos.row > cur_row or (pos.row == cur_row and pos.col > cur_col) then
        target = pos
        count = count - 1
        if count == 0 then
          break
        end
      end
    end
  else
    for i = #positions, 1, -1 do
      local pos = positions[i]
      if pos.row < cur_row or (pos.row == cur_row and pos.col < cur_col) then
        target = pos
        count = count - 1
        if count == 0 then
          break
        end
      end
    end
  end

  if count > 0 or not target then
    vim.notify(("manicule: no %s comment"):format(forward and "next" or "previous"), vim.log.levels.WARN)
    return false
  end

  vim.api.nvim_win_set_cursor(0, { target.row + 1, target.col })
  pcall(vim.cmd, "normal! zv")
  refresh_viewport(bufnr)
  return true
end

---@param opts? { count?: integer }
---@return boolean
function M.next(opts)
  return M.jump("next", opts)
end

---@param opts? { count?: integer }
---@return boolean
function M.prev(opts)
  return M.jump("prev", opts)
end

---Find a record by id across both project + session scopes.
---Returns the record and a closure that persists any mutation back
---through the right store path.
---@param id string
---@param locator? { scope?: "project"|"session", project_root?: string }
---@return table? record, (fun())? save, (fun())? remove
local function find(id, locator)
  local store = require("manicule.store")
  locator = locator or {}

  local function find_project(root)
    if not root then
      return nil, nil, nil
    end
    local record = store.get(root, id)
    if record then
      local function save()
        store.put(root, record)
        return store.save(root)
      end
      local function remove()
        local removed = store.remove(root, id)
        local ok, err = store.save(root)
        return ok, err, removed
      end
      return record, save, remove
    end
    return nil, nil, nil
  end

  local function find_session()
    for _, r in ipairs(store.session_all()) do
      if r.id == id then
        local function save()
          store.session_put(r)
          return store.session_save()
        end
        local function remove()
          local removed = store.session_remove(id)
          local ok, err = store.session_save()
          return ok, err, removed
        end
        return r, save, remove
      end
    end
    return nil, nil, nil
  end

  if locator.scope == "session" then
    local record, save, remove = find_session()
    if record then
      return record, save, remove
    end
  elseif locator.project_root then
    local record, save, remove = find_project(locator.project_root)
    if record then
      return record, save, remove
    end
  end

  -- Lookups from `M.edit`/`M.delete`/`M.resolve` run against the
  -- project store that owns the *current* buffer. Route through the
  -- adapter-aware helper so an id coming off a staged buffer still
  -- finds the real project records.
  local root = current_project_root()
  if root then
    local record, save, remove = find_project(root)
    if record then
      return record, save, remove
    end
  end

  -- Quickfix and picker paths may carry a root, but fall back to every
  -- loaded project cache so ids remain actionable after the current window
  -- moved to a qf/help/scratch buffer. This does not load arbitrary store
  -- files from disk; it only searches roots already touched this session.
  for cached_root in pairs(store._cache()) do
    local record, save, remove = find_project(cached_root)
    if record then
      return record, save, remove
    end
  end

  -- Fall through to the session store.
  return find_session()
end

---Edit an existing comment by id.
---@param id string
---@param opts? { scope?: "project"|"session", project_root?: string }
function M.edit(id, opts)
  local record, save = find(id, opts)
  if not record or not save then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  require("manicule.ui").prompt({ prompt = "Edit: ", default = record.body }, function(body)
    if not body or body == "" then
      return
    end
    local before = vim.deepcopy(record)
    record.body = body
    record.updated_at = os.time()
    local ok, err = save()
    if not ok then
      replace_table_contents(record, before)
      notify_save_failed("edited comment", err)
      return
    end
    -- Rebuild popups for every buffer that currently renders this record.
    reconcile_all_loaded()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        refresh_viewport(bufnr)
      end
    end
    emit("ManiculeEdited", record)
  end)
end

---Delete a comment by id.
---@param id string
---@param opts? { scope?: "project"|"session", project_root?: string }
function M.delete(id, opts)
  local record, _, remove = find(id, opts)
  if not record or not remove then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  local snapshot = vim.deepcopy(record)
  local ok, err = remove()
  if not ok then
    require("manicule.store").put_record(snapshot)
    notify_save_failed("deleted comment", err)
    return
  end
  reconcile_all_loaded()
  refresh_all_loaded_viewports()
  emit("ManiculeDeleted", { id = id, record = record })
end

---Mark a comment as resolved.
---@param id string
---@param opts? { scope?: "project"|"session", project_root?: string }
function M.resolve(id, opts)
  local record, save = find(id, opts)
  if not record or not save then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  local before = vim.deepcopy(record)
  record.resolved = true
  record.updated_at = os.time()
  local ok, err = save()
  if not ok then
    replace_table_contents(record, before)
    notify_save_failed("resolved comment", err)
    return
  end
  emit("ManiculeResolved", record)
end

---Sort records by uri → start line → id so every surface that lists
---records (quickfix, picker, completion) sees the same order. Returning
---a sorted list from `list()` itself — rather than relying on callers
---to re-sort — is load-bearing for the picker: positional numbers from
---tab-completion must resolve to the same records the user sees in
---`:ManiculeList`.
---@param records table[]
---@return table[]
local function sort_records(records)
  local function start_line(r)
    if r and r.range and r.range.start then
      return (r.range.start[1] or 0) + 1
    end
    return 1
  end
  table.sort(records, function(a, b)
    local ap = tostring(a.uri or "")
    local bp = tostring(b.uri or "")
    if ap ~= bp then
      return ap < bp
    end
    local al = start_line(a)
    local bl = start_line(b)
    if al ~= bl then
      return al < bl
    end
    return tostring(a.id or "") < tostring(b.id or "")
  end)
  return records
end

---List comments, optionally filtered. Results are always sorted by
---`uri → start line → id` so the ordering seen in `:ManiculeList`,
---the picker, and the positional-number completer is identical.
---@param filter {uri?: string, path_suffix?: string, unresolved?: boolean, orphaned?: boolean, author?: string, _root?: string}|nil
---@return table[]
function M.list(filter)
  filter = filter or {}
  sync_all_loaded_positions()
  local store = require("manicule.store")
  local anchor = require("manicule.anchor")
  local render = require("manicule.ui.render")
  local uri_mod = require("manicule.uri")
  local bufnr = vim.api.nvim_get_current_buf()
  local mark_ids = render.mark_ids_for_buffer(bufnr)
  -- Walk both stores. The picker/quickfix is per-run-short-lived; the
  -- filter winnows and consumers can scope further. Keeps the scope
  -- transparent — no caller branches on `record.scope`.
  local all = {}
  -- Resolve the project root via the adapter so a staged buffer
  -- (DiffToolGit et al.) hits the real project store rather than
  -- walking up through `stdpath('run')` to a dead end — raw
  -- `store.root()` here returned nil and left M.list blind to every
  -- record saved via `adapter.identify`'s reverse-map.
  local root = filter._root or current_project_root()
  if root then
    for _, r in ipairs(store.all(root)) do
      table.insert(all, r)
    end
  end
  for _, r in ipairs(store.session_all()) do
    table.insert(all, r)
  end
  local results = vim
    .iter(all)
    :filter(function(r)
      if filter.uri and r.uri ~= filter.uri then
        return false
      end
      if filter.path_suffix then
        -- Case-sensitive suffix match. Prefer resolving URIs back to a
        -- filesystem path so callers can query with the natural
        -- project-relative suffix (`src/foo.lua`); fall back to the raw
        -- URI for non-file schemes so session-scope records still match.
        local candidate = uri_mod.to_path(r.uri) or tostring(r.uri or "")
        local suffix = filter.path_suffix
        if #candidate < #suffix or candidate:sub(-#suffix) ~= suffix then
          return false
        end
      end
      if filter.unresolved and r.resolved then
        return false
      end
      if filter.author and r.author ~= filter.author then
        return false
      end
      if filter.orphaned then
        local mid = mark_ids[tostring(r.id)]
        if not mid then
          return false
        end
        local resolved = anchor.resolve(bufnr, mid)
        if not resolved or not resolved.invalid then
          return false
        end
      end
      return true
    end)
    :totable()

  sort_records(results)

  -- If called as a command (no filter, no caller return-use), push to quickfix.
  if not filter._quiet and (filter.to_qflist or vim.tbl_count(filter) == 0) then
    -- Pass the filter through so the quickfix module can cache it for
    -- `refresh()` and regenerate the same list on `User Manicule*`.
    require("manicule.ui.quickfix").show(results, { open = true, filter = filter })
  end
  return results
end

---Dispatch filtered comments to a named sink.
---@param sink_name string|nil
---@param filter table|nil
---@param ctx table|nil
function M.send(sink_name, filter, ctx)
  if sink_name == nil or sink_name == "" then
    require("manicule.ui").select_sink(function(name)
      if name then
        M.send(name, filter, ctx)
      end
    end)
    return
  end
  filter = filter or {}
  filter._quiet = true
  local records = M.list(filter)
  -- Fetch the spec up front so we can check `clear_on_success` after
  -- dispatch without a second registry lookup. Unknown sinks still flow
  -- through `dispatch`'s existing `cb(false, "unknown sink")` path below
  -- (sink will be nil here, `sink.clear_on_success` never evaluates).
  local sinks = require("manicule.sinks")
  local sink = sinks.get(sink_name)
  sinks.dispatch(sink_name, records, ctx or {}, function(ok, err)
    -- Fire `ManiculeSent` BEFORE any auto-clear so subscribers see the
    -- send event ahead of the per-record `ManiculeDeleted` events — a
    -- causal "send happened, now the records are going away" order.
    emit("ManiculeSent", {
      sink = sink_name,
      count = #records,
      ok = ok,
      err = err,
    })
    if not ok then
      vim.notify(("manicule: sink %q failed: %s"):format(sink_name, tostring(err)), vim.log.levels.ERROR)
      return
    end
    if sink and sink.clear_on_success and #records > 0 then
      -- Reuse `M.delete` so each record goes through the full lifecycle
      -- — store.remove + save, render.reconcile per buffer, and one
      -- `User ManiculeDeleted` per record — exactly as if the user had
      -- deleted them by hand. `M.delete` is idempotent on unknown ids
      -- (emits a WARN notify and returns early), so a sink that already
      -- cleared records itself becomes a no-op here.
      for _, record in ipairs(records) do
        M.delete(record.id, { scope = record.scope, project_root = record.project_root })
      end
    end
  end)
end

---Register a sink adapter. Delegates to the sinks registry.
---@param spec {name: string, send: fun(comments: table, ctx: table, cb: fun(ok, err)), format?: fun(c): string, validate?: fun(ctx): boolean, string?}
function M.register_sink(spec)
  return require("manicule.sinks").register(spec)
end

-- Exposed for tests + <Plug> maps; not part of the stable public API.
-- Returns `{ [bufnr] = { [comment_id] = extmark_id, ... }, ... }` by
-- projecting from the render layer's handle table so there is exactly
-- one source of truth for anchor extmarks.
function M._buffer_marks()
  local render = require("manicule.ui.render")
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local marks = render.mark_ids_for_buffer(bufnr)
    if next(marks) then
      out[bufnr] = marks
    end
  end
  return out
end

function M._stop_sync_timer_for_tests()
  if sync_timer then
    sync_timer:stop()
    sync_timer:close()
    sync_timer = nil
  end
end

return M
