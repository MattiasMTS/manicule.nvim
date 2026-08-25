-- manicule.nvim: review panel with files and comments views.
--
-- Auto-opens a bottom quickfix window on session start, showing the
-- review's file pairs with live comment counts. <Tab> toggles between
-- files view (default) and comments view (session-scoped manicule list).
-- In files view, <CR> drills into a commented pair's comments (or opens
-- the pair when it has none); `o` always opens the pair. In a scoped
-- comments view, <Esc> returns to files and <Tab> widens to ALL comments.

local M = {}

---@type "files"|"comments"
local current_view = "files"

---URI scoping the comments view to a single file (set by drill-down
---from the files view); nil means ALL session comments.
---@type string|nil
local file_filter = nil

---@type integer|nil winid of the panel qf window
local panel_winid = nil

---@type integer|nil autocmd group for the panel's live refresh
local augroup = nil

-- The session's project root, URI array/set, and uri -> pair-index map
-- all come pre-computed on review.state() (session cache built once in
-- review.start): list() resolves the store root from the CURRENT
-- buffer, and the panel's unnamed quickfix buffer falls back to cwd —
-- which can miss the reviewed project entirely — so every list() call
-- here passes the cached root as `_root` and filters on the cached
-- uri set.

local function build_files_items()
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return {}
  end

  local counts = {}
  local records = require("manicule").list({ _quiet = true, uris = state.uri_set, _root = state.root })
  for _, record in ipairs(records) do
    counts[record.uri] = (counts[record.uri] or 0) + 1
  end

  local icons = require("manicule.ui.icons")
  local with_icons = icons.enabled()

  local items = {}
  for idx, pair in ipairs(state.files) do
    local text = ("[%s] %s  (%d comments)"):format(pair.status, pair.path, counts[state.uris[idx]] or 0)
    if with_icons then
      -- Quickfix item text is plain — the provider's highlight group
      -- can't ride along per item without rebuilding the panel's
      -- rendering, so the glyph goes in uncolored. One glyph + one
      -- space (a blank cell when the provider yields nothing) keeps
      -- the column aligned.
      text = (icons.file_icon(pair.path) or " ") .. " " .. text
    end
    table.insert(items, {
      filename = review.pair_path(pair),
      lnum = 1,
      text = text,
      -- Store index for <CR> mapping
      user_data = { pair_index = idx },
    })
  end
  return items
end

---@param records? table[] pre-fetched records for the CURRENT filter
---(uri-scoped when `file_filter` is set); fetched here when nil.
local function build_comments_items(records)
  if not records then
    local state = require("manicule.review").state()
    local uris = file_filter and { [file_filter] = true } or (state and state.uri_set or {})
    records = require("manicule").list({ _quiet = true, uris = uris, _root = state and state.root or nil })
  end
  local items = require("manicule.ui.quickfix").build_items(records)
  -- Carry each record's uri + line in user_data (mirroring the files
  -- view's user_data.pair_index) so the panel's <CR> can map a comment
  -- back to its session pair instead of doing a default qf jump.
  local by_id = {}
  for _, record in ipairs(records) do
    by_id[record.id] = record
  end
  local range = require("manicule.range")
  for _, item in ipairs(items) do
    local record = type(item.user_data) == "table" and by_id[item.user_data.id] or nil
    if record then
      item.user_data.uri = record.uri
      item.user_data.line = range.start_line(record)
      -- Mark GitHub-resolved threads (meta.github.resolved, toggled via
      -- `gr`) — distinct from the record's own `resolved` flag.
      local meta = type(record.meta) == "table" and record.meta or nil
      local gh = meta and type(meta.github) == "table" and meta.github or nil
      if gh and gh.resolved == true then
        item.text = "\u{2713} " .. item.text
      end
    end
  end
  return items
end

