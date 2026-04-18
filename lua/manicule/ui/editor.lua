-- manicule.nvim: floating-window comment editor.
--
-- Ported from codediff.nvim's `ui/comments/editor.lua`. Buffer-agnostic:
-- codediff anchored the editor to a diff pane, manicule just anchors it
-- to the cursor in the current window. Only one editor is live at a
-- time — opening a second one closes the first.
--
-- Submit/cancel keys, initial mode, size, and winblend all come from
-- `manicule.config.get().ui` (see `config.lua`).

local M = {}

---@class manicule.ui.editor.Active
---@field id string
---@field winid integer
---@field bufnr integer
---@field close fun()

---@type manicule.ui.editor.Active?
local active_editor = nil

---@param text string?
---@return string[]
local function split_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

---@param key string
---@return string
local function key_label(key)
  local labels = {
    ["<CR>"] = "enter",
    ["<S-CR>"] = "shift+enter",
    ["<S-Enter>"] = "shift+enter",
    ["<S-Return>"] = "shift+enter",
    ["<C-CR>"] = "ctrl+enter",
    ["<C-g>"] = "ctrl+g",
    ["<Esc>"] = "esc",
  }
  if labels[key] then
    return labels[key]
  end
  if type(key) == "string" and key:match("^<.+>$") then
    return key:sub(2, -2):lower()
  end
  return tostring(key)
end

---@param cfg manicule.UIConfig
---@param anchor_winid integer
---@return { width: integer, height: integer }
local function get_editor_layout(cfg, anchor_winid)
  return {
    width = math.min(cfg.width, math.max(1, vim.api.nvim_win_get_width(anchor_winid) - 2)),
    height = math.min(cfg.height, math.max(1, vim.api.nvim_win_get_height(anchor_winid) - 2)),
  }
end

local function force_normal_mode()
  pcall(vim.cmd, "stopinsert")
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) == "i" then
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "n", false)
  end
end

---@param opts? { filetype?: string }
---@return integer bufnr
local function create_scratch_buf(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  if opts.filetype then
    vim.bo[bufnr].filetype = opts.filetype
  end
  return bufnr
end

---@param winid integer
---@param winhighlight string
local function set_float_win_options(winid, winhighlight)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].cursorline = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].winhighlight = winhighlight
end

---@param border any
---@return boolean
local function border_is_none(border)
  if border == nil then
    return false
  end
  if type(border) == "string" then
    return border == "" or border:lower() == "none"
  end
  return false
end

---@param win_config table
---@param border any
---@param title string?
---@param footer string?
local function apply_title_footer(win_config, border, title, footer)
  if border_is_none(border) then
    return
  end
  if vim.fn.has("nvim-0.9") ~= 1 then
    return
  end
  if title then
    win_config.title = title
    win_config.title_pos = "left"
  end
  if footer and vim.fn.has("nvim-0.10") == 1 then
    win_config.footer = footer
    win_config.footer_pos = "left"
  end
end

---@param bufnr integer
---@param submit_keys string[]
---@param cancel_keys string[]
---@param submit_comment fun()
---@param close_editor fun()
local function apply_editor_keymaps(bufnr, submit_keys, cancel_keys, submit_comment, close_editor)
  local seen = {}
  local function map_key(mode, key, cb, group)
    local map_id = string.format("%s:%s:%s", group, mode, key)
    if seen[map_id] then
      return
    end
    seen[map_id] = true
    vim.keymap.set(mode, key, cb, {
      buffer = bufnr,
      noremap = true,
      silent = true,
      nowait = true,
    })
  end
  for _, key in ipairs(submit_keys) do
    if type(key) == "string" and key ~= "" then
      map_key("n", key, submit_comment, "submit")
    end
  end
  for _, key in ipairs(cancel_keys) do
    if type(key) == "string" and key ~= "" then
      map_key("n", key, close_editor, "cancel")
    end
  end
end

---@param bufnr integer
---@return string
local function read_editor_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

