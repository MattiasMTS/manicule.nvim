-- manicule.nvim: review panel — an owned scratch-buffer bottom split.
--
-- Auto-opens on session start as a plain `manicule://panel` buffer
-- (filetype `manicule-panel`) in a full-width split below the diff, so
-- j/k/search/marks all behave like any normal buffer and the GLOBAL
-- quickfix list stays free for the user during reviews.
--
-- Two views share the window. Files view (default) renders one line
-- per pair — `<icon> [M] path  +12 −4  · N comments` — with a per-file
-- diffstat and live comment counts; the
-- OPEN pair's line is marked with a `▸ ` overlay, a full-line
-- `ManiculePanelCurrent` background, and a bold filename. <Tab>
-- toggles to the comments view (session-scoped records). In files
-- view, <CR> drills into a commented pair's comments (or opens the
-- pair when it has none); `o` always opens the pair. In a scoped
-- comments view, <Esc> returns to files and <Tab> widens to ALL
-- comments.
--
-- All rendering goes through one idempotent `render()` from
-- review.state() + the store: buffer lines plus extmarks in the
-- panel's namespaces, rebuilt wholesale on every refresh — except when
-- the rebuilt rows come out identical, where the write is skipped.
-- Per-row locators live in a module-local `line_data` table (files
-- view: the pair index; comments view: record id + uri + line), which
-- replaces the quickfix `user_data` the previous implementation rode
-- on.

local M = {}

local PANEL_BUFNAME = "manicule://panel"
local PANEL_FILETYPE = "manicule-panel"

-- Content extmarks (icon/status/count/resolved spans) and the
-- current-pair marks live in separate namespaces so a pair switch can
-- re-mark the current line without rebuilding — or re-listing — the
-- whole view.
local ns = vim.api.nvim_create_namespace("manicule.review.panel")
local ns_current = vim.api.nvim_create_namespace("manicule.review.panel.current")

---@type "files"|"comments"
local current_view = "files"

---URI scoping the comments view to a single file (set by drill-down
---from the files view); nil means ALL session comments.
---@type string|nil
local file_filter = nil

---@type integer|nil winid of the panel window
local panel_winid = nil

---@type integer|nil bufnr of the panel scratch buffer
local panel_bufnr = nil

---@type integer|nil autocmd group for live refresh + lifecycle
local augroup = nil

---Per-row locators for the CURRENT render, 1-indexed by buffer line.
---Files view rows carry `pair_index` (+ the byte span of the path for
---the bold current-file mark); comments view rows carry the record
---locator (`id`, `scope`, `project_root`) and jump target (`uri`,
---`line`).
---@type table[]
local line_data = {}

---Lines + view of the previous render. A refresh that rebuilds
---identical rows (event bursts, mutations on files outside the view)
---skips the buffer rewrite and extmark rebuild. Reset by `hide()` —
---the buffer is recreated on reopen, so nothing rendered survives.
---@type string[]|nil
local last_lines = nil
---@type "files"|"comments"|nil
local last_view = nil

---Coalesces `User Manicule*` bursts into ONE refresh: a consuming send
---emits ManiculeDeleted PER RECORD, and refreshing inline would run a
---full render per event. The first event of a synchronous burst
---schedules the refresh (same event-loop tick — no timer delay, no
---added latency); the rest find the flag set and no-op. Mirrors
---init.lua's `qf_refresh_pending`.
local refresh_pending = false

-- The session's project root, URI array/set, and uri -> pair-index map
-- all come pre-computed on review.state() (session cache built once in
-- review.start): list() resolves the store root from the CURRENT
-- buffer, and the panel's scratch buffer falls back to cwd — which can
-- miss the reviewed project entirely — so every list() call here
-- passes the cached root as `_root` and filters on the cached uri set.

