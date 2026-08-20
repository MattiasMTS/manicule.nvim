if vim.g.loaded_manicule then
  return
end
vim.g.loaded_manicule = 1

---Resolve a command's opts into the action to run.
---
---- No argument → open the `vim.ui.select` picker for the action.
---- Numeric argument in `[1, #records]` → dispatch to the action with
---  the id at that position in `list()` ordering.
---- Anything else → ERROR notify.
---@param action "edit"|"delete"|"resolve"
---@param opts table
local function dispatch_positional(action, opts)
  local records = require("manicule").list({ _quiet = true })
  if opts.args == nil or opts.args == "" then
    require("manicule.ui.picker").pick(action, records)
    return
  end
  local n = tonumber(opts.args)
  if not n or n ~= math.floor(n) or n < 1 or n > #records then
    vim.notify(("manicule: no comment at position %q"):format(opts.args), vim.log.levels.ERROR)
    return
  end
  require("manicule")[action](records[n].id, {
    scope = records[n].scope,
    project_root = records[n].project_root,
  })
end

---Tab-completion returns stringified positions `"1"`..`"N"`. Command-
---line completion tokens don't support display text — that's what the
---picker is for.
---@return string[]
local function position_completer()
  local records = require("manicule").list({ _quiet = true })
  local out = {}
  for i = 1, #records do
    out[i] = tostring(i)
  end
  return out
end

vim.api.nvim_create_user_command("ManiculeAdd", function(opts)
  require("manicule").add({ range = opts.range > 0 and { opts.line1, opts.line2 } or nil })
end, { range = true })

vim.api.nvim_create_user_command("ManiculeList", function()
  require("manicule").list()
end, {})

