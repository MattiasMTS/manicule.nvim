-- manicule.nvim: review panel with files and comments views.
--
-- Auto-opens a bottom quickfix window on session start, showing the
-- review's file pairs with live comment counts. <Tab> toggles between
-- files view (default) and comments view (session-scoped manicule list).
-- In files view, <CR> calls review.open(idx) instead of default qf jump.

local M = {}

---@type "files"|"comments"
local current_view = "files"

---@type integer|nil winid of the panel qf window
local panel_winid = nil

---@type integer|nil autocmd group for the panel's live refresh
local augroup = nil

local function session_uris()
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return {}
  end
  local uri_mod = require("manicule.uri")
  local uris = {}
  for _, pair in ipairs(state.files) do
    local path = pair.status == "D" and pair.left or pair.right
    uris[uri_mod.for_path(path)] = true
  end
  return uris
end

local function build_files_items()
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return {}
  end

  local uri_mod = require("manicule.uri")
  local pair_uris = {}
  local session_uri_set = {}
  for idx, pair in ipairs(state.files) do
    local path = pair.status == "D" and pair.left or pair.right
    local uri = uri_mod.for_path(path)
    pair_uris[idx] = uri
    session_uri_set[uri] = true
  end

  local counts = {}
  local records = require("manicule").list({ _quiet = true, uris = session_uri_set })
  for _, record in ipairs(records) do
    counts[record.uri] = (counts[record.uri] or 0) + 1
  end

  local items = {}
  for idx, pair in ipairs(state.files) do
    table.insert(items, {
      filename = pair.status == "D" and pair.left or pair.right,
      lnum = 1,
      text = ("[%s] %s  (%d comments)"):format(pair.status, pair.path, counts[pair_uris[idx]] or 0),
      -- Store index for <CR> mapping
      user_data = { pair_index = idx },
    })
  end
  return items
end

local function build_comments_items()
  local records = require("manicule").list({ _quiet = true, uris = session_uris() })
  return require("manicule.ui.quickfix").build_items(records)
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

local function refresh_current_view()
  local winid = find_panel_window()
  if not winid then
    return
  end
  local saved_row = vim.api.nvim_win_get_cursor(winid)[1]
  local items
  if current_view == "files" then
    items = build_files_items()
  else
    items = build_comments_items()
  end
  vim.fn.setqflist({}, "r", { id = panel_list_id(winid), title = get_panel_title(), items = items })
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

  -- <CR> in files view calls review.open(idx)
  vim.keymap.set("n", "<CR>", function()
    if current_view == "files" then
      local winid = vim.api.nvim_get_current_win()
      local row = vim.api.nvim_win_get_cursor(winid)[1]
      -- Read the list displayed in THIS window, not the global current
      -- stack entry, so qf history can't desync row -> pair mapping.
      local ok, info = pcall(vim.fn.getqflist, { winid = winid, items = 1 })
      if not ok or type(info) ~= "table" or type(info.items) ~= "table" then
        return
      end
      local item = info.items[row]
      if not item then
        return
      end
      local data = item.user_data
      if type(data) == "table" and type(data.pair_index) == "number" then
        require("manicule.review").open(data.pair_index)
      end
    else
      -- Comments view: default (unmapped) qf <CR> jumps to the entry.
      local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
      vim.api.nvim_feedkeys(cr, "n", false)
    end
  end, vim.tbl_extend("keep", { desc = "Manicule review: open pair or jump to comment" }, map_opts))

  -- <Tab> toggles views
  vim.keymap.set("n", "<Tab>", function()
    if current_view == "files" then
      current_view = "comments"
    else
      current_view = "files"
    end
    refresh_current_view()
  end, vim.tbl_extend("keep", { desc = "Manicule review: toggle files/comments view" }, map_opts))

  -- Preserve existing manicule quickfix keymaps in comments view
  require("manicule.ui.quickfix_keymaps").attach(bufnr)
end

function M.open()
  local review = require("manicule.review")
  local state = review.state()
  if not state then
    return
  end

  -- Always start in files view
  current_view = "files"
  local items = build_files_items()
  local title = get_panel_title()

  vim.fn.setqflist({}, " ", { title = title, items = items })

  -- Open panel bottom, height = min(#files + 1, 8)
  local height = math.min(#items + 1, 8)
  vim.cmd(("botright %d copen"):format(height))

  -- Find and setup the qf window that was just opened
  local qf_winid = nil
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].buftype == "quickfix" then
      qf_winid = winid
      setup_panel_keymaps(bufnr)
      panel_winid = winid
      break
    end
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
      if current_view == "files" and find_panel_window() then
        refresh_current_view()
      end
    end,
  })
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
end

return M
