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

local uv = vim.uv

---@class manicule.ReviewSession
---@field files {left: string, right: string, status: string, path: string}[]
---@field label string
---@field sink string|nil
---@field sink_ctx table|nil
---@field index integer
---@field tab integer
---@field root string|nil project root the worktree files live under (cached by start)
---@field uris string[] pair_path URI per file, index-aligned with `files` (cached by start)
---@field uri_set table<string, true> membership set over `uris` (list()/send() filter)
---@field uri_index table<string, integer> URI -> first pair index (panel jumps)
---@field stage_dirs string[]|nil staging dirs the session OWNS; deleted by stop()
---@field mapped_bufs table<integer, true>|nil

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

---Windows the pair-switch teardown must never touch: the review panel
---(an owned `manicule-panel` scratch buffer) and any quickfix/loclist
---window the USER has open — the panel no longer lives in the quickfix
---list, so those are entirely the user's.
---@param winid integer
---@return boolean
local function is_preserved_window(winid)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.bo[bufnr].buftype == "quickfix" or vim.bo[bufnr].filetype == "manicule-panel"
end

local function close_session_windows()
  -- Reduce the session tab windows to diff windows only (preserve the
  -- panel and any user quickfix). Unified paint is buffer-scoped, so it
  -- must be dropped explicitly — `diffoff!` knows nothing about it.
  require("manicule.review.inline").clear_all()
  vim.cmd("silent! diffoff!")
  -- Close all non-preserved windows except the first one
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local first_file_win = nil
  for _, winid in ipairs(wins) do
    if not is_preserved_window(winid) then
      if not first_file_win then
        first_file_win = winid
      else
        pcall(vim.api.nvim_win_close, winid, false)
      end
    end
  end
  -- Focus the remaining file window. When none is left (e.g. `:only`
  -- from the panel), make a fresh one — a pair must never be edited
  -- into the panel or a quickfix window.
  if first_file_win and vim.api.nvim_win_is_valid(first_file_win) then
    vim.api.nvim_set_current_win(first_file_win)
  elseif is_preserved_window(vim.api.nvim_get_current_win()) then
    pcall(vim.api.nvim_open_win, vim.api.nvim_create_buf(false, true), true, { split = "above", win = -1 })
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
  -- The review tab can die under the session (`:tabclose` instead of
  -- stop()): the session and its buffer-local <Tab> maps survive, and
  -- the dead handle used to throw 'Invalid tabpage id' here. Recreate
  -- the tab (panel included) rather than stopping, so the session and
  -- its pending comments stay alive. A TabClosed autocmd that stops the
  -- session would fight this recovery — an accidental close would kill
  -- the review and the VimLeavePre autoflush of its comments — so we
  -- recover lazily here instead.
  if not vim.api.nvim_tabpage_is_valid(session.tab) then
    vim.cmd.tabnew()
    session.tab = vim.api.nvim_get_current_tabpage()
    require("manicule.review.panel").open()
  end
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
  local left_win = vim.api.nvim_get_current_win()
  protect_left(vim.api.nvim_get_current_buf())
  map_navigation(vim.api.nvim_get_current_buf())
  map_navigation(right_buf)
  vim.cmd.wincmd("p") -- focus back on the right / worktree side
  if cfg.fold_unchanged == false then
    -- Native :diffsplit folds unchanged regions (foldmethod=diff); the
    -- default is the whole file visible, so drop the folds in both sides.
    vim.wo[left_win].foldenable = false
    vim.wo[vim.api.nvim_get_current_win()].foldenable = false
  end
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

---Path of the buffer a pair is reviewed — and commented — in: the
---worktree file (right side), except for deletions, where only the
---staged baseline (left side) still exists to open and anchor
---comments to.
---@param pair {left: string, right: string, status: string}
---@return string
function M.pair_path(pair)
  return pair.status == "D" and pair.left or pair.right
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

---Session-derived query cache, computed ONCE per session: the URI of
---every commentable buffer (see M.pair_path — matching how
---adapter.identify keys records) and the project root the worktree
---files live under. `uri.for_path` costs an fs_realpath per file and
---`vim.fs.root` a marker walk; finish(), the VimLeavePre autoflush, and
---every panel refresh used to redo that work per call. `session.files`
---never changes after start, so the cache cannot go stale.
---
---The root matters because list() resolves the store root from the
---CURRENT buffer, falling back to cwd — which, from an unnamed buffer,
---the VimLeavePre autoflush, or a job-driven review of an external
---worktree, can miss the reviewed project entirely and silently drop
---the session's comments. It is passed as `_root` on every list/send
---filter instead.
---@param s manicule.ReviewSession
local function build_session_cache(s)
  local uri_mod = require("manicule.uri")
  s.uris = {}
  s.uri_set = {}
  s.uri_index = {}
  for idx, pair in ipairs(s.files) do
    local uri = uri_mod.for_path(M.pair_path(pair))
    s.uris[idx] = uri
    s.uri_set[uri] = true
    if not s.uri_index[uri] then
      s.uri_index[uri] = idx
    end
  end
  local markers = require("manicule.config").current.store.root_markers
  for _, pair in ipairs(s.files) do
    local root = vim.fs.root(M.pair_path(pair), markers)
    if root then
      s.root = root
      break
    end
  end
end

