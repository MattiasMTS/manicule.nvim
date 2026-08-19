-- manicule.nvim: review session core.
--
-- Opens baseline-vs-worktree file pairs as diffs, one active session at
-- a time. The right side is always the real worktree file so comments
-- anchor natively; the left side is a read-only staged baseline copy.
-- Diff rendering prefers the builtin nvim.difftool (0.12+) and falls
-- back to plain :diffsplit.

local M = {}

---@class manicule.ReviewSession
---@field files {left: string, right: string, status: string, path: string}[]
---@field label string
---@field sink string|nil
---@field sink_ctx table|nil
---@field index integer
---@field tab integer

---@type manicule.ReviewSession|nil
local session = nil

local function difftool_mod()
  if not pcall(vim.cmd.packadd, "nvim.difftool") then
    return nil
  end
  local ok, mod = pcall(require, "difftool")
  return ok and mod or nil
end

local function protect_left(bufnr)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
end

local function close_session_windows()
  -- Reduce the session tab to one window so the next pair starts clean.
  vim.cmd("silent! diffoff!")
  vim.cmd("silent! only")
end

local function set_quickfix(files, label)
  local items = {}
  for _, pair in ipairs(files) do
    table.insert(items, {
      filename = pair.status == "D" and pair.left or pair.right,
      lnum = 1,
      text = ("[%s] %s"):format(pair.status, pair.path),
    })
  end
  vim.fn.setqflist({}, " ", {
    title = ("manicule-review (%s)"):format(label),
    items = items,
  })
end

---@param index integer
function M.open(index)
  if not session then
    return
  end
  if index < 1 then
    index = #session.files
  elseif index > #session.files then
    index = 1
  end
  session.index = index
  local pair = session.files[index]
  vim.api.nvim_set_current_tabpage(session.tab)
  close_session_windows()

  if pair.status == "D" then
    vim.cmd.edit(vim.fn.fnameescape(pair.left))
    protect_left(vim.api.nvim_get_current_buf())
    vim.notify(
      ("manicule: %s was deleted; comments here are file-level notes"):format(pair.path),
      vim.log.levels.INFO
    )
    return
  end

  -- Note: nvim.difftool (0.12+) is available but currently not used.
  -- The plugin creates buffers with both sides modifiable, and protecting
  -- them after the fact is unreliable (timing issues, buffer identification).
  -- The plain :diffsplit fallback provides consistent, testable behavior.
  -- difftool support can be added later with proper buffer event hooks.
  local use_difftool = false
  local difftool = use_difftool and difftool_mod() or nil
  if difftool then
    local ok = pcall(difftool.open, pair.left, pair.right)
    if ok then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_get_name(buf) == vim.fs.normalize(pair.left) then
          protect_left(buf)
        end
      end
      return
    end
  end

  -- Fallback: plain diffsplit. Right first (focused), left split beside it.
  vim.cmd.edit(vim.fn.fnameescape(pair.right))
  vim.cmd("leftabove vertical diffsplit " .. vim.fn.fnameescape(pair.left))
  protect_left(vim.api.nvim_get_current_buf())
  vim.cmd.wincmd("p") -- focus back on the right / worktree side
end

function M.next()
  if session then
    M.open(session.index + 1)
  end
end

function M.prev()
  if session then
    M.open(session.index - 1)
  end
end

---@return manicule.ReviewSession|nil
function M.state()
  return session
end

---Start a review session over explicit file pairs.
---@param opts {files: table[], label?: string, sink?: string, sink_ctx?: table}
---@return boolean ok, string|nil err
function M.start(opts)
  opts = opts or {}
  if type(opts.files) ~= "table" or #opts.files == 0 then
    return false, "manicule: review has no files to show"
  end
  if session then
    M.stop()
  end
  vim.cmd.tabnew()
  session = {
    files = opts.files,
    label = opts.label or "review",
    sink = opts.sink,
    sink_ctx = opts.sink_ctx,
    index = 1,
    tab = vim.api.nvim_get_current_tabpage(),
  }
  set_quickfix(session.files, session.label)
  M.open(1)
  return true
end

function M.stop()
  if not session then
    return
  end
  local tab = session.tab
  session = nil
  if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("silent! diffoff!")
    vim.cmd("tabclose")
  end
end

return M
