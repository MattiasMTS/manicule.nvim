-- manicule.nvim: review panel — an owned scratch-buffer window.
--
-- Auto-opens on session start as a plain `manicule://panel` buffer
-- (filetype `manicule-panel`), so j/k/search/marks all behave like any
-- normal buffer and the GLOBAL quickfix list stays free for the user
-- during reviews. Placement comes from `review.panel.position`: a
-- full-width "bottom" split (default), a full-height "left"/"right"
-- column, or a centered "float" (which takes focus; `q` closes it).
--
-- Three views share the window, cycled by <Tab> (files → tree →
-- comments → files). Files view (default) renders one line per pair —
-- `<icon> [M] path  +12 −4  · N comments` — with a per-file diffstat
-- and live comment counts; the OPEN pair's line is marked with a `▸ `
-- overlay, a full-line `ManiculePanelCurrent` background, and a bold
-- filename; VIEWED pairs (`v`, or auto-marked by next/prev) get a `✓ `
-- lead and dim, and the window's winbar counts progress (`3/12
-- viewed`). Tree view groups the same pairs by directory (Pierre
-- style): `▾/▸` directory rows carry rolled-up diffstat/comment counts
-- and a viewed indicator (`✓` all viewed, `●` otherwise), nest by two
-- spaces per level with single-child chains collapsed into one row,
-- and toggle collapse with <CR>/za (`v` marks the subtree viewed);
-- file rows keep the files-view shape with basename labels. In files
-- view, <CR> drills into a commented pair's comments (or opens the
-- pair when it has none); `o` always opens the pair; in tree view <CR>
-- on a file row simply opens it. In a scoped comments view, <Esc>
-- returns to files and <Tab> widens to ALL comments; <Esc> returns to
-- files from every non-files view.
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

---@type "files"|"tree"|"comments"
local current_view = "files"

---URI scoping the comments view to a single file (set by drill-down
---from the files view); nil means ALL session comments.
---@type string|nil
local file_filter = nil

---Collapsed directory rows in the tree view, keyed by the directory
---node's full path. Session-scoped: survives refreshes and toggle
---hide/reopen, reset by close() (session stop).
---@type table<string, true>
local collapsed = {}

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
---@type "files"|"tree"|"comments"|nil
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
  vim.api.nvim_set_hl(0, "ManiculePanelViewed", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ManiculePanelDir", { link = "Directory", default = true })
end

---@class manicule.review.panel.Row
---@field text string rendered buffer line
---@field spans {[1]: integer, [2]: integer, [3]: string}[] byte-range highlights
---@field data table locator stored into `line_data`

---Spans for a VIEWED row: keep the diffstat (+/−) spans colored —
---Pierre keeps them visible — and dim everything around them with
---`ManiculePanelViewed` segments (which replace the icon/status/count
---spans, so no two foreground marks compete on the same bytes).
---@param spans {[1]: integer, [2]: integer, [3]: string}[] built left-to-right
---@param text_len integer row byte length
---@return {[1]: integer, [2]: integer, [3]: string}[]
local function viewed_spans(spans, text_len)
  local out = {}
  local pos = 0
  for _, span in ipairs(spans) do
    if span[3] == "ManiculePanelAdded" or span[3] == "ManiculePanelRemoved" then
      if span[1] > pos then
        out[#out + 1] = { pos, span[1], "ManiculePanelViewed" }
      end
      out[#out + 1] = span
      pos = span[2]
    end
  end
  if pos < text_len then
    out[#out + 1] = { pos, text_len, "ManiculePanelViewed" }
  end
  return out
end

---Shared per-render inputs for pair/dir rows: live comment counts (ONE
---list() call per render), icon availability, the cached session
---diffstat, and viewed marks. nil without a session.
---@return table|nil
local function pair_row_ctx()
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return nil
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
  return {
    state = state,
    counts = counts,
    icons = icons,
    with_icons = icons.enabled(),
    -- Per-pair {added, removed} counts, computed once per session on the
    -- first render and cached on the session (see review.diffstat) —
    -- deliberately NOT refreshed when the worktree side changes mid-review.
    diffstat = review.diffstat() or {},
    viewed = state.viewed or {},
  }
end

---Append the `  +A −R` diffstat segment, zero components omitted (A/D
---pairs naturally show one side; an all-zero stat renders nothing).
---@param parts string[]
---@param spans {[1]: integer, [2]: integer, [3]: string}[]
---@param col integer current row byte length
---@param added integer
---@param removed integer
---@return integer col after the segment
local function append_stat(parts, spans, col, added, removed)
  if added <= 0 and removed <= 0 then
    return col
  end
  parts[#parts + 1] = "  "
  col = col + 2
  if added > 0 then
    local text = ("+%d"):format(added)
    parts[#parts + 1] = text
    spans[#spans + 1] = { col, col + #text, "ManiculePanelAdded" }
    col = col + #text
    if removed > 0 then
      parts[#parts + 1] = " "
      col = col + 1
    end
  end
  if removed > 0 then
    local text = ("\u{2212}%d"):format(removed)
    parts[#parts + 1] = text
    spans[#spans + 1] = { col, col + #text, "ManiculePanelRemoved" }
    col = col + #text
  end
  return col
end

---Append the dim `  · N comments` tail.
---@return integer col after the segment
local function append_count(parts, spans, col, count)
  local text = ("  \u{00B7} %d comments"):format(count)
  parts[#parts + 1] = text
  spans[#spans + 1] = { col, col + #text, "ManiculePanelCount" }
  return col + #text
end

---One pair row: `<indent><lead><icon> [S] label  +A −R  · N comments`.
---The files view renders the full pair path with no indent; the tree
---view indents by nesting depth and labels with the basename. The
---two-cell lead reserves the current-pair marker column (`▸ ` overlays
---it on the open pair) so columns never shift; viewed pairs render a
---`✓ ` lead (same two cells) and dim.
---@param idx integer pair index
---@param label string rendered path text
---@param indent string leading spaces ("" in files view)
---@param ctx table from pair_row_ctx
---@return manicule.review.panel.Row
local function pair_row(idx, label, indent, ctx)
  local pair = ctx.state.files[idx]
  local is_viewed = ctx.viewed[idx] == true
  local lead = is_viewed and "\u{2713} " or "  "
  local parts = { indent, lead }
  local spans = {}
  local col = #indent + #lead
  if ctx.with_icons then
    -- One glyph + one space (a blank cell when the provider yields
    -- nothing) keeps the column aligned; the provider's highlight
    -- group rides along as an extmark — the old quickfix substrate
    -- could carry the glyph but never its color.
    local icon, icon_hl = ctx.icons.file_icon(pair.path)
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
  parts[#parts + 1] = label
  col = col + #label
  local stat = ctx.diffstat[idx] or {}
  col = append_stat(parts, spans, col, stat.added or 0, stat.removed or 0)
  append_count(parts, spans, col, ctx.counts[ctx.state.uris[idx]] or 0)
  local text = table.concat(parts)
  if is_viewed then
    spans = viewed_spans(spans, #text)
  end
  return {
    text = text,
    spans = spans,
    data = {
      kind = "file",
      pair_index = idx,
      path_start = path_start,
      path_end = path_start + #label,
      lead_col = #indent,
    },
  }
end

---Files view rows: one per session pair, full path, no indent.
---@return manicule.review.panel.Row[]
local function build_file_rows()
  local ctx = pair_row_ctx()
  if not ctx then
    return {}
  end
  local rows = {}
  for idx, pair in ipairs(ctx.state.files) do
    rows[#rows + 1] = pair_row(idx, pair.path, "", ctx)
  end
  return rows
end

---@class manicule.review.panel.DirNode
---@field name string row label; single-child chains collapse into "a/b"
---@field path string full directory path — the collapse-state key
---@field dirs manicule.review.panel.DirNode[] child dirs, first-seen order
---@field files integer[] pair indexes directly in this directory

---Group the session pairs by directory (pair.path split on "/").
---Chains of single-child directories holding no files of their own
---collapse into one node ("lua" → "manicule" renders as one
---`lua/manicule` row) — Pierre does this to keep trees shallow.
---@param files {path: string}[]
---@return manicule.review.panel.DirNode root
local function build_tree(files)
  local root = { name = "", path = "", dirs = {}, files = {} }
  local by_path = {}
  for idx, pair in ipairs(files) do
    local node = root
    local parts = vim.split(pair.path, "/", { plain = true })
    for i = 1, #parts - 1 do
      local path = node.path == "" and parts[i] or (node.path .. "/" .. parts[i])
      local child = by_path[path]
      if not child then
        child = { name = parts[i], path = path, dirs = {}, files = {} }
        by_path[path] = child
        node.dirs[#node.dirs + 1] = child
      end
      node = child
    end
    node.files[#node.files + 1] = idx
  end
  local function collapse_chains(node)
    for _, child in ipairs(node.dirs) do
      while #child.dirs == 1 and #child.files == 0 do
        local only = child.dirs[1]
        child.name = child.name .. "/" .. only.name
        child.path = only.path
        child.dirs = only.dirs
        child.files = only.files
      end
      collapse_chains(child)
    end
  end
  collapse_chains(root)
  return root
end

---Recursive subtree totals for one directory node: summed diffstat,
---summed comment counts, and whether EVERY file inside is viewed.
---@return integer added, integer removed, integer comments, boolean all_viewed
local function dir_rollup(node, ctx)
  local added, removed, comments = 0, 0, 0
  local all_viewed = true
  for _, idx in ipairs(node.files) do
    local stat = ctx.diffstat[idx]
    if stat then
      added = added + stat.added
      removed = removed + stat.removed
    end
    comments = comments + (ctx.counts[ctx.state.uris[idx]] or 0)
    if not ctx.viewed[idx] then
      all_viewed = false
    end
  end
  for _, child in ipairs(node.dirs) do
    local a, r, c, v = dir_rollup(child, ctx)
    added, removed, comments = added + a, removed + r, comments + c
    if not v then
      all_viewed = false
    end
  end
  return added, removed, comments, all_viewed
end

---One directory row: `<indent>▾ name  +A −R  · N comments  ●` with a
---`▸` disclosure when collapsed and a `✓` indicator once every file in
---the subtree is viewed.
---@return manicule.review.panel.Row
local function dir_row(node, depth, is_collapsed, ctx)
  local added, removed, comments, all_viewed = dir_rollup(node, ctx)
  local indent = ("  "):rep(depth)
  local glyph = is_collapsed and "\u{25B8}" or "\u{25BE}"
  local parts = { indent, glyph, " ", node.name }
  local col = #indent + #glyph + 1 + #node.name
  local spans = { { #indent, col, "ManiculePanelDir" } }
  col = append_stat(parts, spans, col, added, removed)
  col = append_count(parts, spans, col, comments)
  local mark = all_viewed and "\u{2713}" or "\u{25CF}"
  parts[#parts + 1] = "  " .. mark
  spans[#spans + 1] = { col + 2, col + 2 + #mark, "ManiculePanelViewed" }
  return {
    text = table.concat(parts),
    spans = spans,
    data = { kind = "dir", dir = node.path },
  }
end

---Tree view rows: the node's own files first (basename labels), then
---its child directories, depth-first, skipping the subtrees of
---collapsed directories (their rows still show the full rollup).
local function append_tree_rows(node, depth, rows, ctx)
  local indent = ("  "):rep(depth)
  for _, idx in ipairs(node.files) do
    local path = ctx.state.files[idx].path
    rows[#rows + 1] = pair_row(idx, path:match("[^/]+$") or path, indent, ctx)
  end
  for _, child in ipairs(node.dirs) do
    local is_collapsed = collapsed[child.path] == true
    rows[#rows + 1] = dir_row(child, depth, is_collapsed, ctx)
    if not is_collapsed then
      append_tree_rows(child, depth + 1, rows, ctx)
    end
  end
end

---@return manicule.review.panel.Row[]
local function build_tree_rows()
  local ctx = pair_row_ctx()
  if not ctx then
    return {}
  end
  local rows = {}
  append_tree_rows(build_tree(ctx.state.files), 0, rows, ctx)
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
        kind = "comment",
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

---1-indexed panel row rendering the given pair, or nil when the row is
---not on screen (tree view: hidden inside a collapsed directory). In
---files view the row number equals the pair index; the scan keeps one
---code path for both pair-row views.
---@param pair_index integer
---@return integer|nil
local function pair_row_number(pair_index)
  for row, data in ipairs(line_data) do
    if data.pair_index == pair_index then
      return row
    end
  end
  return nil
end

---Mark the OPEN pair's row (files and tree views): a `▸ ` overlay on
---the row's lead column, a full-line `ManiculePanelCurrent` background,
---and a bold filename. Lives in its own namespace so a pair switch
---re-marks without a re-render (and without re-querying the store).
---No row is marked when the pair is hidden in a collapsed directory.
local function apply_current_marks()
  if not (panel_bufnr and vim.api.nvim_buf_is_valid(panel_bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(panel_bufnr, ns_current, 0, -1)
  if current_view == "comments" then
    return
  end
  local state = require("manicule.review").state()
  local index = state and state.index
  local row = index and pair_row_number(index)
  if not row then
    return
  end
  local data = line_data[row]
  pcall(vim.api.nvim_buf_set_extmark, panel_bufnr, ns_current, row - 1, data.lead_col or 0, {
    line_hl_group = "ManiculePanelCurrent",
    virt_text = { { "\u{25B8} ", "ManiculePanelCurrent" } },
    virt_text_pos = "overlay",
  })
  pcall(vim.api.nvim_buf_set_extmark, panel_bufnr, ns_current, row - 1, data.path_start, {
    end_col = data.path_end,
    hl_group = "ManiculePanelCurrentFile",
  })
end

---Viewed progress (`3/12 viewed`) in the panel window's winbar — the
---panel has no other title surface, and a winbar is native and cheap.
---Plain text (no `%` items), so no escaping is needed.
local function update_winbar()
  if not (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return
  end
  local state = require("manicule.review").state()
  if not state then
    return
  end
  local viewed = 0
  for _ in pairs(state.viewed or {}) do
    viewed = viewed + 1
  end
  local progress = ("%d/%d viewed"):format(viewed, #state.files)
  if current_view == "tree" then
    -- The tree view names itself: its rows can look identical to the
    -- files view for a flat session.
    progress = progress .. " \u{00B7} tree"
  end
  vim.wo[panel_winid].winbar = progress
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
  update_winbar()
  local rows
  if current_view == "files" then
    rows = build_file_rows()
  elseif current_view == "tree" then
    rows = build_tree_rows()
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

---Flip one tree directory row between collapsed and expanded.
---@param dir_path string
local function toggle_dir(dir_path)
  if collapsed[dir_path] then
    collapsed[dir_path] = nil
  else
    collapsed[dir_path] = true
  end
  refresh()
end

---Pair indexes living under a directory row's subtree. Prefix-matching
---pair.path covers collapsed-chain nodes ("lua/manicule") without
---re-walking the tree.
---@param dir_path string
---@param state manicule.ReviewSession
---@return integer[]
local function subtree_pair_indexes(dir_path, state)
  local prefix = dir_path .. "/"
  local out = {}
  for idx, pair in ipairs(state.files) do
    if pair.path:sub(1, #prefix) == prefix then
      out[#out + 1] = idx
    end
  end
  return out
end

---Expand every collapsed ancestor directory of the given pair so its
---tree row becomes visible. Returns true when any state changed (the
---caller re-renders). Clearing a prefix that is not a rendered node
---(chain-collapse swallows intermediates) is harmless.
---@param pair_index integer
---@return boolean changed
local function expand_to(pair_index)
  local state = require("manicule.review").state()
  local pair = state and state.files[pair_index]
  if not pair then
    return false
  end
  local changed = false
  local prefix
  local parts = vim.split(pair.path, "/", { plain = true })
  for i = 1, #parts - 1 do
    prefix = prefix and (prefix .. "/" .. parts[i]) or parts[i]
    if collapsed[prefix] then
      collapsed[prefix] = nil
      changed = true
    end
  end
  return changed
end

local function setup_panel_keymaps(bufnr)
  local map_opts = { buffer = bufnr, nowait = true, silent = true }
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("keep", { desc = desc }, map_opts))
  end

  -- <CR> in files view drills into the pair's comments when it has
  -- any, otherwise opens the pair. In tree view it toggles a directory
  -- row's collapse and plainly opens a file row's pair (the tree keeps
  -- no drill-down — <Tab> reaches the comments view directly). In
  -- comments view it jumps to the comment through review.open (never a
  -- raw window jump, which could stomp a diff window's buffer).
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
    elseif current_view == "tree" then
      local data = data_at_cursor()
      if type(data) ~= "table" then
        return
      end
      if data.kind == "dir" then
        toggle_dir(data.dir)
      elseif data.pair_index then
        require("manicule.review").open(data.pair_index)
      end
    else
      jump_to_comment()
    end
  end, "Manicule review: drill into comments, toggle directory, or open pair")

  -- `o` on any pair row (files or tree view) always opens the pair —
  -- the escape hatch when <CR> would drill into comments instead.
  map("o", function()
    if current_view == "comments" then
      feed_default("o")
      return
    end
    local idx = pair_index_at_cursor()
    if idx then
      require("manicule.review").open(idx)
    end
  end, "Manicule review: open pair (skip drill-down)")

  -- `za` mirrors <CR> on tree directory rows — the native fold-toggle
  -- key. Falls through to the default `za` everywhere else.
  map("za", function()
    local data = current_view == "tree" and data_at_cursor() or nil
    if type(data) == "table" and data.kind == "dir" then
      toggle_dir(data.dir)
    else
      feed_default("za")
    end
  end, "Manicule review: toggle directory collapse")

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

  -- <Esc> in any non-files view returns to files (clearing any file
  -- filter); in files view it falls through to the default behavior.
  map("<Esc>", function()
    if current_view ~= "files" then
      current_view = "files"
      file_filter = nil
      refresh()
    else
      feed_default("<Esc>")
    end
  end, "Manicule review: back to files view")

  -- `v` toggles viewed state (next/prev also auto-mark the pair they
  -- leave; `v` is the manual toggle/un-mark): a pair row toggles that
  -- pair; a tree directory row toggles its whole subtree — any unviewed
  -- file marks everything viewed, an all-viewed subtree un-marks. Falls
  -- through to the default `v` (visual mode) in comments view.
  map("v", function()
    if current_view == "comments" then
      feed_default("v")
      return
    end
    local data = data_at_cursor()
    if type(data) ~= "table" then
      return
    end
    local review = require("manicule.review")
    local state = review.state()
    if not state then
      return
    end
    if data.kind == "dir" then
      local indexes = subtree_pair_indexes(data.dir, state)
      local target = false
      for _, idx in ipairs(indexes) do
        if not state.viewed[idx] then
          target = true
          break
        end
      end
      for _, idx in ipairs(indexes) do
        review.set_viewed(idx, target)
      end
    elseif data.pair_index then
      review.set_viewed(data.pair_index, not state.viewed[data.pair_index])
    end
  end, "Manicule review: toggle viewed for the file or directory under cursor")

  -- <Tab> cycles the views: files → tree → comments → files. From a
  -- drilled-down (scoped) comments view it first widens to ALL comments.
  map("<Tab>", function()
    if current_view == "files" then
      current_view = "tree"
    elseif current_view == "tree" then
      current_view = "comments"
      file_filter = nil
    elseif file_filter then
      file_filter = nil
    else
      current_view = "files"
    end
    refresh()
  end, "Manicule review: cycle files/tree/comments view")

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

---The configured panel placement: position plus optional size override.
---@return {position: "bottom"|"left"|"right"|"float", size?: integer}
local function panel_config()
  local review_cfg = require("manicule.config").get().review or {}
  local cfg = type(review_cfg.panel) == "table" and review_cfg.panel or {}
  return { position = cfg.position or "bottom", size = cfg.size }
end

---Window config for one placement. Splits mirror the shapes already in
---the codebase: "bottom" is the `:botright split` full-width strip,
---"left"/"right" the rail's full-height side column (`win = -1`, so
---"right" places OUTERMOST and coexists with the comments rail).
---"float" is a centered editor-relative window.
---@param position string
---@param size integer|nil
---@param file_count integer
---@return table win_opts, boolean enter
local function placement_win_opts(position, size, file_count)
  if position == "float" then
    local width = math.floor(vim.o.columns * 0.6)
    local height = math.floor(vim.o.lines * 0.4)
    return {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      border = "rounded",
      focusable = true,
    },
      true -- modal-ish: the float takes focus on open
  end
  if position == "left" or position == "right" then
    -- Same clamp as the comments rail: 30% of the screen in [30, 46].
    local width = size or math.min(46, math.max(30, math.floor(vim.o.columns * 0.3)))
    return { split = position, win = -1, width = width }, false
  end
  return { split = "below", win = -1, height = size or math.min(12, file_count + 2) }, false
end

---Create the panel buffer + window for the CURRENT view state and arm
---the live-refresh/lifecycle augroup. Splits open with `enter = false`
---(never steal focus); the float is modal-ish and takes focus, with a
---float-only `q` map that closes it (toggle-hide — the session lives).
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
  local cfg = panel_config()
  local win_opts, enter = placement_win_opts(cfg.position, cfg.size, state and #state.files or 1)

  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, enter, win_opts)
  if not ok or not winid or not vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end

  if cfg.position == "bottom" then
    vim.wo[winid].winfixheight = true
  elseif cfg.position == "left" or cfg.position == "right" then
    vim.wo[winid].winfixwidth = true
  end
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
  -- Float only: `q` closes the panel like a toggle (the session lives;
  -- reopen with :ManiculeToggle). <Esc> keeps its view-back meaning in
  -- every position, so the comments-view drill-down works unchanged.
  if cfg.position == "float" then
    vim.keymap.set("n", "q", hide, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Manicule review: close the floating panel",
    })
  end
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

---Point the panel's files or tree view at the given pair: re-mark the
---current line and move the panel window's cursor to that row, WITHOUT
---re-querying the store or stealing focus. The tree view auto-expands
---collapsed ancestors first — Pierre keeps the active file visible —
---and only that expansion re-renders. No-op when the panel is hidden,
---showing a comments view (including a drill-down), or there is no
---session.
---@param pair_index integer
function M.sync_index(pair_index)
  if current_view == "comments" then
    return
  end
  if not require("manicule.review").state() then
    return
  end
  if not (panel_winid and vim.api.nvim_win_is_valid(panel_winid)) then
    return
  end
  if current_view == "tree" and expand_to(pair_index) then
    render()
  end
  apply_current_marks()
  local row = pair_row_number(pair_index)
  if row then
    pcall(vim.api.nvim_win_set_cursor, panel_winid, { row, 0 })
  end
end

---Re-render the current view in place, preserving the panel cursor.
---For review-state changes that bypass the store-event path (viewed
---toggles). No-op while the panel is hidden.
function M.refresh()
  refresh()
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

---Close the panel and reset ALL module state (view and tree collapse
---state included) — the session-stop teardown. Idempotent.
function M.close()
  hide()
  current_view = "files"
  file_filter = nil
  collapsed = {}
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