---Quickfix item under the cursor in the CURRENT (panel) window. Reads
---the list displayed in THIS window, not the global current stack
---entry, so qf history can't desync row -> item. The three projections
---below pull their locators out of the item's user_data.
---@return table|nil item
local function item_at_cursor()
  local winid = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(winid)[1]
  local ok, info = pcall(vim.fn.getqflist, { winid = winid, items = 1 })
  if not ok or type(info) ~= "table" or type(info.items) ~= "table" then
    return nil
  end
  return info.items[row]
end

---Pair index under the cursor (files view).
---@return integer|nil
local function pair_index_at_cursor()
  local item = item_at_cursor()
  local data = item and item.user_data
  if type(data) == "table" and type(data.pair_index) == "number" then
    return data.pair_index
  end
  return nil
end

---Comment locator (uri + line) under the cursor (comments view).
---@return {uri: string, line: integer}|nil
local function comment_at_cursor()
  local item = item_at_cursor()
  local data = item and item.user_data
  if type(data) == "table" and type(data.uri) == "string" and data.uri ~= "" then
    return { uri = data.uri, line = tonumber(data.line) or item.lnum or 1 }
  end
  return nil
end

---Record locator (id + scope + project root) under the cursor
---(comments view).
---@return {id: string, scope?: string, project_root?: string}|nil
local function record_locator_at_cursor()
  local item = item_at_cursor()
  local data = item and item.user_data
  if type(data) == "table" and type(data.id) == "string" and data.id ~= "" then
    return { id = data.id, scope = data.scope, project_root = data.project_root }
  end
  return nil
end

---Jump to the comment under the cursor in a comments view: resolve its
---uri to the owning session pair, rebuild that pair's diff via
---review.open (never the default qf jump, which picks its own target
---window and can stomp a diff window's buffer), then put the cursor on
---the comment's line in the commentable window (right side; the single
---left window for D pairs). The panel stays open; focus moves to the
---jump target.
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
  -- uri -> pair index straight off the session cache; the linear
  -- pair_uri scan here used to cost an fs_realpath per pair per jump.
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

local function get_panel_title()
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return "manicule-review"
  end
  return ("manicule-review (%s)"):format(state.label)
end

