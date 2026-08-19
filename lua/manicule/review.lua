-- manicule.nvim: review session core.
--
-- Opens baseline-vs-worktree file pairs as diffs, one active session at
-- a time. The right side is always the real worktree file so comments
-- anchor natively; the left side is a read-only staged baseline copy.
-- Uses plain :diffsplit for reliable, pair-based diff rendering.

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
    vim.notify(("manicule: %s was deleted; comments here are file-level notes"):format(pair.path), vim.log.levels.INFO)
    return
  end

  -- Plain diffsplit: Right first (focused), left split beside it.
  -- nvim.difftool support could be added later via open() hook if needed.
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

---URIs for every commentable buffer in the session (right side; left
---side for deletions), matching how adapter.identify keys records.
local function session_uris()
  local uri_mod = require("manicule.uri")
  local uris = {}
  for _, pair in ipairs(session.files) do
    local path = pair.status == "D" and pair.left or pair.right
    uris[uri_mod.for_path(path)] = true
  end
  return uris
end

---Count the session's pending comments without side effects.
local function pending_comments()
  if not session then
    return {}
  end
  return require("manicule").list({ _quiet = true, uris = session_uris() })
end

---Dispatch the session's comments to the configured sink.
---@param opts? {sink?: string}
function M.finish(opts)
  opts = opts or {}
  if not session then
    vim.notify("manicule: no active review session", vim.log.levels.WARN)
    return
  end
  local sink = opts.sink or session.sink
  if not sink then
    vim.notify("manicule: review session has no sink configured", vim.log.levels.WARN)
    return
  end
  local comments = pending_comments()
  if #comments == 0 then
    vim.notify("manicule: review has no comments to send", vim.log.levels.INFO)
    return
  end
  require("manicule").send(sink, { uris = session_uris() }, session.sink_ctx)
end

---Start a review from a JSON job file written by an external driver
---(e.g. a coding-agent extension). Errors are returned AND notified so
---headless drivers see them on stderr.
---@param path string
---@return boolean ok, string|nil err
function M.start_from_job(path)
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    local err = ("manicule: cannot read job file %s"):format(path)
    vim.notify(err, vim.log.levels.ERROR)
    return false, err
  end
  local ok_decode, job = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode or type(job) ~= "table" or type(job.files) ~= "table" then
    local err = ("manicule: invalid job file %s"):format(path)
    vim.notify(err, vim.log.levels.ERROR)
    return false, err
  end
  local sink_ctx = nil
  local sink = nil
  if type(job.return_socket) == "string" and job.return_socket ~= "" then
    sink = "socket"
    sink_ctx = { socket = job.return_socket, job = job.id, label = job.label }
  end
  local ok, err = M.start({
    files = job.files,
    label = job.label or "review",
    sink = sink,
    sink_ctx = sink_ctx,
  })
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
  end
  return ok, err
end

local augroup = vim.api.nvim_create_augroup("ManiculeReview", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    if session and session.sink and #pending_comments() > 0 then
      -- Block until the async sink settles or times out so the submit/fallback
      -- completes before nvim exits. Socket sink's default ack_timeout_ms is
      -- 2000; wait slightly longer to let submit.json fallback finish.
      local done = false
      local done_id = vim.api.nvim_create_autocmd("User", {
        pattern = "ManiculeSent",
        once = true,
        callback = function()
          done = true
        end,
      })
      M.finish()
      vim.wait(2500, function()
        return done
      end, 50, false)
      pcall(vim.api.nvim_del_autocmd, done_id)
    end
  end,
})

return M
