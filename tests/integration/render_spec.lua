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
  end)
end)