local function is_panel_qf(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if vim.bo[bufnr].buftype ~= "quickfix" then
    return false
  end
  local wininfo = vim.fn.getwininfo(winid)[1]
  if not wininfo or wininfo.loclist ~= 0 then
    return false
  end
  local ok, info = pcall(vim.fn.getqflist, { winid = winid, title = 1 })
  if ok and type(info) == "table" and type(info.title) == "string" then
    return info.title:match("^manicule%-review") ~= nil
  end
  return false
end

local function find_panel_window()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_panel_qf(winid) then
      return winid
    end
  end
  return nil
end

---Resolve the id of the list DISPLAYED in the panel window, so reads
---and in-place replaces target the panel's list even when qf history
---or another plugin moved the global current stack entry elsewhere.
---@param winid integer
---@return integer id 0 when unresolvable (falls back to current list)
local function panel_list_id(winid)
  local ok, info = pcall(vim.fn.getqflist, { winid = winid, id = 0 })
  if ok and type(info) == "table" and type(info.id) == "number" then
    return info.id
  end
  return 0
end

---@param comment_records? table[] pre-fetched records for a comments
---view refresh (see build_comments_items); ignored in files view.
local function refresh_current_view(comment_records)
  local winid = find_panel_window()
  if not winid then
    return
  end
  local saved_row = vim.api.nvim_win_get_cursor(winid)[1]
  local items
  if current_view == "files" then
    items = build_files_items()
  else
    items = build_comments_items(comment_records)
  end
  local what = { id = panel_list_id(winid), title = get_panel_title(), items = items }
  if current_view == "files" then
    -- Rebuilding resets the list's current entry; restore it to the
    -- open pair so the panel keeps indicating what is on screen.
    local state = require("manicule.review").state()
    if state and state.index and state.index <= #items then
      what.idx = state.index
    end
  end
  vim.fn.setqflist({}, "r", what)
  -- Restore cursor, clamped
  if vim.api.nvim_win_is_valid(winid) then
    local max_row = math.max(1, #items)
    local target = math.min(saved_row, max_row)
    if #items > 0 then
      pcall(vim.api.nvim_win_set_cursor, winid, { target, 0 })
    end
  end
end

local function setup_panel_keymaps(bufnr)
  local map_opts = { buffer = bufnr, nowait = true, silent = true }

  -- <CR> in files view drills into the pair's comments when it has
  -- any, otherwise opens the pair.
  vim.keymap.set("n", "<CR>", function()
    if current_view == "files" then
      local idx = pair_index_at_cursor()
      if not idx then
        return
      end
      local state = require("manicule.review").state()
      local pair = state and state.files[idx]
      if pair then
        local uri = state.uris[idx]
        local records = require("manicule").list({ _quiet = true, uris = { [uri] = true }, _root = state.root })
        if #records > 0 then
          current_view = "comments"
          file_filter = uri
          -- The drill-down check above already fetched exactly the
          -- records this scoped view shows; render them instead of
          -- re-listing.
          refresh_current_view(records)
          return
        end
      end
      require("manicule.review").open(idx)
    else
      -- Comments view: never the default qf jump — it picks its own
      -- target window (possibly a diff window) and breaks the layout.
      jump_to_comment()
    end
  end, vim.tbl_extend("keep", { desc = "Manicule review: drill into comments or open pair" }, map_opts))

  -- `o` in files view always opens the pair — the escape hatch when
  -- <CR> would drill into comments instead.
  vim.keymap.set("n", "o", function()
    if current_view ~= "files" then
      local o = vim.api.nvim_replace_termcodes("o", true, false, true)
      vim.api.nvim_feedkeys(o, "n", false)
      return
    end
    local idx = pair_index_at_cursor()
    if idx then
      require("manicule.review").open(idx)
    end
  end, vim.tbl_extend("keep", { desc = "Manicule review: open pair (skip drill-down)" }, map_opts))

  -- `r` in comments view replies to an imported GitHub comment: opens
  -- the comment editor; the reply posts to the comment's thread on the
  -- next github send. Falls through to the default `r` elsewhere.
  vim.keymap.set("n", "r", function()
    if current_view ~= "comments" then
      local r = vim.api.nvim_replace_termcodes("r", true, false, true)
      vim.api.nvim_feedkeys(r, "n", false)
      return
    end
    local locator = record_locator_at_cursor()
    if locator then
      require("manicule.review.github").reply(locator)
    end
  end, vim.tbl_extend("keep", { desc = "Manicule review: reply to imported GitHub comment" }, map_opts))

  -- `gr` in comments view toggles GitHub thread resolution for an
  -- imported comment. Falls through to the default `gr` elsewhere.
  vim.keymap.set("n", "gr", function()
    if current_view ~= "comments" then
      local gr = vim.api.nvim_replace_termcodes("gr", true, false, true)
      vim.api.nvim_feedkeys(gr, "n", false)
      return
    end
    local locator = record_locator_at_cursor()
    if locator then
      require("manicule.review.github").toggle_resolve(locator)
    end
  end, vim.tbl_extend("keep", { desc = "Manicule review: toggle GitHub thread resolution" }, map_opts))

  -- <Esc> in a comments view returns to files (clearing any file
  -- filter); in files view it falls through to the default behavior.
  vim.keymap.set("n", "<Esc>", function()
    if current_view == "comments" then
      current_view = "files"
      file_filter = nil
      refresh_current_view()
    else
      local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
      vim.api.nvim_feedkeys(esc, "n", false)
    end
  end, vim.tbl_extend("keep", { desc = "Manicule review: back to files view" }, map_opts))

  -- <Tab> toggles files <-> ALL comments. From a drilled-down (scoped)
  -- comments view it first widens to all comments.
  vim.keymap.set("n", "<Tab>", function()
    if current_view == "files" then
      current_view = "comments"
      file_filter = nil
    elseif file_filter then
      file_filter = nil
    else
      current_view = "files"
    end
    refresh_current_view()
  end, vim.tbl_extend("keep", { desc = "Manicule review: toggle files/comments view" }, map_opts))

  -- Preserve existing manicule quickfix keymaps in comments view
  require("manicule.ui.quickfix_keymaps").attach(bufnr)
end

---Create the panel window for the CURRENT view state: push a fresh qf
---list, open it bottom, wire keymaps, refocus the diff, and (re)arm the
---live-refresh autocmds. Shared by open() and toggle() reopen.
local function open_window()
  local items
  if current_view == "files" then
    items = build_files_items()
  else
    items = build_comments_items()
  end
  local title = get_panel_title()

  vim.fn.setqflist({}, " ", { title = title, items = items })

  -- Open panel bottom, height = min(#files + 1, 8)
  local height = math.min(#items + 1, 8)
  vim.cmd(("botright %d copen"):format(height))

  -- copen focuses the window it opened: bind the panel to it. Never
  -- scan for buftype == "quickfix" — location-list windows share that
  -- buftype, so a loclist open in the tab could be captured instead.
  local qf_winid = vim.api.nvim_get_current_win()
  if not is_panel_qf(qf_winid) then
    qf_winid = find_panel_window()
  end
  if qf_winid then
    panel_winid = qf_winid
    setup_panel_keymaps(vim.api.nvim_win_get_buf(qf_winid))
  end

  -- Return focus to diff (right-side window)
  -- Find the first non-qf window in the tab
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local win_bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[win_bufnr].buftype ~= "quickfix" then
      vim.api.nvim_set_current_win(winid)
      break
    end
  end

  -- Setup live refresh on comment events (only when in files view)
  augroup = vim.api.nvim_create_augroup("ManiculeReviewPanel", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = { "ManiculeAdded", "ManiculeDeleted", "ManiculeEdited", "ManiculeResolved" },
    callback = function()
      -- Refresh both views: files for live counts, comments so dd/ce
      -- in a (scoped) comments view update the list in place.
      if find_panel_window() then
        refresh_current_view()
      end
    end,
  })
end

---Point the panel's files view at the given pair: set the quickfix
---list's current-entry index and move the panel window's cursor to
---that row, WITHOUT stealing focus from the current window. No-op
---when the panel is hidden, showing a comments view (including a
---drill-down), or there is no session.
---@param pair_index integer
function M.sync_index(pair_index)
  if current_view ~= "files" then
    return
  end
  if not require("manicule.review").state() then
    return
  end
  local winid = find_panel_window()
  if not winid then
    return
  end
  pcall(vim.fn.setqflist, {}, "a", { id = panel_list_id(winid), idx = pair_index })
  pcall(vim.api.nvim_win_set_cursor, winid, { pair_index, 0 })
end

function M.open()
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return
  end

  -- Always start in files view
  current_view = "files"
  file_filter = nil
  open_window()
end

---Show/hide the panel window without ending the session. Hiding closes
---ONLY the window; view and file-filter state survive so a second
---toggle reopens the panel exactly where it was. Autocmds are dropped
---on hide and re-armed on reopen (no leaks, no refreshes of a window
---that is gone). No-op without an active session.
---@return boolean toggled false when there is no session
function M.toggle()
  if not require("manicule.review").state() then
    return false
  end
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    pcall(vim.api.nvim_win_close, panel_winid, true)
    panel_winid = nil
    if augroup then
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
      augroup = nil
    end
    return true
  end
  open_window()
  return true
end

function M.close()
  -- Close panel window if it exists
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    pcall(vim.api.nvim_win_close, panel_winid, true)
  end
  -- Clean up autocmds
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  -- Reset module state
  panel_winid = nil
  augroup = nil
  current_view = "files"
  file_filter = nil
end

return M
