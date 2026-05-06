local H = require("helpers")

local ctx

local function setup_env()
  ctx = H.setup()
  H.edit_project_file(ctx, "src/example.lua", {
    "local value = 1",
    "return value",
  })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

describe("manicule headless workflow", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("adds, lists, sends, and keeps comments when the sink is non-consuming", function()
    local events, stop_capture = H.capture_events({ "ManiculeAdded", "ManiculeSent" })
    local calls = H.register_fake_sink("fake")

    require("manicule").add({
      body = "review this line",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #records)
    assert.are.equal("review this line", records[1].body)
    assert.are.equal("project", records[1].scope)
    assert.are.equal(ctx.root, records[1].project_root)

    require("manicule").send("fake", nil, { target = "agent-a" })

    assert.are.equal(1, #calls)
    assert.are.equal("agent-a", calls[1].ctx.target)
    assert.are.equal(1, #calls[1].comments)
    assert.are.equal(records[1].id, calls[1].comments[1].id)
    assert.are.equal("review this line", calls[1].comments[1].body)

    local remaining = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #remaining)
    assert.are.equal(records[1].id, remaining[1].id)

    assert.are.equal("ManiculeAdded", events[1].pattern)
    assert.are.equal(records[1].id, events[1].data.id)
    assert.are.equal("ManiculeSent", events[2].pattern)
    assert.are.equal("fake", events[2].data.sink)
    assert.are.equal(1, events[2].data.count)
    assert.is_true(events[2].data.ok)

    stop_capture()
  end)

  it("can drive the command path with a fake prompt and consuming sink", function()
    vim.cmd("runtime plugin/manicule.lua")
    local events, stop_capture = H.capture_events({ "ManiculeAdded", "ManiculeSent", "ManiculeDeleted" })
    local calls = H.register_fake_sink("consume", { clear_on_success = true })
    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("from prompt")
    end

    vim.cmd("ManiculeAdd")
    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #records)
    assert.are.equal("from prompt", records[1].body)

    vim.cmd("ManiculeSend consume")

    ui.prompt = original_prompt

    assert.are.equal(1, #calls)
    assert.are.equal(1, #calls[1].comments)
    assert.are.equal("from prompt", calls[1].comments[1].body)
    assert.are.equal(0, #require("manicule").list({ _quiet = true }))

    assert.are.equal("ManiculeAdded", events[1].pattern)
    assert.are.equal("ManiculeSent", events[2].pattern)
    assert.are.equal("ManiculeDeleted", events[3].pattern)

    stop_capture()
  end)

  it("can drive add and edit through the command path", function()
    vim.cmd("runtime plugin/manicule.lua")
    local events, stop_capture = H.capture_events({ "ManiculeAdded", "ManiculeEdited" })
    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    local responses = { "initial body", "edited body" }
    ui.prompt = function(opts, cb)
      assert.is_truthy(opts.prompt:match("Comment") or opts.prompt:match("Edit"))
      cb(table.remove(responses, 1))
    end

    vim.cmd("ManiculeAdd")
    vim.cmd("ManiculeEdit 1")
    ui.prompt = original_prompt

    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #records)
    assert.are.equal("edited body", records[1].body)
    assert.are.equal(0, #responses)

    assert.are.equal("ManiculeAdded", events[1].pattern)
    assert.are.equal("initial body", events[1].data.body)
    assert.are.equal("ManiculeEdited", events[2].pattern)
    assert.are.equal(records[1].id, events[2].data.id)
    assert.are.equal("edited body", events[2].data.body)

    stop_capture()
  end)

  it("deletes a project record from the manicule quickfix buffer", function()
    require("manicule").add({
      body = "delete from qf",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local records = require("manicule").list({ _quiet = true })
    local items = require("manicule.ui.quickfix").build_items(records)
    vim.fn.setqflist({}, " ", { title = "locator test", items = items })
    vim.cmd.enew()
    vim.bo.buftype = "quickfix"

    assert.are.equal("quickfix", vim.bo.buftype)
    local locator = require("manicule.ui.quickfix").record_locator_at_cursor()
    assert.is_truthy(locator)
    assert.are.equal("project", locator.scope)
    assert.are.equal(ctx.root, locator.project_root)

    require("manicule").delete(locator.id, locator)

    assert.are.equal(0, #require("manicule.store").all(ctx.root))
  end)

  it("persists extmark movement on write", function()
    local store = require("manicule.store")
    require("manicule").add({
      body = "follow the line",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    local root = store.root()
    assert.is_truthy(root)

    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted above" })
    vim.cmd("silent write")

    store._reset()
    local reloaded = store.all(root)
    assert.are.equal(1, #reloaded)
    assert.are.equal(2, reloaded[1].range.start[1])
  end)

  it("keeps rejected add and cancelled edit side-effect free", function()
    local events, stop_capture = H.capture_events({ "ManiculeAdded", "ManiculeEdited" })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    vim.cmd("enew")
    local rejected_bufnr = vim.api.nvim_get_current_buf()
    vim.bo[rejected_bufnr].buftype = "quickfix"
    require("manicule").add({
      body = "should not persist",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    vim.notify = original_notify

    assert.are.equal(0, #require("manicule").list({ _quiet = true }))
    assert.are.equal(0, #events)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find("quickfix buffers don't accept comments", 1, true))

    H.edit_project_file(ctx, "src/example.lua", {
      "local value = 1",
      "return value",
    })
    require("manicule").add({
      body = "keep this body",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #records)

    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("")
    end
    require("manicule").edit(records[1].id)
    ui.prompt = original_prompt

    local after_cancel = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #after_cancel)
    assert.are.equal("keep this body", after_cancel[1].body)
    assert.are.equal(1, #events)
    assert.are.equal("ManiculeAdded", events[1].pattern)

    stop_capture()
  end)

  it("does not emit add events when persistence fails", function()
    local events, stop_capture = H.capture_events({ "ManiculeAdded" })
    local notifications = {}
    local store = require("manicule.store")
    local original_save = store.save
    local original_notify = vim.notify
    store.save = function()
      return false, "disk full"
    end
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    require("manicule").add({
      body = "must not emit",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    store.save = original_save
    vim.notify = original_notify

    assert.are.equal(0, #events)
    assert.are.equal(0, #require("manicule").list({ _quiet = true }))
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find("failed to persist new comment", 1, true))

    stop_capture()
  end)

  it("keeps comments when a consuming sink reports failure", function()
    local events, stop_capture = H.capture_events({ "ManiculeAdded", "ManiculeSent", "ManiculeDeleted" })
    local calls = H.register_fake_sink("fail-consume", {
      clear_on_success = true,
      ok = false,
      err = "sink exploded",
    })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    require("manicule").add({
      body = "must remain",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local before_send = require("manicule").list({ _quiet = true })
    require("manicule").send("fail-consume")
    vim.notify = original_notify

    local after_send = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #calls)
    assert.are.equal(1, #after_send)
    assert.are.equal(before_send[1].id, after_send[1].id)
    assert.are.equal("must remain", after_send[1].body)

    assert.are.equal("ManiculeAdded", events[1].pattern)
    assert.are.equal("ManiculeSent", events[2].pattern)
    assert.are.equal("fail-consume", events[2].data.sink)
    assert.is_false(events[2].data.ok)
    assert.are.equal("sink exploded", events[2].data.err)
    assert.are.equal(2, #events)

    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find('sink "fail%-consume" failed'))

    stop_capture()
  end)

  it("can send to the bundled cmux integration through a fake cmux cli", function()
    local bin, log = H.fake_cmux(ctx, {
      surfaces = {
        { id = "surface-current", ref = "surface:1", title = "manicule.nvim" },
        { id = "surface-agent", ref = "surface:2", title = "manicule.nvim" },
      },
      tree = {
        'surface:1 [terminal] "manicule.nvim" tty=ttys001 here',
        'surface:2 [terminal] "manicule.nvim" tty=ttys002',
      },
      screens = {
        ["surface:2"] = "OpenAI Codex\nContext 0 tokens\nReady",
      },
    })
    require("manicule").register_sink(require("manicule.sinks.cmux").setup({
      command = bin,
      workspace_id = "workspace-1",
      current_surface = "surface-current",
      process_fallback = false,
      agent_state_dir = ctx.state,
      clear_on_success = true,
    }))
    local events, stop_capture = H.capture_events({ "ManiculeAdded", "ManiculeSent", "ManiculeDeleted" })

    require("manicule").add({
      body = "send this to the agent",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("manicule").list({ _quiet = true })

    local original_notify = vim.notify
    vim.notify = function() end
    require("manicule").send("cmux")
    vim.notify = original_notify

    assert.are.equal(0, #require("manicule").list({ _quiet = true }))
    local log_lines = vim.fn.readfile(log)
    assert.is_truthy(table.concat(log_lines, "\n"):find("surface:2", 1, true))
    assert.is_truthy(table.concat(log_lines, "\n"):find("Manicule review (1 comment):", 1, true))
    assert.is_truthy(table.concat(log_lines, "\n"):find("send this to the agent", 1, true))

    assert.are.equal("ManiculeAdded", events[1].pattern)
    assert.are.equal(records[1].id, events[1].data.id)
    assert.are.equal("ManiculeSent", events[2].pattern)
    assert.are.equal("cmux", events[2].data.sink)
    assert.is_true(events[2].data.ok)
    assert.are.equal("ManiculeDeleted", events[3].pattern)

    stop_capture()
  end)
end)
