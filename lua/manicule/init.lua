-- manicule.nvim
-- Public API surface. All heavy `require`s happen inside functions so
-- users with `cmd = {...}` in their lazy spec don't pay the cost on
-- startup.
--
-- Lifecycle events are emitted as native `User` autocmds — there is no
-- `M.on` helper. Subscribe via `vim.api.nvim_create_autocmd`:
--
--   vim.api.nvim_create_autocmd("User", {
--     pattern = "ManiculeAdded",
--     callback = function(ev) vim.print(ev.data) end,
--   })
--
-- Pattern catalog (see `ARCHITECTURE.md` and `doc/manicule.txt`):
--   ManiculeAdded     record
--   ManiculeEdited    record
--   ManiculeDeleted   { id, record }
--   ManiculeResolved  record (with resolved=true)
--   ManiculeSent      { sink, count, ok, err }
--   ManiculeOrphaned  { id, record }

local M = {}

---@class manicule.Config
---@field store? table
---@field handlers? table
---@field sinks? table

-- Per-buffer: record id -> extmark id.
---@type table<integer, table<string, integer>>
local buffer_marks = {}

local function emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data })
end

---Resolve a buffer path to a project-relative path.
---@param bufnr integer
---@param root string|nil
---@return string relpath, string abspath
local function relpath_for_buf(bufnr, root)
  local abs = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
  if not root or abs == "" then
    return abs, abs
  end
  local rel
  if vim.fs.relpath then
    rel = vim.fs.relpath(root, abs)
  end
  if rel and rel ~= "" then
    return rel, abs
  end
  -- Manual fallback: strip the root prefix.
  local root_norm = vim.fs.normalize(root)
  if root_norm:sub(-1) ~= "/" then
    root_norm = root_norm .. "/"
  end
  if abs:sub(1, #root_norm) == root_norm then
    return abs:sub(#root_norm + 1), abs
  end
  return abs, abs
end

---Return the 0-indexed range currently in play for M.add.
---@param opts {range?: table}|nil
---@return {start: integer[], end_: integer[]}
local function resolve_range(opts)
  if opts and opts.range then
    local r = opts.range
    -- Support {l1, l2} (command-line style, 1-indexed) and full 0-indexed form.
    if r.start and r.end_ then
      return r
    end
    local l1, l2 = r[1], r[2] or r[1]
    return {
      start = { l1 - 1, 0 },
      end_ = { l2 - 1, 0 },
    }
  end
  -- Visual selection: when called from select mode the marks '< and '>
  -- are set. If the cursor is currently in visual mode we use the live
  -- positions instead (the marks update only after leaving visual mode).
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\022" then
    vim.cmd.normal({ args = { "\27" }, bang = true }) -- leave visual so '< '> finalize
  end
  local vstart = vim.fn.getpos("'<")
  local vend = vim.fn.getpos("'>")
  if vstart[2] > 0 and vend[2] > 0 and (vstart[2] ~= vend[2] or vstart[3] ~= vend[3]) then
    return {
      start = { vstart[2] - 1, math.max(0, vstart[3] - 1) },
      end_ = { vend[2] - 1, math.max(0, vend[3] - 1) },
    }
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  return { start = { cur[1] - 1, 0 }, end_ = { cur[1] - 1, 0 } }
end

---Attach extmarks for every record matching `bufnr`. Fires
---`ManiculeOrphaned` when a re-attach comes back invalid.
---@param bufnr integer
local function attach_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local store = require("manicule.store")
  local anchor = require("manicule.anchor")
  local root = store.root()
  if not root then
    return
  end
  store.load(root)
  local relpath = relpath_for_buf(bufnr, root)
  local records = store.for_path(root, relpath)
  if #records == 0 then
    return
  end
  local marks = buffer_marks[bufnr] or {}
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local attached = {}
  for _, r in ipairs(records) do
    if not marks[r.id] and r.range and r.range.start then
      local sr = math.min(r.range.start[1] or 0, math.max(0, line_count - 1))
      local sc = r.range.start[2] or 0
      local er = math.min((r.range.end_ and r.range.end_[1]) or sr, math.max(0, line_count - 1))
      local ec = (r.range.end_ and r.range.end_[2]) or sc
      local ok, mark_id = pcall(anchor.create, bufnr, {
        start = { sr, sc },
        end_ = { er, ec },
      })
      if ok then
        marks[r.id] = mark_id
        table.insert(attached, r)
        local resolved = anchor.resolve(bufnr, mark_id)
        if resolved and resolved.invalid then
          emit("ManiculeOrphaned", { id = r.id, record = r })
        end
      end
    end
  end
  buffer_marks[bufnr] = marks
  if #attached > 0 then
    require("manicule.ui.render").attach_all(bufnr, attached)
  end
end

---Initialize manicule with user options.
---@param opts manicule.Config|nil
function M.setup(opts)
  opts = opts or {}
  local config = require("manicule.config")
  config.setup(opts)

  -- Register built-in sinks unless the user opted out.
  local sinks_cfg = opts.sinks or {}
  if sinks_cfg.clipboard ~= false then
    local sinks = require("manicule.sinks")
    local clipboard = require("manicule.sinks.clipboard")
    sinks.register(clipboard.spec)
  end

  -- Idempotent augroup: clear = true means a second setup() wins cleanly.
  local group = vim.api.nvim_create_augroup("manicule", { clear = true })
  local store = require("manicule.store")

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    callback = function(ev)
      attach_buffer(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function()
      local root = store.root()
      if root then
        store.save(root)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
    group = group,
    callback = function(ev)
      buffer_marks[ev.buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      store.flush_all()
    end,
  })
end

---Build the record and wrap up add().
---@param body string
---@param bufnr integer
---@param range table
local function finalize_add(body, bufnr, range)
  if not body or body == "" then
    return
  end
  local anchor = require("manicule.anchor")
  local store = require("manicule.store")
  local id_mod = require("manicule.id")
  local ui = require("manicule.ui")

  local root = store.root()
  local relpath = relpath_for_buf(bufnr, root)
  local mark_id = anchor.create(bufnr, range)
  local now = os.time()
  local record = {
    id = id_mod.new(),
    path = relpath,
    range = range,
    body = body,
    author = ui.git_email(),
    created_at = now,
    updated_at = now,
    resolved = false,
    meta = {},
  }
  store.put(root, record)
  store.save(root)
  local marks = buffer_marks[bufnr] or {}
  marks[record.id] = mark_id
  buffer_marks[bufnr] = marks
  require("manicule.ui.render").attach_one(bufnr, record)
  emit("ManiculeAdded", record)
end

---Add a new comment, optionally tied to a range in the current buffer.
---@param opts {range?: table, body?: string, meta?: table}|nil
function M.add(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local range = resolve_range(opts)
  if opts.body and opts.body ~= "" then
    finalize_add(opts.body, bufnr, range)
    return
  end
  require("manicule.ui").prompt({ prompt = "Comment: " }, function(body)
    if body and body ~= "" then
      finalize_add(body, bufnr, range)
    end
  end)
end

---Find the (root, record) pair for an id.
---@param id string
---@return string|nil root, table|nil record
local function find(id)
  local store = require("manicule.store")
  local root = store.root()
  if not root then
    return nil, nil
  end
  return root, store.get(root, id)
end

---Edit an existing comment by id.
---@param id string
function M.edit(id)
  local root, record = find(id)
  if not root or not record then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  require("manicule.ui").prompt({ prompt = "Edit: ", default = record.body }, function(body)
    if not body or body == "" then
      return
    end
    record.body = body
    record.updated_at = os.time()
    require("manicule.store").put(root, record)
    require("manicule.store").save(root)
    -- Refresh the inline preview for every buffer that's currently showing this record.
    for bufnr, marks in pairs(buffer_marks) do
      if marks[record.id] and vim.api.nvim_buf_is_valid(bufnr) then
        require("manicule.ui.render").refresh_one(bufnr, record)
      end
    end
    emit("ManiculeEdited", record)
  end)
end

---Delete a comment by id.
---@param id string
function M.delete(id)
  local root, record = find(id)
  if not root or not record then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  -- Strip the extmark from any loaded buffer.
  for bufnr, marks in pairs(buffer_marks) do
    local mid = marks[id]
    if mid then
      require("manicule.anchor").delete(bufnr, mid)
      marks[id] = nil
      require("manicule.ui.render").detach(bufnr, id)
    end
  end
  require("manicule.store").remove(root, id)
  require("manicule.store").save(root)
  emit("ManiculeDeleted", { id = id, record = record })
end

---Mark a comment as resolved.
---@param id string
function M.resolve(id)
  local root, record = find(id)
  if not root or not record then
    vim.notify("manicule: no comment with id " .. tostring(id), vim.log.levels.WARN)
    return
  end
  record.resolved = true
  record.updated_at = os.time()
  require("manicule.store").put(root, record)
  require("manicule.store").save(root)
  emit("ManiculeResolved", record)
end

---List comments, optionally filtered.
---@param filter {path?: string, unresolved?: boolean, orphaned?: boolean, author?: string}|nil
---@return table[]
function M.list(filter)
  filter = filter or {}
  local store = require("manicule.store")
  local anchor = require("manicule.anchor")
  local root = store.root()
  if not root then
    return {}
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local all = store.all(root)
  local results = vim
    .iter(all)
    :filter(function(r)
      if filter.path and r.path ~= filter.path then
        return false
      end
      if filter.unresolved and r.resolved then
        return false
      end
      if filter.author and r.author ~= filter.author then
        return false
      end
      if filter.orphaned then
        local marks = buffer_marks[bufnr] or {}
        local mid = marks[r.id]
        if not mid then
          return false
        end
        local resolved = anchor.resolve(bufnr, mid)
        if not resolved or not resolved.invalid then
          return false
        end
      end
      return true
    end)
    :totable()

  -- If called as a command (no filter, no caller return-use), push to quickfix.
  if not filter._quiet and (filter.to_qflist or vim.tbl_count(filter) == 0) then
    require("manicule.ui.quickfix").show(results, { open = true })
  end
  return results
end

---Dispatch filtered comments to a named sink.
---@param sink_name string
---@param filter table|nil
---@param ctx table|nil
function M.send(sink_name, filter, ctx)
  filter = filter or {}
  filter._quiet = true
  local records = M.list(filter)
  require("manicule.sinks").dispatch(sink_name, records, ctx or {}, function(ok, err)
    emit("ManiculeSent", {
      sink = sink_name,
      count = #records,
      ok = ok,
      err = err,
    })
    if not ok then
      vim.notify(("manicule: sink %q failed: %s"):format(sink_name, tostring(err)), vim.log.levels.ERROR)
    end
  end)
end

---Register a sink adapter. Delegates to the sinks registry.
---@param spec {name: string, send: fun(comments: table, ctx: table, cb: fun(ok, err)), format?: fun(c): string, validate?: fun(ctx): boolean, string?}
function M.register_sink(spec)
  return require("manicule.sinks").register(spec)
end

-- Exposed for tests; not part of the public API.
function M._buffer_marks()
  return buffer_marks
end

return M
