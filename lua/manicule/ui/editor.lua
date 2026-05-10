-- manicule.nvim: floating-window comment editor.
--
-- Buffer-agnostic floating editor for adding and editing comment bodies.
-- The editor anchors to the cursor in the current window. Only one
-- editor is live at a time; opening a second one closes the first.
--
-- Float primitives (`create_scratch_buf`, `open_or_reconfigure`,
-- `apply_title_footer`, `set_float_win_options`) are shared with
-- `ui/render.lua` via `ui/float.lua`. The editor also reuses the render
-- layer's `winhighlight` so popups and the editor look identical.
--
-- Submit/cancel keys, initial mode, size, and opacity all come from
-- `manicule.config.get().ui` (see `config.lua`).

local M = {}

local float = require("manicule.ui.float")

---@class manicule.ui.editor.Active
---@field id string
---@field winid integer
---@field bufnr integer
---@field close fun()

---@type manicule.ui.editor.Active?
local active_editor = nil
local opening_editor = false

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

---@param key string?
---@return boolean
local function is_enter_key(key)
  return key == "<CR>" or key == "<Enter>" or key == "<Return>"
end

---@param keys string[]?
---@param fallback string
---@return string
local function first_key(keys, fallback)
  return type(keys) == "table" and keys[1] or fallback
end

---@param cfg manicule.UIConfig
---@return string
local function footer_text(cfg)
  local submit_hint = first_key(cfg.submit_keys, "<CR>")
  local cancel_hint = first_key(cfg.cancel_keys, "<Esc>")
  if cfg.editor_mode == "insert" and is_enter_key(submit_hint) then
    return string.format("enter newline | normal %s submit | %s close", key_label(submit_hint), key_label(cancel_hint))
  end
  return string.format("%s submit | %s close", key_label(submit_hint), key_label(cancel_hint))
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

---Apply editor window options. The editor hard-wraps at the float edge, but
---keeps `linebreak` off so visual wrapping does not jump early to a word
---boundary and make soft wraps look like manual newlines.
---@param winid integer
---@param winhighlight string
local function apply_editor_win_options(winid, winhighlight)
  float.set_float_win_options(winid, winhighlight)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.wo[winid].wrap = true
    vim.wo[winid].linebreak = false
  end
end

---@param bufnr integer
---@param submit_keys string[]
---@param cancel_keys string[]
---@param submit_comment fun()
---@param close_editor fun()
local function apply_editor_keymaps(bufnr, submit_keys, cancel_keys, submit_comment, close_editor)
  local seen = {}
  local function map_key(mode, key, rhs, group)
    local map_id = string.format("%s:%s:%s", group, mode, key)
    if seen[map_id] then
      return
    end
    seen[map_id] = true
    vim.keymap.set(mode, key, rhs, {
      buffer = bufnr,
      noremap = true,
      silent = true,
      nowait = true,
    })
  end

  -- Insert-mode <CR> is intentionally left alone so multi-line editing uses
  -- Neovim's native newline behavior. We still install a buffer-local insert
  -- mapping for it because buffer-local mappings beat global completion maps.
  -- The default submit key is normal-mode <CR>: press <Esc>, then <CR>.
  local function insert_submit()
    pcall(vim.cmd, "stopinsert")
    submit_comment()
  end
  local function insert_cancel()
    pcall(vim.cmd, "stopinsert")
    close_editor()
  end
  for _, key in ipairs(submit_keys) do
    if type(key) == "string" and key ~= "" then
      map_key("n", key, submit_comment, "submit")
      if is_enter_key(key) then
        map_key("i", key, "<CR>", "newline")
      else
        map_key("i", key, insert_submit, "submit")
      end
    end
  end
  for _, key in ipairs(cancel_keys) do
    if type(key) == "string" and key ~= "" then
      map_key("n", key, close_editor, "cancel")
      -- Only bind the cancel key in insert mode when it looks like a
      -- control sequence (e.g. "<Esc>", "<C-c>"). A plain letter such as
      -- the default "q" must remain typeable.
      if key:match("^<.+>$") then
        map_key("i", key, insert_cancel, "cancel")
      end
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

function M.is_opening()
  return opening_editor
end

--- Open a floating comment editor popup.
---
--- `opts.cfg` must be the `manicule.config.get().ui` table. When
--- `opts.default` is non-empty the cursor is placed at end-of-text; this
--- matches the normal edit flow. On submit the concatenated buffer text
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

  local cfg = opts.cfg
  local anchor_winid = opts.anchor_winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(anchor_winid) then
    anchor_winid = vim.api.nvim_get_current_win()
  end
  local layout = get_editor_layout(cfg, anchor_winid)

  local title = string.format(" %s ", opts.title or "Comment")
  local footer = footer_text(cfg)

  local previous_win = vim.api.nvim_get_current_win()
  local bufnr = float.create_scratch_buf({ filetype = "markdown" })
  pcall(function()
    if vim.lsp and vim.lsp.inline_completion then
      vim.lsp.inline_completion.enable(false, { bufnr = bufnr })
    end
  end)

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

  float.apply_title_footer(win_config, border, title, "left", footer, "left")

  -- Reuse the render layer's shared winhighlight so the editor and
  -- popups pick up the same border/meta colours.
  local winhighlight = require("manicule.ui.render").winhighlight()

  opening_editor = true
  local open_ok, winid_or_err = pcall(vim.api.nvim_open_win, bufnr, true, win_config)
  opening_editor = false
  if not open_ok then
    error(winid_or_err)
  end
  local winid = winid_or_err
  apply_editor_win_options(winid, winhighlight)
  float.set_float_transparency(winid, cfg.opacity)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, split_lines(opts.default))
  local has_default = type(opts.default) == "string" and opts.default ~= ""
  if has_default then
    move_cursor_to_end(winid, opts.default)
  end

  local editor_id = tostring((vim.uv or vim.loop).hrtime())
  local closed = false
  local result_sent = false

  local function finish(body)
    if result_sent then
      return
    end
    result_sent = true

    vim.schedule(function()
      force_normal_mode()
      if vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
      end
      if vim.api.nvim_win_is_valid(previous_win) then
        pcall(vim.api.nvim_set_current_win, previous_win)
      end
      force_normal_mode()

      -- Dispatch after the editor window has actually finished closing.
      -- Callback-side UI and render refreshes can otherwise race with
      -- WinLeave/BufLeave cleanup from the closing float.
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

    finish(nil)
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

    finish(text)
  end

  local function install_keymaps()
    apply_editor_keymaps(bufnr, cfg.submit_keys, cfg.cancel_keys, submit_comment, close_editor)
  end

  local function schedule_install_keymaps()
    vim.schedule(function()
      if not closed and vim.api.nvim_buf_is_valid(bufnr) then
        install_keymaps()
      end
    end)
  end

  install_keymaps()
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = bufnr,
    callback = function()
      install_keymaps()
      schedule_install_keymaps()
    end,
  })

  if cfg.editor_mode == "insert" and not has_default then
    vim.cmd("startinsert")
  elseif cfg.editor_mode == "insert" and has_default then
    -- When editing a pre-filled body, start in insert at EOL so the user
    -- can keep typing without an extra 'A'.
    vim.cmd("startinsert")
    move_cursor_to_end(winid, opts.default)
  end

  schedule_install_keymaps()

  active_editor = {
    id = editor_id,
    winid = winid,
    bufnr = bufnr,
    close = close_editor,
  }

  return true
end

return M
