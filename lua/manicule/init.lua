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
--   ManiculeOrphaned  { id, record }
--   ManiculeRenamed   { bufnr, old_uri, new_uri, record_count }
--
-- Rendering is owned by `lua/manicule/ui/render.lua`. `init.lua`
-- resolves records for the affected buffer on every mutation and
-- delegates to `render.reconcile(bufnr, records)`, which is idempotent.

local M = {}

---@class manicule.Config
---@field store? table
---@field handlers? table
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

---Return records that belong to `bufnr` (URI equality) under `root`.
---@param bufnr integer
---@param root string|nil
---@return table[]
local function records_for_buffer(bufnr, root)
  if not root or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local store = require("manicule.store")
  local uri = require("manicule.uri").for_bufnr(bufnr)
  if not uri then
    return {}
  end
  return store.for_uri(root, uri)
end

---Run reconcile for every buffer that already has an entry in `buffer_to_path`
---or is loaded and visible. Returns the records passed in.
---@param bufnr integer
local function reconcile_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local store = require("manicule.store")
  local root = store.root()
  if not root then
    return
  end
  store.load(root)
  local records = records_for_buffer(bufnr, root)
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
  local store = require("manicule.store")
  local root = store.root()
  if not root then
    return
  end
  local render = require("manicule.ui.render")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local records = records_for_buffer(bufnr, root)
      render.reconcile(bufnr, records)
    end
  end
end

---Run the non-sticky viewport refresh for `bufnr`. Cheap enough to fire
---from scroll / resize / cursor-moved autocmds.
---@param bufnr integer
local function refresh_viewport(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local cfg = require("manicule.config").get()
  if (cfg.ui or {}).sticky then
    return
  end
  local store = require("manicule.store")
  local root = store.root()
  if not root then
    return
  end
  local records = records_for_buffer(bufnr, root)
  require("manicule.ui.render").update_viewport_popups(bufnr, records)
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
  local root = store.root()
  if not root then
    return
  end
  local new_uri = uri_mod.for_bufnr(bufnr)
  if not new_uri or not old_uri or old_uri == new_uri then
    return
  end
  local all = store.all(root)
  local ids = {}
  for _, record in ipairs(all) do
    if record.uri == old_uri then
      record.uri = new_uri
      table.insert(ids, record.id)
    end
  end
  if #ids == 0 then
    return
  end
  store.mark_dirty(root)
  store.save(root)
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

  -- Register built-in sinks unless the user opted out.
  local sinks_cfg = opts.sinks or {}
  if sinks_cfg.clipboard ~= false then
    local sinks = require("manicule.sinks")
    local clipboard = require("manicule.sinks.clipboard")
    sinks.register(clipboard.spec)
  end

  -- Initialize the render layer (highlights).
  require("manicule.ui.render").setup()

  -- Idempotent augroup: clear = true means a second setup() wins cleanly.
  local group = vim.api.nvim_create_augroup("manicule", { clear = true })
  local store = require("manicule.store")

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
      require("manicule.ui.render").hide_all_popups(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(ev)
      -- `vim.schedule` mirrors codediff's render path: avoid doing float
      -- reconfigure work from inside the autocmd, lets batched events
      -- coalesce into a single render.
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
    callback = function()
      local root = store.root()
      if root then
        store.save(root)
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
  local uri_mod = require("manicule.uri")

  local uri = uri_mod.for_bufnr(bufnr)
  if not uri then
    -- Buffer has no name (scratch, anonymous). Phase 3 will route these
    -- into the session-scoped store; for now, refuse rather than
    -- persist a URI-less record.
    vim.notify("manicule: buffer has no name — comment not saved.", vim.log.levels.WARN)
    return
  end

  local root = store.root()
  if not root then
    -- No project root resolved and the user hasn't opted in to
    -- `store.persist_unrooted`. Tell them instead of silently dropping
    -- the comment on the floor.
    -- TODO(manicule): phase 3 — route unrooted to session store
    vim.notify(
      "manicule: buffer is not in a project (scope='session' will handle this in phase 3)",
      vim.log.levels.WARN
    )
    return
  end

  local now = os.time()
  local record = {
    id = id_mod.new(),
    uri = uri,
    scope = "project",
    project_root = root,
    range = range,
    body = body,
    author = ui.git_email(),
    created_at = now,
    updated_at = now,
    resolved = false,
    meta = {},
  }
  store.put(root, record)
  store.save(root)
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

---Find the (root, record) pair for an id.
---@param id string
---@return string|nil root, table|nil record
local function find(id)
  local store = require("manicule.store")
  local root = store.root()
  if not root then
    return nil, nil
  end
  return root, store.get(root, id)
end

---Edit an existing comment by id.
---@param id string
function M.edit(id)
  local root, record = find(id)
  if not root or not record then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  require("manicule.ui").prompt({ prompt = "Edit: ", default = record.body }, function(body)
    if not body or body == "" then
      return
    end
    record.body = body
    record.updated_at = os.time()
    require("manicule.store").put(root, record)
    require("manicule.store").save(root)
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
function M.delete(id)
  local root, record = find(id)
  if not root or not record then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  require("manicule.store").remove(root, id)
  require("manicule.store").save(root)
  reconcile_all_loaded()
  emit("ManiculeDeleted", { id = id, record = record })
end

---Mark a comment as resolved.
---@param id string
function M.resolve(id)
  local root, record = find(id)
  if not root or not record then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  record.resolved = true
  record.updated_at = os.time()
  require("manicule.store").put(root, record)
  require("manicule.store").save(root)
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
---@param filter {uri?: string, path_suffix?: string, unresolved?: boolean, orphaned?: boolean, author?: string}|nil
---@return table[]
function M.list(filter)
  filter = filter or {}
  local store = require("manicule.store")
  local anchor = require("manicule.anchor")
  local render = require("manicule.ui.render")
  local uri_mod = require("manicule.uri")
  local root = store.root()
  if not root then
    return {}
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local mark_ids = render.mark_ids_for_buffer(bufnr)
  local all = store.all(root)
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
        -- URI for non-file schemes so phase 3 adapters still match.
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
---@param sink_name string
---@param filter table|nil
---@param ctx table|nil
function M.send(sink_name, filter, ctx)
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
        M.delete(record.id)
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

return M