---@param winid integer
---@param text string?
local function move_cursor_to_end(winid, text)
  local lines = split_lines(text)
  local target_line = math.max(1, #lines)
  local target_text = lines[target_line] or ""
  local target_col = #target_text
  pcall(vim.api.nvim_win_set_cursor, winid, { target_line, target_col })
end

---Setup default highlight groups (idempotent).
local function ensure_highlights()
  vim.api.nvim_set_hl(0, "ManiculeFloatBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "ManiculeFloatTitle", { link = "Title", default = true })
end

--- Close the active editor if any.
function M.close_active()
  if active_editor then
    active_editor.close()
  end
end

--- Whether an editor is currently open.
---@return boolean
function M.is_active()
  return active_editor ~= nil
end

--- Open a floating comment editor popup.
---
--- `opts.cfg` must be the `manicule.config.get().ui` table. When
--- `opts.default` is non-empty the cursor is placed at end-of-text; this
--- mirrors codediff's edit flow. On submit the concatenated buffer text
--- is trimmed and passed to `cb`; empty after trim is treated as cancel.
---
---@param opts { title?: string, default?: string, anchor_winid?: integer, anchor_pos?: { [1]: integer, [2]: integer }, cfg: manicule.UIConfig }
---@param cb fun(body: string|nil)
---@return boolean
function M.open(opts, cb)
  opts = opts or {}
  assert(type(opts.cfg) == "table", "manicule.ui.editor.open: opts.cfg is required")
  assert(type(cb) == "function", "manicule.ui.editor.open: cb is required")

  M.close_active()
  ensure_highlights()

  local cfg = opts.cfg
  local anchor_winid = opts.anchor_winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(anchor_winid) then
    anchor_winid = vim.api.nvim_get_current_win()
  end
  local layout = get_editor_layout(cfg, anchor_winid)

  local submit_hint = cfg.submit_keys[1] or "<CR>"
  local cancel_hint = cfg.cancel_keys[1] or "<Esc>"
  local title = string.format(" %s ", opts.title or "Comment")
  local footer = string.format("%s close | %s submit", key_label(cancel_hint), key_label(submit_hint))

  local previous_win = vim.api.nvim_get_current_win()
  local bufnr = create_scratch_buf({ filetype = "markdown" })

  local border = "rounded"
  local win_config = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = layout.width,
    height = layout.height,
    style = "minimal",
    border = border,
    zindex = 220,
  }

  -- If an explicit anchor position was supplied, pin the popup to that
  -- row/col in `anchor_winid` rather than the live cursor.
  if opts.anchor_pos and type(opts.anchor_pos) == "table" then
    local row = tonumber(opts.anchor_pos[1]) or 0
    local col = tonumber(opts.anchor_pos[2]) or 0
    win_config.relative = "win"
    win_config.win = anchor_winid
    win_config.bufpos = { math.max(0, row), math.max(0, col) }
    win_config.row = 1
    win_config.col = 0
  end

  apply_title_footer(win_config, border, title, footer)

  local winhighlight =
    "NormalFloat:NormalFloat,FloatBorder:ManiculeFloatBorder,FloatTitle:ManiculeFloatTitle,FloatFooter:ManiculeFloatTitle"

  local winid = vim.api.nvim_open_win(bufnr, true, win_config)
  set_float_win_options(winid, winhighlight)
  vim.wo[winid].winblend = cfg.opacity or 0

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, split_lines(opts.default))
  local has_default = type(opts.default) == "string" and opts.default ~= ""
  if has_default then
    move_cursor_to_end(winid, opts.default)
  end

  local editor_id = tostring((vim.uv or vim.loop).hrtime())
  local closed = false
  local result_sent = false

  local function send_result(body)
    if result_sent then
      return
    end
    result_sent = true
    -- Dispatch on the next tick so the window actually finishes closing
    -- before any callback-side UI (e.g. another prompt) pops up.
    vim.schedule(function()
      cb(body)
    end)
  end

  local function close_editor()
    if closed then
      return
    end
    closed = true

    if active_editor and active_editor.id == editor_id then
      active_editor = nil
    end

    send_result(nil)

    vim.schedule(function()
      force_normal_mode()
      if vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
      end
      if vim.api.nvim_win_is_valid(previous_win) then
        pcall(vim.api.nvim_set_current_win, previous_win)
      end
      force_normal_mode()
    end)
  end

  local function submit_comment()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local text = read_editor_text(bufnr)
    if text == "" then
      close_editor()
      return
    end
    if closed then
      return
    end
    closed = true
    if active_editor and active_editor.id == editor_id then
      active_editor = nil
    end

    send_result(text)

    vim.schedule(function()
      force_normal_mode()
      if vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
      end
      if vim.api.nvim_win_is_valid(previous_win) then
        pcall(vim.api.nvim_set_current_win, previous_win)
      end
      force_normal_mode()
    end)
  end

  apply_editor_keymaps(bufnr, cfg.submit_keys, cfg.cancel_keys, submit_comment, close_editor)

  if cfg.editor_mode == "insert" and not has_default then
    vim.cmd("startinsert")
  elseif cfg.editor_mode == "insert" and has_default then
    -- When editing a pre-filled body, start in insert at EOL so the user
    -- can keep typing without an extra 'A'.
    vim.cmd("startinsert")
    move_cursor_to_end(winid, opts.default)
  end

  active_editor = {
    id = editor_id,
    winid = winid,
    bufnr = bufnr,
    close = close_editor,
  }

  return true
end

return M