---@param name string
---@return table
local function get_highlight(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then
    return hl
  end
  return {}
end

---Define the panel's highlight groups. The current-line surface is a
---ManiculeCardBg-style tint — Normal bg nudged 8% toward Normal fg via
---`render.blend` — recomputed here on every panel open and on
---ColorScheme (the panel augroup re-runs this; render.lua's own
---ColorScheme wiring only covers the card palette). Transparent themes
---(no Normal bg) have nothing to blend from and borrow CursorLine so
---the current pair still stands out. Status/count/resolved groups are
---`default` links, so user overrides win.
local function setup_highlights()
  local normal = get_highlight("Normal")
  if type(normal.bg) == "number" then
    local toward = type(normal.fg) == "number" and normal.fg or normal.bg
    local bg = require("manicule.ui.render").blend(normal.bg, toward, 0.08)
    vim.api.nvim_set_hl(0, "ManiculePanelCurrent", { bg = bg })
  else
    vim.api.nvim_set_hl(0, "ManiculePanelCurrent", { link = "CursorLine" })
  end
  -- Bold-only group: layered over the path span on the current line,
  -- it combines with (never covers) the line background above.
  vim.api.nvim_set_hl(0, "ManiculePanelCurrentFile", { bold = true })
  vim.api.nvim_set_hl(0, "ManiculePanelStatusA", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "ManiculePanelStatusD", { link = "DiagnosticError", default = true })
  -- M (and any other status) stays default text on purpose — most of a
  -- review is modifications, and coloring all of them is noise.
  vim.api.nvim_set_hl(0, "ManiculePanelAdded", { link = "Added", default = true })
  vim.api.nvim_set_hl(0, "ManiculePanelRemoved", { link = "Removed", default = true })
  vim.api.nvim_set_hl(0, "ManiculePanelCount", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ManiculePanelResolved", { link = "Comment", default = true })
end

---@class manicule.review.panel.Row
---@field text string rendered buffer line
---@field spans {[1]: integer, [2]: integer, [3]: string}[] byte-range highlights
---@field data table locator stored into `line_data`

---Files view rows: one per session pair, `<lead><icon> [S] path  +A −R
---· N comments`. The two-space lead reserves the current-pair marker
---column (`▸ ` overlays it on the open pair) so columns never shift.
---@return manicule.review.panel.Row[]
local function build_file_rows()
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return {}
  end

  local counts = {}
  -- `_no_sync`: the panel is a read-only surface rendering right after
  -- a mutation, whose path already synced extmark positions — skip the
  -- editor-wide position sweep on every render (all three list() call
  -- sites here pass it).
  local records = require("manicule").list({ _quiet = true, _no_sync = true, uris = state.uri_set, _root = state.root })
  for _, record in ipairs(records) do
    counts[record.uri] = (counts[record.uri] or 0) + 1
  end

  local icons = require("manicule.ui.icons")
  local with_icons = icons.enabled()
  -- Per-pair {added, removed} counts, computed once per session on the
  -- first render and cached on the session (see review.diffstat) —
  -- deliberately NOT refreshed when the worktree side changes mid-review.
  local diffstat = review.diffstat() or {}

  local rows = {}
  for idx, pair in ipairs(state.files) do
    local parts = { "  " }
    local spans = {}
    local col = 2
    if with_icons then
      -- One glyph + one space (a blank cell when the provider yields
      -- nothing) keeps the column aligned; the provider's highlight
      -- group rides along as an extmark — the old quickfix substrate
      -- could carry the glyph but never its color.
      local icon, icon_hl = icons.file_icon(pair.path)
      local glyph = icon or " "
      parts[#parts + 1] = glyph .. " "
      if icon and icon_hl then
        spans[#spans + 1] = { col, col + #glyph, icon_hl }
      end
      col = col + #glyph + 1
    end
    local status = ("[%s]"):format(pair.status)
    local status_hl = pair.status == "A" and "ManiculePanelStatusA"
      or pair.status == "D" and "ManiculePanelStatusD"
      or nil
    parts[#parts + 1] = status .. " "
    if status_hl then
      spans[#spans + 1] = { col, col + #status, status_hl }
    end
    col = col + #status + 1
    local path_start = col
    parts[#parts + 1] = pair.path
    col = col + #pair.path
    -- `+A −R` between path and comment count, zero components omitted
    -- (A/D pairs naturally show one side). An all-zero stat renders
    -- nothing, keeping unchanged/unreadable pairs at the old row shape.
    local stat = diffstat[idx]
    if stat and (stat.added > 0 or stat.removed > 0) then
      parts[#parts + 1] = "  "
      col = col + 2
      if stat.added > 0 then
        local added = ("+%d"):format(stat.added)
        parts[#parts + 1] = added
        spans[#spans + 1] = { col, col + #added, "ManiculePanelAdded" }
        col = col + #added
        if stat.removed > 0 then
          parts[#parts + 1] = " "
          col = col + 1
        end
      end
      if stat.removed > 0 then
        local removed = ("\u{2212}%d"):format(stat.removed)
        parts[#parts + 1] = removed
        spans[#spans + 1] = { col, col + #removed, "ManiculePanelRemoved" }
        col = col + #removed
      end
    end
    local count = ("  \u{00B7} %d comments"):format(counts[state.uris[idx]] or 0)
    parts[#parts + 1] = count
    spans[#spans + 1] = { col, col + #count, "ManiculePanelCount" }
    rows[#rows + 1] = {
      text = table.concat(parts),
      spans = spans,
      data = { pair_index = idx, path_start = path_start, path_end = path_start + #pair.path },
    }
  end
  return rows
end

---Comments view rows, one per record in canonical `uri → line → id`
---order: `[✓ ][x] path:lnum  first body line`. Resolved records keep
---the existing conventions — `[x]` for locally-resolved, a `✓` prefix
---for GitHub-resolved threads (meta.github.resolved, toggled via `gr`)
---— and both render dimmed.
---@param records? table[] pre-fetched records for the CURRENT filter
---(uri-scoped when `file_filter` is set); fetched here when nil.
---@return manicule.review.panel.Row[]
local function build_comment_rows(records)
  local state = require("manicule.review").state()
  if not records then
    local uris = file_filter and { [file_filter] = true } or (state and state.uri_set or {})
    records =
      require("manicule").list({ _quiet = true, _no_sync = true, uris = uris, _root = state and state.root or nil })
  end
  local range = require("manicule.range")
  local str = require("manicule.str")

  -- `manicule.list()` already returns a fresh array sorted by
  -- `range.compare` — the canonical order — so the records are used
  -- as-is.
  local rows = {}
  for _, record in ipairs(records) do
    local meta = type(record.meta) == "table" and record.meta or nil
    local gh = meta and type(meta.github) == "table" and meta.github or nil
    local gh_resolved = gh ~= nil and gh.resolved == true

    -- Display path: the session pair's relative path when the record
    -- maps to one (uri -> pair index straight off the session cache),
    -- else the file's tail.
    local label
    local pair_index = state and state.uri_index and state.uri_index[record.uri] or nil
    if pair_index and state.files[pair_index] then
      label = state.files[pair_index].path
    else
      local path = require("manicule.uri").to_path(record.uri)
      label = path and vim.fn.fnamemodify(path, ":t") or record.uri
    end

    local sl = range.start_line(record)
    local el = range.end_line(record)
    local loc = (el and el > sl) and ("%s:%d-%d"):format(label, sl, el) or ("%s:%d"):format(label, sl)
    local marker = record.resolved and "[x]" or "[ ]"
    local first = vim.split(record.body or "", "\n", { plain = true })[1] or ""
    local prefix = gh_resolved and "\u{2713} " or ""
    local text = ("%s%s %s  %s"):format(prefix, marker, loc, str.truncate(first, 160))
    local spans = {}
    if gh_resolved or record.resolved then
      spans[#spans + 1] = { 0, #text, "ManiculePanelResolved" }
    end
    rows[#rows + 1] = {
      text = text,
      spans = spans,
      data = {
        id = record.id,
        scope = record.scope,
        project_root = record.project_root,
        uri = record.uri,
        line = sl,
      },
    }
  end
  return rows
end

---Mark the OPEN pair's row (files view only): a `▸ ` overlay on the
---lead column, a full-line `ManiculePanelCurrent` background, and a
---bold filename. Lives in its own namespace so a pair switch re-marks
---without a re-render (and without re-querying the store).
local function apply_current_marks()
  if not (panel_bufnr and vim.api.nvim_buf_is_valid(panel_bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(panel_bufnr, ns_current, 0, -1)
  if current_view ~= "files" then
    return
  end
  local state = require("manicule.review").state()
  local index = state and state.index
  local data = index and line_data[index]
  if not data or data.pair_index ~= index then
    return
  end
  local row = index - 1
  pcall(vim.api.nvim_buf_set_extmark, panel_bufnr, ns_current, row, 0, {
    line_hl_group = "ManiculePanelCurrent",
    virt_text = { { "\u{25B8} ", "ManiculePanelCurrent" } },
    virt_text_pos = "overlay",
  })
  pcall(vim.api.nvim_buf_set_extmark, panel_bufnr, ns_current, row, data.path_start, {
    end_col = data.path_end,
    hl_group = "ManiculePanelCurrentFile",
  })
end

---Rebuild the panel buffer from state: lines, content extmarks, and
---`line_data`, then the current-pair marks. Idempotent; never moves
---the cursor or focus.
---@param comment_records? table[] pre-fetched records for a comments
---view render (see build_comment_rows); ignored in files view.
local function render(comment_records)
  if not (panel_bufnr and vim.api.nvim_buf_is_valid(panel_bufnr)) then
    return
  end
  local rows
  if current_view == "files" then
    rows = build_file_rows()
  else
    rows = build_comment_rows(comment_records)
  end

  local lines = {}
  line_data = {}
  for i, row in ipairs(rows) do
    lines[i] = row.text
    line_data[i] = row.data
  end

  -- Same view, identical lines: the content extmark spans derive from
  -- the row text, so only the current-pair marks can differ — re-apply
  -- those and skip the buffer rewrite + extmark rebuild.
  if last_view == current_view and vim.deep_equal(last_lines, lines) then
    apply_current_marks()
    return
  end
  last_view = current_view
  last_lines = lines

  vim.bo[panel_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(panel_bufnr, 0, -1, false, lines)
  vim.bo[panel_bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(panel_bufnr, ns, 0, -1)
  for i, row in ipairs(rows) do
    for _, span in ipairs(row.spans) do
      pcall(vim.api.nvim_buf_set_extmark, panel_bufnr, ns, i - 1, span[1], {
        end_col = span[2],
        hl_group = span[3],
      })
    end
  end
  apply_current_marks()
end

---Re-render the current view, preserving the panel cursor position
---(clamped to the new line count) across the rebuild.
---@param comment_records? table[] see build_comment_rows
local function refresh(comment_records)
  if not (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return
  end
  local saved = vim.api.nvim_win_get_cursor(panel_winid)
  render(comment_records)
  local max_row = math.max(1, #line_data)
  pcall(vim.api.nvim_win_set_cursor, panel_winid, { math.min(saved[1], max_row), saved[2] })
end

---Locator under the cursor. Keymaps are buffer-local to the panel, so
---the cursor row indexes straight into the current render's line_data.
---@return table|nil
local function data_at_cursor()
  return line_data[vim.api.nvim_win_get_cursor(0)[1]]
end

---Pair index under the cursor (files view).
---@return integer|nil
local function pair_index_at_cursor()
  local data = data_at_cursor()
  if type(data) == "table" and type(data.pair_index) == "number" then
    return data.pair_index
  end
  return nil
end

---Comment locator (uri + line) under the cursor (comments view).
---@return {uri: string, line: integer}|nil
local function comment_at_cursor()
  local data = data_at_cursor()
  if type(data) == "table" and type(data.uri) == "string" and data.uri ~= "" then
    return { uri = data.uri, line = tonumber(data.line) or 1 }
  end
  return nil
end

---Record locator (id + scope + project root) under the cursor
---(comments view).
---@return {id: string, scope?: string, project_root?: string}|nil
local function record_locator_at_cursor()
  local data = data_at_cursor()
  if type(data) == "table" and type(data.id) == "string" and data.id ~= "" then
    return { id = data.id, scope = data.scope, project_root = data.project_root }
  end
  return nil
end

---Jump to the comment under the cursor in a comments view: resolve its
---uri to the owning session pair, rebuild that pair's diff via
---review.open, then put the cursor on the comment's line in the
---commentable window (right side; the single left window for D pairs).
---The panel stays open; focus moves to the jump target.
local function jump_to_comment()
  local comment = comment_at_cursor()
  if not comment then
    return
  end
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return
  end
  local pair_index = state.uri_index[comment.uri]
  if not pair_index then
    vim.notify("manicule: comment does not match any file in this review", vim.log.levels.WARN)
    return
  end
  review.open(pair_index)
  -- review.open leaves focus in the commentable window (right side;
  -- the left buffer for D pairs).
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local line = math.min(math.max(comment.line, 1), vim.api.nvim_buf_line_count(bufnr))
  pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
end

---Feed `lhs` back through as an unmapped key — the fallthrough for
---maps that only act in one view.
---@param lhs string
local function feed_default(lhs)
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
end

local function setup_panel_keymaps(bufnr)
  local map_opts = { buffer = bufnr, nowait = true, silent = true }
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("keep", { desc = desc }, map_opts))
  end

  -- <CR> in files view drills into the pair's comments when it has
  -- any, otherwise opens the pair. In comments view it jumps to the
  -- comment through review.open (never a raw window jump, which could
  -- stomp a diff window's buffer).
  map("<CR>", function()
    if current_view == "files" then
      local idx = pair_index_at_cursor()
      if not idx then
        return
      end
      local state = require("manicule.review").state()
      local pair = state and state.files[idx]
      if pair then
        local uri = state.uris[idx]
        local records =
          require("manicule").list({ _quiet = true, _no_sync = true, uris = { [uri] = true }, _root = state.root })
        if #records > 0 then
          current_view = "comments"
          file_filter = uri
          -- The drill-down check above already fetched exactly the
          -- records this scoped view shows; render them instead of
          -- re-listing.
          refresh(records)
          return
        end
      end
      require("manicule.review").open(idx)
    else
      jump_to_comment()
    end
  end, "Manicule review: drill into comments or open pair")

  -- `o` in files view always opens the pair — the escape hatch when
  -- <CR> would drill into comments instead.
  map("o", function()
    if current_view ~= "files" then
      feed_default("o")
      return
    end
    local idx = pair_index_at_cursor()
    if idx then
      require("manicule.review").open(idx)
    end
  end, "Manicule review: open pair (skip drill-down)")

  -- `r` in comments view replies to an imported GitHub comment: opens
  -- the comment editor; the reply posts to the comment's thread on the
  -- next github send. Falls through to the default `r` elsewhere.
  map("r", function()
    if current_view ~= "comments" then
      feed_default("r")
      return
    end
    local locator = record_locator_at_cursor()
    if locator then
      require("manicule.review.github").reply(locator)
    end
  end, "Manicule review: reply to imported GitHub comment")

  -- `gr` in comments view toggles GitHub thread resolution for an
  -- imported comment. Falls through to the default `gr` elsewhere.
  map("gr", function()
    if current_view ~= "comments" then
      feed_default("gr")
      return
    end
    local locator = record_locator_at_cursor()
    if locator then
      require("manicule.review.github").toggle_resolve(locator)
    end
  end, "Manicule review: toggle GitHub thread resolution")

  -- <Esc> in a comments view returns to files (clearing any file
  -- filter); in files view it falls through to the default behavior.
  map("<Esc>", function()
    if current_view == "comments" then
      current_view = "files"
      file_filter = nil
      refresh()
    else
      feed_default("<Esc>")
    end
  end, "Manicule review: back to files view")

  -- <Tab> toggles files <-> ALL comments. From a drilled-down (scoped)
  -- comments view it first widens to all comments.
  map("<Tab>", function()
    if current_view == "files" then
      current_view = "comments"
      file_filter = nil
    elseif file_filter then
      file_filter = nil
    else
      current_view = "files"
    end
    refresh()
  end, "Manicule review: toggle files/comments view")

  -- Comment mutations, previously inherited from the quickfix keymap
  -- module: same keys, same opt-out flag, but the locator now comes
  -- from line_data instead of qf user_data. No-ops on file rows.
  if vim.g.manicule_no_default_keymaps == 1 then
    return
  end

  map("dd", function()
    local locator = record_locator_at_cursor()
    if locator then
      require("manicule").delete(locator.id, locator)
    end
  end, "Manicule review: delete comment under cursor")

  map("ce", function()
    local locator = record_locator_at_cursor()
    if locator then
      require("manicule").edit(locator.id, locator)
    end
  end, "Manicule review: edit comment under cursor")

  map("u", function()
    require("manicule").undo_delete()
  end, "Manicule review: undo last comment deletion")

  map("<C-r>", function()
    require("manicule").redo_delete()
  end, "Manicule review: redo last undone deletion")
end

---Close the panel window and drop its augroup + buffer state, KEEPING
---the view/filter state so a later reopen (toggle) restores the panel
---exactly where it was. Idempotent — safe when the window is already
---gone (e.g. called from its own WinClosed).
local function hide()
  local win = panel_winid
  local buf = panel_bufnr
  panel_winid = nil
  panel_bufnr = nil
  line_data = {}
  last_lines = nil
  last_view = nil
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  -- `bufhidden = wipe` wipes the buffer with its window; a buffer that
  -- never reached a window (open failure) still needs explicit deletion.
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---Create the panel buffer + window for the CURRENT view state and arm
---the live-refresh/lifecycle augroup. `enter = false` — opening never
---steals focus, so there is nothing to restore afterwards.
local function open_window()
  setup_highlights()

  -- A stale buffer holding the panel's name (e.g. left from an aborted
  -- open) would make `nvim_buf_set_name` fail with E95 — drop it.
  local stale = vim.fn.bufnr(PANEL_BUFNAME)
  if stale ~= -1 then
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  pcall(vim.api.nvim_buf_set_name, bufnr, PANEL_BUFNAME)
  vim.bo[bufnr].filetype = PANEL_FILETYPE

  local state = require("manicule.review").state()
  local height = math.min(12, (state and #state.files or 1) + 2)

  -- `split = "below"` + `win = -1` opens a full-width top-level split
  -- at the bottom of the tab (the `:botright split` shape), under both
  -- diff windows.
  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
    split = "below",
    win = -1,
    height = height,
  })
  if not ok or not winid or not vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end

  vim.wo[winid].winfixheight = true
  vim.wo[winid].cursorline = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].wrap = false
  vim.wo[winid].list = false
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].spell = false

  panel_winid = winid
  panel_bufnr = bufnr
  setup_panel_keymaps(bufnr)
  render()

  augroup = vim.api.nvim_create_augroup("ManiculeReviewPanel", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = { "ManiculeAdded", "ManiculeDeleted", "ManiculeEdited", "ManiculeResolved", "ManiculeRestored" },
    callback = function()
      -- Refresh both views: files for live counts, comments so dd/ce/u
      -- in a (scoped) comments view update the list in place. The
      -- pending flag coalesces a synchronous event burst (a consuming
      -- send fires one ManiculeDeleted per record) into ONE scheduled
      -- refresh.
      if refresh_pending then
        return
      end
      refresh_pending = true
      vim.schedule(function()
        refresh_pending = false
        refresh()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = setup_highlights,
  })
  -- The user can close the panel window directly (:q, <C-w>c): tear
  -- down like a toggle-hide so no autocmd outlives the window. The
  -- window is still in the layout inside a WinClosed callback, hence
  -- the deferred validation.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(winid),
    callback = function()
      vim.schedule(function()
        if panel_winid == winid and not vim.api.nvim_win_is_valid(winid) then
          hide()
        end
      end)
    end,
  })
end

---Point the panel's files view at the given pair: re-mark the current
---line and move the panel window's cursor to that row, WITHOUT
---re-rendering, re-querying the store, or stealing focus. No-op when
---the panel is hidden, showing a comments view (including a
---drill-down), or there is no session.
---@param pair_index integer
function M.sync_index(pair_index)
  if current_view ~= "files" then
    return
  end
  if not require("manicule.review").state() then
    return
  end
  if not (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return
  end
  apply_current_marks()
  local max_row = math.max(1, #line_data)
  pcall(vim.api.nvim_win_set_cursor, panel_winid, { math.min(pair_index, max_row), 0 })
end

---Open the panel (files view) for the active session. Re-renders in
---place when the window already exists. No-op without a session.
function M.open()
  if not require("manicule.review").state() then
    return
  end
  -- Always start in files view
  current_view = "files"
  file_filter = nil
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    render()
    return
  end
  hide() -- clear any half-dead window/buffer state before recreating
  open_window()
end

---Show/hide the panel window without ending the session. Hiding drops
---the window, buffer, and autocmds; view and file-filter state survive
---so a second toggle reopens the panel exactly where it was. No-op
---without an active session.
---@return boolean toggled false when there is no session
function M.toggle()
  if not require("manicule.review").state() then
    return false
  end
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    hide()
    return true
  end
  open_window()
  return true
end

---Close the panel and reset ALL module state (view included) — the
---session-stop teardown. Idempotent.
function M.close()
  hide()
  current_view = "files"
  file_filter = nil
end

---True when the panel window is open.
---@return boolean
function M.is_open()
  return panel_winid ~= nil and vim.api.nvim_win_is_valid(panel_winid)
end

---The panel window id, or nil when closed. For tests/introspection.
---@return integer?
function M.winid()
  return panel_winid
end

---The panel buffer number, or nil when closed. For tests/introspection.
---@return integer?
function M.bufnr()
  return panel_bufnr
end

return M
