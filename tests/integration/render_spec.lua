local H = require("helpers")

local ctx

local function setup_env()
  ctx = H.setup()
  H.edit_project_file(ctx, "src/render.lua", {
    "local value = 1",
    "value = value + 1",
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

local function popup_title(winid)
  local title = vim.api.nvim_win_get_config(winid).title
  if type(title) == "string" then
    return title
  end
  if type(title) == "table" then
    local parts = {}
    for _, item in ipairs(title) do
      if type(item) == "string" then
        table.insert(parts, item)
      elseif type(item) == "table" and type(item[1]) == "string" then
        table.insert(parts, item[1])
      end
    end
    return table.concat(parts, "")
  end
  return ""
end

-- Wait until a popup containing `text` carries a title that includes
-- `needle`. Switching back to an already-loaded buffer re-renders its
-- popups (and thus their counters) asynchronously, so the title trails
-- the popup-window count by a tick — poll instead of reading it once.
local function wait_for_popup_title(text, needle)
  return vim.wait(1000, function()
    local winid = floating_windows_containing(text)[1]
    return winid ~= nil and popup_title(winid):find(needle, 1, true) ~= nil
  end, 10)
end

-- Return true only if a popup containing `text` stays present for the
-- whole observation window. `vim.wait` returns true when the predicate
-- fires; we invert it so a `false` here means "never disappeared". This
-- catches a transient hide (count momentarily 0) even when a later
-- refresh re-shows the popup.
local function popup_stays_visible(text)
  local vanished = vim.wait(150, function()
    return #floating_windows_containing(text) == 0
  end, 5)
  return not vanished
end

local function popup_screen_top(winid)
  local cfg = vim.api.nvim_win_get_config(winid)
  local bufpos = cfg.bufpos or { 0, 0 }
  return (tonumber(bufpos[1]) or 0) + (tonumber(cfg.row) or 0)
end

local function popup_screen_bottom(winid)
  local cfg = vim.api.nvim_win_get_config(winid)
  return popup_screen_top(winid) + (tonumber(cfg.height) or 1) + 1
end

describe("manicule render lifecycle", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("hides, restores, and clears popup state without losing anchors", function()
    local manicule = require("manicule")
    local render = require("manicule.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()

    manicule.add({
      body = "render note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = manicule.list({ _quiet = true })
    assert.are.equal(1, #records)

    local id = records[1].id
    assert.is_truthy(render.mark_ids_for_buffer(bufnr)[id])
    assert.is_true(wait_for_popup_count("render note", 1))
    assert.is_truthy(popup_title(floating_windows_containing("render note")[1]):find("1/1", 1, true))

    render.hide_all_popups(bufnr)
    assert.is_true(wait_for_popup_count("render note", 0))
    assert.is_truthy(render.mark_ids_for_buffer(bufnr)[id])

    render.update_viewport_popups(bufnr, records)
    assert.is_true(wait_for_popup_count("render note", 1))

    render.hide()
    assert.is_true(render.is_hidden())
    assert.is_true(wait_for_popup_count("render note", 0))
    assert.is_truthy(render.mark_ids_for_buffer(bufnr)[id])

    render.show()
    assert.is_false(render.is_hidden())
    assert.is_true(wait_for_popup_count("render note", 1))

    render.clear_buffer(bufnr)
    assert.are.same({}, render.mark_ids_for_buffer(bufnr))
    assert.is_true(wait_for_popup_count("render note", 0))
  end)

  it("keeps popups while the source buffer stays visible but loses focus", function()
    local manicule = require("manicule")
    local source_win = vim.api.nvim_get_current_win()

    manicule.add({
      body = "some note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("some note", 1))

    -- Open the quickfix list: a new window takes focus while the source
    -- window stays on screen. BufLeave/WinLeave fire on the source buffer,
    -- but its popup must persist — uninterrupted — because the buffer is
    -- still visible. The pre-fix behavior hid the popup on the focus-loss
    -- tick (count momentarily 0), so assert it never vanishes, not merely
    -- that it eventually reappears.
    vim.cmd("botright copen")
    assert.is_true(popup_stays_visible("some note"))
    assert.is_true(wait_for_popup_count("some note", 1))

    -- Genuine off-screen case: replacing the buffer in the source window so
    -- it is no longer displayed anywhere must hide the popups.
    vim.cmd("cclose")
    vim.api.nvim_set_current_win(source_win)
    vim.cmd("enew")
    assert.is_true(wait_for_popup_count("some note", 0))
  end)

  it(":ManiculeToggle emits visibility events and rebuilds real popup windows", function()
    vim.cmd("runtime plugin/manicule.lua")
    local events, stop_capture = H.capture_events({ "ManiculeVisibility" })

    require("manicule").add({
      body = "toggle note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("toggle note", 1))

    vim.cmd("ManiculeToggle")
    assert.is_true(require("manicule.ui.render").is_hidden())
    assert.is_true(wait_for_popup_count("toggle note", 0))

    vim.cmd("ManiculeToggle")
    assert.is_false(require("manicule.ui.render").is_hidden())
    assert.is_true(wait_for_popup_count("toggle note", 1))

    assert.are.equal(2, #events)
    assert.is_true(events[1].data.hidden)
    assert.is_false(events[2].data.hidden)

    stop_capture()
  end)

  it("stacks same-line popups by popup height", function()
    require("manicule").add({
      body = "stack top\nwith another line",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("manicule").add({
      body = "stack second",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    assert.is_true(wait_for_popup_count("stack top", 1))
    assert.is_true(wait_for_popup_count("stack second", 1))

    local first = floating_windows_containing("stack top")[1]
    local second = floating_windows_containing("stack second")[1]
    assert.is_truthy(first)
    assert.is_truthy(second)

    local first_row = tonumber(vim.api.nvim_win_get_config(first).row) or 0
    local second_row = tonumber(vim.api.nvim_win_get_config(second).row) or 0
    assert.is_true(math.abs(first_row - second_row) >= 3)

    local titles = {
      popup_title(first),
      popup_title(second),
    }
    table.sort(titles)
    assert.is_truthy(table.concat(titles, "\n"):find("1/2", 1, true))
    assert.is_truthy(table.concat(titles, "\n"):find("2/2", 1, true))
  end)

  it("numbers and separates adjacent visible popups", function()
    require("manicule").add({
      body = "adjacent first",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    require("manicule").add({
      body = "adjacent second",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    assert.is_true(wait_for_popup_count("adjacent first", 1))
    assert.is_true(wait_for_popup_count("adjacent second", 1))

    local first = floating_windows_containing("adjacent first")[1]
    local second = floating_windows_containing("adjacent second")[1]
    assert.is_truthy(first)
    assert.is_truthy(second)

    assert.is_truthy(popup_title(first):find("1/2", 1, true))
    assert.is_truthy(popup_title(second):find("2/2", 1, true))
    assert.is_true(popup_screen_top(second) > popup_screen_bottom(first))
  end)

  it("prunes an orphaned popup but keeps the tracked one", function()
    local manicule = require("manicule")
    local render = require("manicule.ui.render")

    manicule.add({
      body = "orphan target",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("orphan target", 1))

    -- The tracked popup's winid lives on the record's handle.
    local records = manicule.list({ _quiet = true })
    local tracked_winid = floating_windows_containing("orphan target")[1]
    assert.is_truthy(tracked_winid)

    -- Simulate a leaked/reloaded float: a separate floating window over a
    -- scratch buffer that shows the same text and carries the
    -- `manicule_popup` win-var, but which no handle tracks.
    local orphan_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(orphan_buf, 0, -1, false, { "orphan target" })
    local orphan_win = vim.api.nvim_open_win(orphan_buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 1,
      style = "minimal",
    })
    vim.api.nvim_win_set_var(orphan_win, "manicule_popup", true)
    assert.is_true(wait_for_popup_count("orphan target", 2))

    render.prune_orphan_popups()

    -- Only the tracked popup survives — by winid, not just by count.
    assert.is_true(wait_for_popup_count("orphan target", 1))
    assert.is_false(vim.api.nvim_win_is_valid(orphan_win))
    assert.are.equal(tracked_winid, floating_windows_containing("orphan target")[1])

    -- A follow-up viewport update still shows the tracked popup.
    render.update_viewport_popups(vim.api.nvim_get_current_buf(), records)
    assert.is_true(wait_for_popup_count("orphan target", 1))
  end)

  it("never closes a tracked popup when pruning", function()
    local manicule = require("manicule")
    local render = require("manicule.ui.render")

    manicule.add({
      body = "keep me",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("keep me", 1))

    render.prune_orphan_popups()
    assert.is_true(wait_for_popup_count("keep me", 1))
  end)

  it("is a no-op when there are no tagged floats", function()
    local render = require("manicule.ui.render")
    -- No comments added: no tagged floats exist, so pruning must not error
    -- and must not touch any window.
    local before = #vim.api.nvim_list_wins()
    render.prune_orphan_popups()
    assert.are.equal(before, #vim.api.nvim_list_wins())
  end)

  it("handles a float open failure without throwing or leaking a scratch buffer", function()
    local manicule = require("manicule")
    local render = require("manicule.ui.render")
    local float = require("manicule.ui.float")
    local bufnr = vim.api.nvim_get_current_buf()

    manicule.add({
      body = "open failure note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = manicule.list({ _quiet = true })

    -- Simulate `nvim_open_win` throwing inside `open_or_reconfigure`
    -- (the pcall there returns nil on failure). `render_comment_popup`
    -- must bail cleanly: no popup, no thrown error, and the orphaned
    -- scratch buffer must not accumulate across repeated renders.
    local original = float.open_or_reconfigure
    float.open_or_reconfigure = function()
      return nil
    end

    local function count_listed_bufs()
      return #vim.api.nvim_list_bufs()
    end

    local ok = pcall(function()
      render.update_viewport_popups(bufnr, records)
      render.update_viewport_popups(bufnr, records)
    end)
    local bufs_after_two = count_listed_bufs()
    local ok2 = pcall(function()
      render.update_viewport_popups(bufnr, records)
      render.update_viewport_popups(bufnr, records)
    end)
    local bufs_after_four = count_listed_bufs()

    float.open_or_reconfigure = original

    assert.is_true(ok)
    assert.is_true(ok2)
    -- No popup ever appeared while the open was failing.
    assert.are.equal(0, #floating_windows_containing("open failure note"))
    -- The scratch buffer is reused, not leaked: extra render passes do
    -- not grow the buffer list.
    assert.are.equal(bufs_after_two, bufs_after_four)

    -- Recovery: with the real opener restored, the popup renders again.
    render.update_viewport_popups(bufnr, records)
    assert.is_true(wait_for_popup_count("open failure note", 1))
  end)

  it("numbers popups across project records", function()
    local first_path = H.edit_project_file(ctx, "src/a.lua", {
      "local first = true",
    })
    require("manicule").add({
      body = "project first",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local second_path = H.edit_project_file(ctx, "src/z.lua", {
      "local second = true",
    })
    require("manicule").add({
      body = "project second",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    assert.is_true(wait_for_popup_count("project second", 1))
    assert.is_true(wait_for_popup_title("project second", "2/2"))

    vim.cmd.edit(vim.fn.fnameescape(first_path))
    assert.is_true(wait_for_popup_count("project first", 1))
    assert.is_true(wait_for_popup_title("project first", "1/2"))

    vim.cmd.edit(vim.fn.fnameescape(second_path))
    assert.is_true(wait_for_popup_count("project second", 1))
    assert.is_true(wait_for_popup_title("project second", "2/2"))
  end)

  it("renders only one popup when a file is open in a same-URI codediff buffer", function()
    local manicule = require("manicule")
    local render = require("manicule.ui.render")

    -- Working-tree buffer for the file the comment anchors to.
    local lines = { "local a = 1", "return a" }
    H.edit_project_file(ctx, "src/a.lua", lines)
    local work_buf = vim.api.nvim_get_current_buf()

    manicule.add({
      body = "wow nice",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("wow nice", 1))

    -- Open a codediff buffer for the SAME file in a split. The adapter
    -- maps `codediff:///<root>///HEAD/<path>` to the working-tree URI, so
    -- both buffers resolve to the same URI and would each render the popup.
    local cd_name = ("codediff:///%s///HEAD/%s"):format(ctx.root, "src/a.lua")
    vim.cmd("vsplit")
    local cd_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(cd_buf, cd_name)
    vim.bo[cd_buf].buftype = "nofile"
    vim.api.nvim_buf_set_lines(cd_buf, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, cd_buf)

    -- Confirm the collision: codediff buffer resolves to the same URI as
    -- the working buffer — that's what makes both render the popup.
    local adapter = require("manicule.adapter")
    assert.are.equal(adapter.identify(work_buf).uri, adapter.identify(cd_buf).uri)

    -- Drive a render against the codediff buffer; before the fix this
    -- pushes the popup count to 2 (one per same-URI buffer).
    local records = manicule.list({ _quiet = true })
    render.reconcile(cd_buf, records, records)
    render.update_viewport_popups(cd_buf, records, records)
    assert.is_true(wait_for_popup_count("wow nice", 1))

    -- The dedup must survive an edit (refresh_all_loaded re-renders every
    -- loaded buffer, including both same-URI buffers).
    local original_prompt = package.loaded["manicule.ui"].prompt
    package.loaded["manicule.ui"].prompt = function(_, cb)
      cb("edited body")
    end
    local id = records[1].id
    manicule.edit(id)
    vim.wait(200, function()
      return false
    end, 10)
    package.loaded["manicule.ui"].prompt = original_prompt
    assert.is_true(wait_for_popup_count("edited body", 1))

    -- Focus-follow: switching back to the working window and refreshing
    -- its viewport keeps exactly one popup.
    vim.cmd("wincmd p")
    render.update_viewport_popups(work_buf, manicule.list({ _quiet = true }), manicule.list({ _quiet = true }))
    assert.is_true(wait_for_popup_count("edited body", 1))
  end)
end)

-- Sticky-mode regressions (#5, #6). Dedicated describe so the sticky
-- config doesn't bleed into the non-sticky specs above. `H.setup`
-- deep-merges the opts into the base config, so `ui = { sticky = true }`
-- flips the renderer into "always show a popup for every record" mode;
-- teardown resets render state + reloads the default config on the next
-- `H.setup`.
describe("manicule sticky render", function()
  before_each(function()
    ctx = H.setup({ ui = { sticky = true } })
    H.edit_project_file(ctx, "src/sticky.lua", {
      "local value = 1",
      "value = value + 1",
      "return value",
    })
  end)
  after_each(teardown_env)

  it("keeps the popup when the source buffer loses focus but stays visible (#6)", function()
    local manicule = require("manicule")
    local source_win = vim.api.nvim_get_current_win()

    manicule.add({
      body = "sticky qf note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("sticky qf note", 1))

    -- Open the quickfix list so the source window loses focus but stays on
    -- screen. Under sticky `refresh_viewport` early-returns, so the
    -- keep-branch must route through reconcile to rebuild the popup.
    vim.cmd("botright copen")
    assert.is_true(wait_for_popup_count("sticky qf note", 1))

    vim.cmd("cclose")
    vim.api.nvim_set_current_win(source_win)
  end)

  it("rebuilds the popup after the anchor window is closed (#6)", function()
    local manicule = require("manicule")

    manicule.add({
      body = "sticky split note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    assert.is_true(wait_for_popup_count("sticky split note", 1))

    -- Same buffer in two windows. The original (lower) window owns the
    -- float's `relative='win'` anchor; closing it makes Neovim auto-close
    -- the float. The WinClosed handler must rebuild the popup against the
    -- surviving window where the buffer is still visible.
    local original = vim.api.nvim_get_current_win()
    vim.cmd("split")
    assert.is_true(wait_for_popup_count("sticky split note", 1))

    vim.api.nvim_set_current_win(original)
    vim.cmd("close")
    assert.is_true(wait_for_popup_count("sticky split note", 1))
  end)

  it("does not leak an orphaned float when the buffer is wiped before the scheduled render (#5)", function()
    local manicule = require("manicule")
    local render = require("manicule.ui.render")

    -- Create a fresh, isolated buffer so wiping it can't disturb the
    -- project source buffer. Add a session-scope record to it, which
    -- schedules a sticky popup render, then wipe the buffer before the
    -- scheduled callback flushes. The stale render must be a no-op.
    local scratch = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(scratch)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "scratch line one", "scratch line two" })

    manicule.add({
      body = "sticky orphan note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    -- Wipe immediately, before flushing scheduled callbacks. clear_buffer
    -- (BufUnload/BufDelete) clears the handle, so the scheduled sticky
    -- render's liveness guard must bail without opening a float.
    vim.cmd("bwipeout! " .. scratch)

    -- Give every queued schedule a chance to run; assert no orphaned float
    -- ever appears.
    vim.wait(150, function()
      return false
    end, 10)
    assert.are.equal(0, #floating_windows_containing("sticky orphan note"))
  end)
end)