---Verdict words accepted as the optional second argument of
---`:ManiculeSend github`, mapped to the GitHub review event they pick
---for that send (overriding the sink's configured `event`).
local send_verdicts = {
  comment = "COMMENT",
  approve = "APPROVE",
  ["request-changes"] = "REQUEST_CHANGES",
}

vim.api.nvim_create_user_command("ManiculeSend", function(opts)
  local sink = opts.fargs[1]
  local ctx
  if opts.fargs[2] ~= nil then
    local event = send_verdicts[opts.fargs[2]]
    if not event then
      vim.notify(
        ("manicule: unknown verdict %q (expected comment, approve, or request-changes)"):format(opts.fargs[2]),
        vim.log.levels.ERROR
      )
      return
    end
    -- A verdict only means something to a sink that consumes ctx.event
    -- (`spec.accepts_verdict`, e.g. github). Refuse rather than silently
    -- dropping the verdict and sending anyway. An unregistered sink name
    -- falls through: dispatch reports its own "unknown sink" error.
    local spec = require("manicule.sinks").get(sink)
    if spec and not spec.accepts_verdict then
      vim.notify(
        ("manicule: sink %q does not accept a verdict; drop %q or send to github"):format(sink, opts.fargs[2]),
        vim.log.levels.ERROR
      )
      return
    end
    ctx = { event = event }
  end
  require("manicule").send(sink, nil, ctx)
end, {
  nargs = "*",
  complete = function(arglead, cmdline)
    -- Second argument after `github`: complete the verdict words.
    local sink = cmdline:match("ManiculeSend%s+(%S+)%s")
    if sink == "github" then
      local out = {}
      for _, verdict in ipairs({ "approve", "comment", "request-changes" }) do
        if verdict:find(arglead, 1, true) == 1 then
          table.insert(out, verdict)
        end
      end
      return out
    end
    return require("manicule.sinks").list()
  end,
})

vim.api.nvim_create_user_command("ManiculeResolve", function(opts)
  dispatch_positional("resolve", opts)
end, { nargs = "?", complete = position_completer })

vim.api.nvim_create_user_command("ManiculeDelete", function(opts)
  dispatch_positional("delete", opts)
end, { nargs = "?", complete = position_completer })

vim.api.nvim_create_user_command("ManiculeEdit", function(opts)
  dispatch_positional("edit", opts)
end, { nargs = "?", complete = position_completer })

---During an active review session, :ManiculeToggle shows/hides the
---review panel; otherwise it flips comment visuals on/off.
local function toggle()
  if require("manicule.review").state() then
    require("manicule.review.panel").toggle()
    return
  end
  require("manicule.ui.render").toggle()
end

vim.api.nvim_create_user_command("ManiculeToggle", toggle, {})

local function dispatch_jump(direction, opts)
  local count = 1
  if opts.args ~= nil and opts.args ~= "" then
    count = tonumber(opts.args)
    if not count or count ~= math.floor(count) or count < 1 then
      vim.notify(("manicule: jump count must be a positive integer, got %q"):format(opts.args), vim.log.levels.ERROR)
      return
    end
  end
  require("manicule").jump(direction, { count = count })
end

vim.api.nvim_create_user_command("ManiculeNext", function(opts)
  dispatch_jump("next", opts)
end, { nargs = "?" })

vim.api.nvim_create_user_command("ManiculePrev", function(opts)
  dispatch_jump("prev", opts)
end, { nargs = "?" })

vim.keymap.set({ "n", "x" }, "<Plug>(manicule-add)", function()
  require("manicule").add()
end, { silent = true })

vim.keymap.set("n", "<Plug>(manicule-list)", function()
  require("manicule").list()
end, { silent = true })

local function jump_next()
  require("manicule").jump("next", { count = vim.v.count1 })
end

local function jump_prev()
  require("manicule").jump("prev", { count = vim.v.count1 })
end

vim.keymap.set("n", "<Plug>(manicule-next)", jump_next, { silent = true })

vim.keymap.set("n", "<Plug>(manicule-prev)", jump_prev, { silent = true })

-- Edit the first comment at/covering the cursor.
-- Manicule is buffer-agnostic, so we resolve the target record via the
-- render layer's cursor hit-test helper.
vim.keymap.set("n", "<Plug>(manicule-edit)", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = require("manicule.ui.render").record_at_cursor(bufnr)
  if not id then
    vim.notify("manicule: no comment at cursor", vim.log.levels.WARN)
    return
  end
  require("manicule").edit(id)
end, { silent = true })

-- Delete the first comment at/covering the cursor.
vim.keymap.set("n", "<Plug>(manicule-delete)", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = require("manicule.ui.render").record_at_cursor(bufnr)
  if not id then
    vim.notify("manicule: no comment at cursor", vim.log.levels.WARN)
    return
  end
  require("manicule").delete(id)
end, { silent = true })

-- Flip visuals on/off without touching the store (or show/hide the
-- review panel during a session). No default binding — the command is
-- enough for most users; expose the <Plug> for anyone who wants a keymap.
vim.keymap.set("n", "<Plug>(manicule-toggle)", toggle, { silent = true })

-- Default keymaps. The popup footer advertises `gca` / `gcd` so users
-- expect them to work out of the box. Set `vim.g.manicule_no_default_keymaps = 1`
-- before the plugin loads to opt out.
if vim.g.manicule_no_default_keymaps ~= 1 then
  vim.keymap.set("n", "gca", "<Plug>(manicule-edit)", {
    desc = "Manicule: edit comment at cursor",
  })
  vim.keymap.set("n", "gcd", "<Plug>(manicule-delete)", {
    desc = "Manicule: delete comment at cursor",
  })
  vim.keymap.set("n", "]m", jump_next, {
    desc = "Manicule: next comment",
  })
  vim.keymap.set("n", "[m", jump_prev, {
    desc = "Manicule: previous comment",
  })
end

-- Review mode commands
vim.api.nvim_create_user_command("ManiculeReview", function(opts)
  -- Schedule error notifies: on lazy-loading stubs the command is re-invoked
  -- via nvim_cmd, where an ERROR notify behaves like :echoerr and is
  -- rethrown as a "Vim:" traceback. Deferring past the command context
  -- keeps it a plain red message.
  local function notify_error(msg)
    vim.schedule(function()
      vim.notify(msg, vim.log.levels.ERROR)
    end)
  end
  local function resolve_and_start(fargs)
    local sources = require("manicule.review.sources")
    local job, err = sources.resolve(fargs, {})
    if not job then
      notify_error(err or "manicule: cannot resolve review")
      return
    end
    local ok, start_err = require("manicule.review").start(job)
    if not ok then
      notify_error(start_err)
    end
  end
  -- Bare `pr`: pick an open PR via vim.ui.select, then proceed as if
  -- `:ManiculeReview pr <n>` was typed. Intercepted BEFORE resolve —
  -- resolve is synchronous, the picker is async, and the git resolver
  -- would otherwise try (and fail) to treat "pr" as a ref.
  if #opts.fargs == 1 and opts.fargs[1] == "pr" then
    require("manicule.review.pr_picker").pick(function(number)
      resolve_and_start({ "pr", number })
    end)
    return
  end
  resolve_and_start(opts.fargs)
end, {
  nargs = "*",
  complete = function(arglead, cmdline)
    return require("manicule.review.complete").candidates(arglead, cmdline)
  end,
})

vim.api.nvim_create_user_command("ManiculeReviewNext", function()
  require("manicule.review").next()
end, {})

vim.api.nvim_create_user_command("ManiculeReviewPrev", function()
  require("manicule.review").prev()
end, {})

vim.api.nvim_create_user_command("ManiculeReviewFinish", function(opts)
  require("manicule.review").finish({ sink = opts.args ~= "" and opts.args or nil })
end, {
  nargs = "?",
  complete = function()
    return require("manicule.sinks").list()
  end,
})

vim.api.nvim_create_user_command("ManiculeReviewStop", function()
  require("manicule.review").stop()
end, {})

-- `:ManiculeReviewDiffMode` with no argument toggles split <-> unified.
vim.api.nvim_create_user_command("ManiculeReviewDiffMode", function(opts)
  require("manicule.review").set_diff_mode(opts.args)
end, {
  nargs = "?",
  complete = function(arglead)
    local out = {}
    for _, mode in ipairs({ "split", "unified" }) do
      if mode:find(arglead, 1, true) == 1 then
        table.insert(out, mode)
      end
    end
    return out
  end,
})

vim.keymap.set("n", "<Plug>(manicule-review-next)", function()
  require("manicule.review").next()
end, { silent = true })

vim.keymap.set("n", "<Plug>(manicule-review-prev)", function()
  require("manicule.review").prev()
end, { silent = true })

vim.keymap.set("n", "<Plug>(manicule-review-diff-mode)", function()
  require("manicule.review").set_diff_mode()
end, { silent = true })