---Start a review session over explicit file pairs. `stage_dirs` lists
---staging directories the session OWNS: stop() deletes them (and wipes
---any buffer still pointing into them). Resolvers report only dirs they
---created themselves.
---@param opts {files: table[], label?: string, sink?: string, sink_ctx?: table, stage_dirs?: string[]}
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
    stage_dirs = opts.stage_dirs,
    index = 1,
    tab = vim.api.nvim_get_current_tabpage(),
  }
  build_session_cache(session)
  M.open(1)
  -- The panel is an owned scratch-buffer split (files/comments views);
  -- review mode never touches the quickfix stack.
  require("manicule.review.panel").open()
  return true
end

---Delete the staging dirs a stopped session OWNED. Buffers first:
---deleted-file pairs opened the LEFT staged file, and a
---pr-head-not-checked-out session opens staged RIGHT files as plain
---file buffers — wipe anything still pointing into a stage dir so no
---buffer is left naming a removed file. Comments recorded on those
---staged URIs live in the session-scope store and simply remain
---(session-scoped by design; finish() already ran or the user chose
---not to send).
---@param stage_dirs string[]|nil
local function cleanup_stage_dirs(stage_dirs)
  if type(stage_dirs) ~= "table" or #stage_dirs == 0 then
    return
  end
  local prefixes = {}
  for _, dir in ipairs(stage_dirs) do
    if type(dir) == "string" and dir ~= "" and dir ~= "/" then
      local norm = dir:gsub("/+$", "")
      prefixes[#prefixes + 1] = norm .. "/"
      -- Buffer names may carry the resolved path (macOS: /tmp and
      -- /var/folders are symlinks under /private).
      local real = uv.fs_realpath(norm)
      if real and real ~= norm then
        prefixes[#prefixes + 1] = real .. "/"
      end
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      for _, prefix in ipairs(prefixes) do
        if name:sub(1, #prefix) == prefix then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
          break
        end
      end
    end
  end
  for _, dir in ipairs(stage_dirs) do
    if type(dir) == "string" and dir ~= "" and dir ~= "/" then
      vim.fn.delete(dir, "rf")
    end
  end
end

function M.stop()
  if not session then
    return
  end
  require("manicule.review.panel").close()
  local tab = session.tab
  local stage_dirs = session.stage_dirs
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
  -- Owned staging dirs go LAST, after the tab/windows above are gone,
  -- so no window is left displaying a removed file. stop() is
  -- deliberately not wired to VimLeavePre: the autoflush there must
  -- finish its send first, and leaking dirs on a hard exit is the
  -- accepted trade (in-session stop/restart is what must not leak).
  cleanup_stage_dirs(stage_dirs)
end

---Count the session's pending comments without side effects. Records
---imported FROM GitHub (meta.github.imported) are excluded: finish()
---must never echo GitHub's own comments back through the sink. The
---uris/root filters come from the session cache (see
---build_session_cache).
local function pending_comments()
  if not session then
    return {}
  end
  return require("manicule").list({
    _quiet = true,
    uris = session.uri_set,
    exclude_imported = true,
    _root = session.root,
  })
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
  -- send() re-lists internally — its contract takes a filter, never
  -- pre-fetched records — so the pending_comments() gate above plus
  -- this call cost two list() passes. Avoiding that needs a
  -- records-accepting send() in init.lua; with the cached uris/root
  -- each pass is cheap, so the double list stays.
  require("manicule").send(
    sink,
    { uris = session.uri_set, exclude_imported = true, _root = session.root },
    session.sink_ctx
  )
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
    -- External drivers own their staged files: stop() deletes them only
    -- when the job opts in by listing them under `stage_dirs`.
    stage_dirs = type(job.stage_dirs) == "table" and job.stage_dirs or nil,
  })
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
  end
  return ok, err
end

---Milliseconds the VimLeavePre autoflush blocks waiting for the sink to
---settle. The socket sink writes its never-lose-comments submit.json
---fallback only when its ack timer fires, so the wait must outlive the
---configured `ack_timeout_ms` (plus margin for the scheduled fallback
---write) — a hard-coded 2500 lost comments for any timeout >= 2500. The
---historical 2500 stays as the floor. Exposed for tests.
---@return integer
function M._autoflush_wait_ms()
  local sinks_cfg = require("manicule.config").get().sinks or {}
  local socket_cfg = type(sinks_cfg.socket) == "table" and sinks_cfg.socket or {}
  local ack = tonumber(socket_cfg.ack_timeout_ms) or 2000
  return math.max(2500, ack + 500)
end

local augroup = vim.api.nvim_create_augroup("ManiculeReview", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  callback = function()
    if session and session.sink and #pending_comments() > 0 then
      -- Block until the async sink settles or times out so the submit/fallback
      -- completes before nvim exits. The wait is derived from the socket
      -- sink's configured ack_timeout_ms: any shorter and nvim exits before
      -- the sink's submit.json fallback timer ever fires.
      local done = false
      local done_id = vim.api.nvim_create_autocmd("User", {
        pattern = "ManiculeSent",
        once = true,
        callback = function()
          done = true
        end,
      })
      M.finish()
      vim.wait(M._autoflush_wait_ms(), function()
        return done
      end, 50, false)
      pcall(vim.api.nvim_del_autocmd, done_id)
    end
  end,
})

return M
