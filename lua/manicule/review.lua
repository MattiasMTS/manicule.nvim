-- manicule.nvim: review session core.
--
-- Opens baseline-vs-worktree file pairs as diffs, one active session at
-- a time. Whichever mode is active, the buffer the user comments in is
-- the real worktree file, so comments anchor natively.
--
--   * `review.mode = "split"` (default) — plain `:diffsplit`: read-only
--     staged baseline on the left, worktree file on the right.
--   * `review.mode = "unified"` — a single window showing the worktree
--     file with the diff painted onto it (see `review/inline.lua`).
--
-- `:ManiculeReviewDiffMode` flips between them, re-rendering the pair
-- that is currently open.

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

---@return manicule.ReviewConfig
local function review_config()
  return require("manicule.config").get().review or {}
end

local function close_session_windows()
  -- Reduce the session tab windows to diff windows only (preserve qf panel).
  -- Unified paint is buffer-scoped, so it must be dropped explicitly —
  -- `diffoff!` knows nothing about it.
  require("manicule.review.inline").clear_all()
  vim.cmd("silent! diffoff!")
  -- Close all non-quickfix windows except the first one
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local first_non_qf = nil
  for _, winid in ipairs(wins) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].buftype ~= "quickfix" then
      if not first_non_qf then
        first_non_qf = winid
      else
        pcall(vim.api.nvim_win_close, winid, false)
      end
    end
  end
  -- Focus the remaining non-qf window
  if first_non_qf and vim.api.nvim_win_is_valid(first_non_qf) then
    vim.api.nvim_set_current_win(first_non_qf)
  end
end

-- Session-scoped file navigation: <Tab>/<S-Tab> cycle pairs. Buffer-local
-- so the global <Tab> (= <C-i> jumplist) is shadowed only inside review
-- buffers, and removed again in stop(). Left buffers are bufhidden=wipe;
-- right buffers are real files, so stop() must unmap them explicitly.
local function map_navigation(bufnr)
  if not session then
    return
  end
  vim.keymap.set("n", "<Tab>", function()
    require("manicule.review").next()
  end, { buffer = bufnr, desc = "Manicule review: next file" })
  vim.keymap.set("n", "<S-Tab>", function()
    require("manicule.review").prev()
  end, { buffer = bufnr, desc = "Manicule review: previous file" })
  session.mapped_bufs = session.mapped_bufs or {}
  session.mapped_bufs[bufnr] = true
end

local function unmap_navigation(mapped_bufs)
  for bufnr in pairs(mapped_bufs or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.keymap.del, "n", "<Tab>", { buffer = bufnr })
      pcall(vim.keymap.del, "n", "<S-Tab>", { buffer = bufnr })
    end
  end
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
    map_navigation(vim.api.nvim_get_current_buf())
    vim.notify(("manicule: %s was deleted; comments here are file-level notes"):format(pair.path), vim.log.levels.INFO)
    require("manicule.review.panel").sync_index(index)
    return
  end

  local cfg = review_config()

  if cfg.mode == "unified" then
    -- One window, the worktree file itself, with the baseline painted on
    -- as virtual lines. No second buffer means nothing to protect and no
    -- coordinate translation anywhere in the comment path.
    vim.cmd.edit(vim.fn.fnameescape(pair.right))
    local buf = vim.api.nvim_get_current_buf()
    local ok, err = require("manicule.review.inline").apply(buf, pair.left, {
      fold = cfg.fold_unchanged ~= false,
      context = cfg.context,
    })
    if not ok then
      vim.notify(err or "manicule: cannot render inline diff", vim.log.levels.WARN)
    end
    map_navigation(buf)
    require("manicule.review.panel").sync_index(index)
    return
  end

  -- Plain diffsplit: Right first (focused), left split beside it.
  -- nvim.difftool support could be added later via open() hook if needed.
  vim.cmd.edit(vim.fn.fnameescape(pair.right))
  local right_buf = vim.api.nvim_get_current_buf()
  vim.cmd("leftabove vertical diffsplit " .. vim.fn.fnameescape(pair.left))
  protect_left(vim.api.nvim_get_current_buf())
  map_navigation(vim.api.nvim_get_current_buf())
  map_navigation(right_buf)
  vim.cmd.wincmd("p") -- focus back on the right / worktree side
  -- Keep the panel's files view pointing at the pair now on screen.
  require("manicule.review.panel").sync_index(index)
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

---Switch the diff rendering used by review sessions. With no argument,
---flips between "split" and "unified". The setting lives on the merged
---config, so it also becomes the default for later sessions in this
---Neovim instance; put `review.mode` in `setup()` to make it permanent.
---@param mode? "split"|"unified"|"" nil/"" toggles
---@return string|nil mode, string|nil err
function M.set_diff_mode(mode)
  local cfg = require("manicule.config").get()
  cfg.review = cfg.review or {}
  if mode == nil or mode == "" then
    mode = cfg.review.mode == "unified" and "split" or "unified"
  end
  if mode ~= "split" and mode ~= "unified" then
    local err = ('manicule: review mode must be "split" or "unified", got %q'):format(tostring(mode))
    vim.notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  cfg.review.mode = mode
  if session then
    -- Re-render the pair on screen so the switch is visible immediately
    -- rather than at the next file.
    M.open(session.index)
  end
  vim.notify(("manicule: review diff mode is %s"):format(mode), vim.log.levels.INFO)
  return mode
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
  M.open(1)
  -- The panel owns the review quickfix list (files/comments views);
  -- review.lua itself never writes the qf stack.
  require("manicule.review.panel").open()
  return true
end

function M.stop()
  if not session then
    return
  end
  require("manicule.review.panel").close()
  local tab = session.tab
  -- Worktree buffers outlive the session tab, so the inline paint has to
  -- come off explicitly or the file keeps its diff highlights forever.
  require("manicule.review.inline").clear_all()
  unmap_navigation(session.mapped_bufs)
  session = nil
  if vim.api.nvim_tabpage_is_valid(tab) then
    local tab_count = #vim.api.nvim_list_tabpages()
    if tab_count > 1 then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("silent! diffoff!")
      vim.cmd("tabclose")
    else
      -- Single tab: close all windows and buffers to clean up
      vim.cmd("silent! diffoff!")
      vim.cmd("silent! only")
      vim.cmd("silent! enew")
    end
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

---Count the session's pending comments without side effects. Records
---imported FROM GitHub (meta.github.imported) are excluded: finish()
---must never echo GitHub's own comments back through the sink.
local function pending_comments()
  if not session then
    return {}
  end
  return require("manicule").list({ _quiet = true, uris = session_uris(), exclude_imported = true })
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
  require("manicule").send(sink, { uris = session_uris(), exclude_imported = true }, session.sink_ctx)
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
