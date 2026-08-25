local H = require("helpers")

local ctx

local function setup_env()
  -- Several workflows assert on float popups; the shipped default is
  -- `ui.display = "eol"`, so opt into float mode explicitly.
  ctx = H.setup({ ui = { display = "float" } })
  H.edit_project_file(ctx, "src/example.lua", {
    "local value = 1",
    "return value",
  })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

local function floating_windows_containing(text)
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local cfg = vim.api.nvim_win_get_config(winid)
      if cfg.relative and cfg.relative ~= "" then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local lines = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if lines:find(text, 1, true) then
          table.insert(wins, winid)
        end
      end
    end
  end
  return wins
end

local function wait_for_popup_count(text, expected)
  return vim.wait(1000, function()
    return #floating_windows_containing(text) == expected
  end, 10)
end

local function new_store_client()
  return dofile(vim.fn.getcwd() .. "/lua/manicule/store.lua")
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

  it("jumps between current-buffer comments with commands and default maps", function()
    vim.cmd("runtime plugin/manicule.lua")
    H.edit_project_file(ctx, "src/navigation.lua", {
      "local one = 1",
      "local two = 2",
      "local three = 3",
      "return one + two + three",
    })

    local manicule = require("manicule")
    manicule.add({
      body = "first jump target",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    manicule.add({
      body = "second jump target",
      range = { start = { 2, 0 }, end_ = { 2, 0 } },
    })
    manicule.add({
      body = "third jump target",
      range = { start = { 3, 0 }, end_ = { 3, 0 } },
    })

    assert.are.equal("Manicule: next comment", vim.fn.maparg("]m", "n", false, true).desc)
    assert.are.equal("Manicule: previous comment", vim.fn.maparg("[m", "n", false, true).desc)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_true(manicule.jump("next"))
    assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))

    assert.is_true(manicule.jump("prev"))
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))

    vim.cmd("ManiculeNext 2")
    assert.are.same({ 4, 0 }, vim.api.nvim_win_get_cursor(0))

    vim.cmd("ManiculePrev")
    assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("deletes a project record through the real manicule quickfix window", function()
    vim.cmd("runtime plugin/manicule.lua")
    local events, stop_capture = H.capture_events({ "ManiculeDeleted" })

    require("manicule").add({
      body = "delete from qf",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #records)

    vim.cmd("ManiculeList")

    local quickfix = require("manicule.ui.quickfix")
    local qf_winid = quickfix.is_manicule_qf_open()
    assert.is_truthy(qf_winid)
    vim.api.nvim_set_current_win(qf_winid)

    assert.are.equal("quickfix", vim.bo.buftype)
    local locator = quickfix.record_locator_at_cursor()
    assert.is_truthy(locator)
    assert.are.equal(records[1].id, locator.id)
    assert.are.equal("project", locator.scope)
    assert.are.equal(ctx.root, locator.project_root)

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("dd", true, false, true), "mx", false)

    assert.is_true(vim.wait(1000, function()
      return #require("manicule.store").all(ctx.root) == 0 and #vim.fn.getqflist() == 0
    end, 10))
    assert.are.equal("ManiculeDeleted", events[1].pattern)
    assert.are.equal(records[1].id, events[1].data.id)

    stop_capture()
  end)

  it("keeps quickfix keymaps off location-list buffers while a manicule list is set", function()
    -- Count buffer-local normal-mode maps installed by
    -- quickfix_keymaps.attach — all desc'd "Manicule: …".
    local function manicule_map_count(bufnr)
      local count = 0
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if type(map.desc) == "string" and map.desc:find("Manicule:", 1, true) then
          count = count + 1
        end
      end
      return count
    end

    -- A manicule-titled GLOBAL quickfix list, as an active review
    -- session leaves behind.
    local path = ctx.root .. "/src/example.lua"
    vim.fn.setqflist({}, " ", {
      title = "manicule-review (1/2)",
      items = { { filename = path, lnum = 1, text = "review entry" } },
    })

    -- A location list is a different list entirely: its qf buffer must
    -- not inherit manicule's dd/ce/u/<C-r> maps.
    vim.fn.setloclist(0, { { filename = path, lnum = 1, text = "loc entry" } })
    vim.cmd("lopen")
    local loclist_win = vim.api.nvim_get_current_win()
    local loclist_buf = vim.api.nvim_win_get_buf(loclist_win)
    assert.are.equal(1, vim.fn.getwininfo(loclist_win)[1].loclist)
    assert.are.equal(0, manicule_map_count(loclist_buf), "manicule quickfix maps leaked onto a location-list buffer")
    vim.cmd("lclose")

    -- The real quickfix window showing the manicule-titled list still
    -- gets the maps.
    vim.cmd("copen")
    local qf_win = vim.api.nvim_get_current_win()
    local qf_buf = vim.api.nvim_win_get_buf(qf_win)
    assert.are.equal(0, vim.fn.getwininfo(qf_win)[1].loclist)
    assert.is_true(manicule_map_count(qf_buf) > 0, "manicule maps missing from the manicule quickfix buffer")
    vim.cmd("cclose")
  end)

  it("edits a project record through quickfix and repaints the source popup", function()
    vim.cmd("runtime plugin/manicule.lua")

    require("manicule").add({
      body = "edit from qf before",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("edit from qf before", 1))

    vim.cmd("ManiculeList")
    local quickfix = require("manicule.ui.quickfix")
    local qf_winid = quickfix.is_manicule_qf_open()
    assert.is_truthy(qf_winid)
    vim.api.nvim_set_current_win(qf_winid)

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ce", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      return require("manicule.ui.editor").is_active()
    end, 10))

    local editor_bufnr = vim.api.nvim_get_current_buf()
    vim.bo[editor_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, { "edit from qf after" })
    vim.bo[editor_bufnr].modifiable = false
    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)

    assert.is_true(vim.wait(1000, function()
      local records = require("manicule.store").all(ctx.root)
      return records[1] and records[1].body == "edit from qf after"
    end, 10))
    assert.is_true(vim.wait(1000, function()
      return not require("manicule.ui.editor").is_active()
    end, 10))

    assert.is_true(wait_for_popup_count("edit from qf before", 0))
    assert.is_true(wait_for_popup_count("edit from qf after", 1))
    assert.is_true(vim.wait(1000, function()
      local qf = vim.fn.getqflist()
      return #qf == 1 and qf[1].text:find("edit from qf after", 1, true) ~= nil
    end, 10))
  end)

  it("uses insert enter for newlines and normal enter for submitting the comment editor", function()
    vim.cmd("runtime plugin/manicule.lua")

    vim.cmd("ManiculeAdd")
    assert.is_true(vim.wait(1000, function()
      return require("manicule.ui.editor").is_active()
    end, 10))
    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("iline one<CR>line two", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      return lines[1] == "line one" and lines[2] == "line two"
    end, 10))
    assert.is_true(require("manicule.ui.editor").is_active())

    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      return not require("manicule.ui.editor").is_active()
    end, 10))

    assert.is_true(vim.wait(1000, function()
      return #require("manicule").list({ _quiet = true }) == 1
    end, 10))
    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #records)
    assert.are.equal("line one\nline two", records[1].body)
  end)

  it("cancels and discards the comment editor when focus leaves it", function()
    vim.cmd("runtime plugin/manicule.lua")
    local anchor_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(anchor_win)

    vim.cmd("ManiculeAdd")
    assert.is_true(vim.wait(1000, function()
      return require("manicule.ui.editor").is_active()
    end, 10))

    local editor_bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, { "discard this draft" })
    vim.api.nvim_set_current_win(target_win)

    assert.is_true(vim.wait(1000, function()
      return not require("manicule.ui.editor").is_active()
    end, 10))
    assert.are.equal(target_win, vim.api.nvim_get_current_win())
    assert.are.equal(0, #require("manicule").list({ _quiet = true }))
  end)

  it("keeps insert enter as newline when other plugins map enter", function()
    vim.cmd("runtime plugin/manicule.lua")
    local augroup = vim.api.nvim_create_augroup("ManiculeTestEditorEnterConflict", { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = augroup,
      once = true,
      callback = function(args)
        vim.keymap.set("i", "<CR>", function()
          vim.g.manicule_test_conflicting_cr = true
        end, { buffer = args.buf })
      end,
    })

    vim.cmd("ManiculeAdd")
    assert.is_true(vim.wait(1000, function()
      local map = vim.fn.maparg("<CR>", "i", false, true)
      return type(map) == "table" and map.rhs == "<CR>"
    end, 10))
    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("iconflict first<CR>conflict second", true, false, true),
      "mx",
      false
    )
    assert.is_true(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      return lines[1] == "conflict first" and lines[2] == "conflict second"
    end, 10))
    assert.is_nil(vim.g.manicule_test_conflicting_cr)

    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
    assert.is_true(vim.wait(1000, function()
      return #require("manicule").list({ _quiet = true }) == 1
    end, 10))
    local records = require("manicule").list({ _quiet = true })
    assert.are.equal("conflict first\nconflict second", records[1].body)
  end)

  it("keeps existing popups visible while the add editor is open", function()
    require("manicule").add({
      body = "visible while adding",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("visible while adding", 1))

    require("manicule").add({
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    assert.is_true(vim.wait(1000, function()
      return require("manicule.ui.editor").is_active()
    end, 10))

    vim.wait(50, function()
      return false
    end, 10)
    assert.is_true(wait_for_popup_count("visible while adding", 1))

    require("manicule.ui.editor").close_active()
    assert.is_true(vim.wait(1000, function()
      return not require("manicule.ui.editor").is_active()
    end, 10))
  end)

  it("keeps other visible popups rendered after deleting one comment", function()
    require("manicule").add({
      body = "delete only this popup",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("manicule").add({
      body = "keep this popup visible",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    assert.is_true(wait_for_popup_count("delete only this popup", 1))
    assert.is_true(wait_for_popup_count("keep this popup visible", 1))

    local records = require("manicule").list({ _quiet = true })
    local delete_id
    for _, record in ipairs(records) do
      if record.body == "delete only this popup" then
        delete_id = record.id
      end
    end
    assert.is_truthy(delete_id)

    require("manicule").delete(delete_id)

    assert.is_true(wait_for_popup_count("delete only this popup", 0))
    assert.is_true(wait_for_popup_count("keep this popup visible", 1))
  end)

  it("polls the SQLite WAL store and renders comments from another client", function()
    require("manicule").setup({
      store = {
        dir = ctx.state .. "/",
        format = "json",
        canonicalize_symlinks = false,
        poll_interval_ms = 20,
      },
      sinks = {
        clipboard = false,
        cmux = false,
      },
    })
    local store_a = require("manicule.store")
    local store_b = new_store_client()
    local uri = require("manicule.uri").for_bufnr(0)

    assert.are.equal(0, #store_a.load(ctx.root))
    store_b.put(ctx.root, {
      id = "external-1",
      uri = uri,
      scope = "project",
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "from another nvim",
      author = "",
      created_at = 1,
      updated_at = 1,
      resolved = false,
      meta = {},
    })
    assert.is_true(store_b.save(ctx.root))

    assert.is_true(wait_for_popup_count("from another nvim", 1))
    assert.are.equal(1, #store_a.all(ctx.root))
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

  it("paints the buffer in a single pass when a comment is added", function()
    local manicule = require("manicule")
    -- Drain callbacks scheduled by setup's edit (BufWinEnter attach).
    vim.wait(50, function()
      return false
    end, 10)

    local bufnr = vim.api.nvim_get_current_buf()
    local adapter = require("manicule.adapter")
    local original_identify = adapter.identify
    local identify_calls = 0
    adapter.identify = function(b, ...)
      if b == bufnr then
        identify_calls = identify_calls + 1
      end
      return original_identify(b, ...)
    end

    -- With a body, add() runs synchronously — nothing scheduled can
    -- inflate the count before the spy is removed.
    manicule.add({
      body = "single pass",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    adapter.identify = original_identify

    -- finalize_add resolves identity twice itself (record build + the
    -- invariant canary); the repaint must add exactly ONE more pass —
    -- not two (reconcile + viewport each re-identifying and re-reading
    -- the store).
    assert.are.equal(3, identify_calls)
  end)

  it("repaints buffers once per consuming send, not once per cleared record", function()
    local calls = H.register_fake_sink("consume-batch", { clear_on_success = true })
    local manicule = require("manicule")
    for i = 1, 3 do
      manicule.add({
        body = "batch clear " .. i,
        range = { start = { i - 1, 0 }, end_ = { i - 1, 0 } },
      })
    end
    assert.are.equal(3, #manicule.list({ _quiet = true }))

    -- Drain callbacks already scheduled by the adds (and by earlier
    -- tests in this Neovim instance) so the counter below only sees
    -- work caused by the send itself.
    vim.wait(50, function()
      return false
    end, 10)

    local target_bufnr = vim.api.nvim_get_current_buf()
    local render = require("manicule.ui.render")
    local original_reconcile = render.reconcile
    local reconcile_calls = 0
    render.reconcile = function(bufnr, ...)
      if bufnr == target_bufnr then
        reconcile_calls = reconcile_calls + 1
      end
      return original_reconcile(bufnr, ...)
    end

    local events, stop_capture = H.capture_events({ "ManiculeDeleted" })
    manicule.send("consume-batch")
    render.reconcile = original_reconcile

    assert.are.equal(1, #calls)
    assert.are.equal(0, #manicule.list({ _quiet = true }))
    -- Event semantics unchanged: one ManiculeDeleted per cleared record.
    assert.are.equal(3, #events)
    -- Repaint batched: ONE refresh sweep after the clear loop, not one
    -- editor-wide repaint per deleted record.
    assert.are.equal(1, reconcile_calls)

    stop_capture()
  end)

  it("coalesces a synchronous burst of mutation events into one quickfix refresh", function()
    vim.cmd("runtime plugin/manicule.lua")
    require("manicule").add({
      body = "coalesce me",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    vim.cmd("ManiculeList")
    local quickfix = require("manicule.ui.quickfix")
    assert.is_truthy(quickfix.is_manicule_qf_open())

    -- Drain callbacks already scheduled by the add (and by earlier
    -- tests in this Neovim instance) so the counter below only sees
    -- refreshes caused by the burst fired here.
    vim.wait(50, function()
      return false
    end, 10)

    local original_refresh = quickfix.refresh
    local refresh_calls = 0
    quickfix.refresh = function(...)
      refresh_calls = refresh_calls + 1
      return original_refresh(...)
    end

    -- Three synchronous events, zero event-loop ticks in between — the
    -- exact burst shape a bulk mutation produces.
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("User", { pattern = "ManiculeEdited" })
    end
    assert.is_true(vim.wait(1000, function()
      return refresh_calls > 0
    end, 10))
    -- Drain any additional scheduled callbacks before counting.
    vim.wait(50, function()
      return false
    end, 10)
    quickfix.refresh = original_refresh

    assert.are.equal(1, refresh_calls)
  end)

  it("clears the pre-rename URI snapshot when the buffer unloads before BufFilePost lands", function()
    local path, bufnr = H.edit_project_file(ctx, "src/rename_me.lua", { "local x = 1" })
    -- `:file` fires BufFilePre (URI snapshotted) then BufFilePost, whose
    -- handler is deferred via vim.schedule. Wipe the buffer BEFORE the
    -- schedule drains: the deferred handler early-returns on the dead
    -- buffer, so only the BufUnload/BufDelete handler can clear the
    -- snapshot — without it the bufnr slot leaks a stale URI.
    vim.cmd("file " .. vim.fn.fnameescape(path .. ".renamed"))
    vim.cmd("bwipeout! " .. bufnr)
    vim.wait(100, function()
      return false
    end, 10)
    assert.is_nil(require("manicule")._pre_rename_uris()[bufnr])
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
      pre_text = "Custom review rules",
      post_text = "Report back with the M IDs you handled.",
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
    -- The cmux send path is asynchronous (vim.system callbacks); wait for
    -- the full Added -> Sent -> Deleted event chain before asserting.
    vim.wait(2000, function()
      return #events >= 3
    end)
    vim.notify = original_notify

    assert.are.equal(0, #require("manicule").list({ _quiet = true }))
    local log_lines = vim.fn.readfile(log)
    local log_text = table.concat(log_lines, "\n")
    assert.is_truthy(log_text:find("set%-buffer\tmanicule%-", 1, false))
    assert.is_truthy(log_text:find("paste%-buffer\tsurface:2\tmanicule%-", 1, false))
    assert.is_truthy(log_text:find("Manicule review (1 comment):", 1, true))
    assert.is_truthy(log_text:find("Custom review rules", 1, true))
    assert.is_truthy(log_text:find("## M1", 1, true))
    assert.is_truthy(log_text:find("send this to the agent", 1, true))
    assert.is_truthy(log_text:find("Report back with the M IDs you handled.", 1, true))
    assert.is_nil(log_text:find("send\tsurface:2", 1, true))
    assert.is_truthy(log_text:find("key\tsurface:2\tenter", 1, true))

    assert.are.equal("ManiculeAdded", events[1].pattern)
    assert.are.equal(records[1].id, events[1].data.id)
    assert.are.equal("ManiculeSent", events[2].pattern)
    assert.are.equal("cmux", events[2].data.sink)
    assert.is_true(events[2].data.ok)
    assert.are.equal("ManiculeDeleted", events[3].pattern)

    stop_capture()
  end)
end)
