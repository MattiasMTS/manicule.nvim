local H = require("helpers")

local ctx

local function setup_env(opts)
  ctx = H.setup(opts)
  H.edit_project_file(ctx, "src/display.lua", {
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

---Concatenated text of every eol virt-text extmark on `row` (0-indexed),
---in the manicule namespace. Empty string when the row carries none.
local function eol_virt_text(bufnr, row)
  local ns = require("manicule.anchor").ns
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, { details = true })
  local out = {}
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.virt_text and details.virt_text_pos == "eol" then
      for _, chunk in ipairs(details.virt_text) do
        table.insert(out, chunk[1])
      end
    end
  end
  return table.concat(out, "")
end

---True when any row of `bufnr` carries eol virt text.
local function has_any_eol_virt_text(bufnr)
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    if eol_virt_text(bufnr, row) ~= "" then
      return true
    end
  end
  return false
end

---Move the cursor and deliver the CursorMoved event the plugin's
---viewport autocmd listens for. `nvim_win_set_cursor` alone does not
---fire autocmds, so tests deliver the event explicitly — same contract
---as a real interactive movement.
local function move_cursor(bufnr, line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
end

describe("manicule display config", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("rejects an invalid ui.display value", function()
    local ok, err = pcall(require("manicule.config").setup, {
      ui = { display = "sideways" },
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("ui.display", 1, true))
    assert.is_truthy(tostring(err):find('"float", "eol", "inline", or "hidden"', 1, true))
  end)

  it("defaults to the eol display mode", function()
    assert.are.equal("eol", require("manicule.config").get().ui.display)
    assert.are.equal("eol", require("manicule.ui.render").display_mode())
  end)

  it("rejects an unknown runtime mode without changing the current one", function()
    local render = require("manicule.ui.render")
    local mode, err = render.set_display_mode("bogus")
    assert.is_nil(mode)
    assert.is_truthy(tostring(err):find('"float", "eol", "inline", or "hidden"', 1, true))
    assert.are.equal("eol", render.display_mode())
  end)
end)

describe("manicule display command", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("completes the four display modes", function()
    vim.cmd("runtime plugin/manicule.lua")
    local all = vim.fn.getcompletion("ManiculeDisplay ", "cmdline")
    table.sort(all)
    assert.are.same({ "eol", "float", "hidden", "inline" }, all)
    assert.are.same({ "float" }, vim.fn.getcompletion("ManiculeDisplay f", "cmdline"))
  end)

  it("exposes <Plug>(manicule-display-cycle)", function()
    vim.cmd("runtime plugin/manicule.lua")
    assert.is_true(vim.fn.maparg("<Plug>(manicule-display-cycle)", "n") ~= "")
  end)

  it("cycles float → eol → inline → hidden → float with live re-render", function()
    vim.cmd("runtime plugin/manicule.lua")
    local render = require("manicule.ui.render")
    local bufnr = vim.api.nvim_get_current_buf()

    -- Keep the cursor OFF the comment line so eol mode stays collapsed.
    move_cursor(bufnr, 3)
    require("manicule").add({
      body = "cycle note",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, ...)
      table.insert(notifications, tostring(msg))
      return original_notify(msg, ...)
    end

    -- Default eol: collapsed marker, no popup.
    assert.are.equal("eol", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 0))
    assert.is_truthy(eol_virt_text(bufnr, 0):find("cycle note", 1, true))

    -- Explicit argument: float shows the popup and drops the marker.
    vim.cmd("ManiculeDisplay float")
    assert.are.equal("float", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 1))
    assert.are.equal("", eol_virt_text(bufnr, 0))

    -- Bare command cycles: float → eol.
    vim.cmd("ManiculeDisplay")
    assert.are.equal("eol", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 0))
    assert.is_truthy(eol_virt_text(bufnr, 0):find("cycle note", 1, true))

    -- eol → inline (falls back to float popups for now).
    vim.cmd("ManiculeDisplay")
    assert.are.equal("inline", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 1))

    -- inline → hidden: no popups, no virt text, anchors survive.
    vim.cmd("ManiculeDisplay")
    assert.are.equal("hidden", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 0))
    assert.is_false(has_any_eol_virt_text(bufnr))
    assert.is_true(next(render.mark_ids_for_buffer(bufnr)) ~= nil)

    -- hidden → float: wraparound, popup returns.
    vim.cmd("ManiculeDisplay")
    assert.are.equal("float", render.display_mode())
    assert.is_true(wait_for_popup_count("cycle note", 1))

    vim.notify = original_notify

    -- Every switch announced with the one-line notify.
    local announced = table.concat(notifications, "\n")
    for _, mode in ipairs({ "float", "eol", "inline", "hidden" }) do
      assert.is_truthy(announced:find("manicule: display = " .. mode, 1, true))
    end
  end)
end)

describe("manicule eol display mode", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("collapses to eol virt text with the truncated body and no popup", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("manicule").add({
      body = "first line of the note\nsecond line stays hidden",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("manicule").list({ _quiet = true })
    local short = tostring(records[1].id):sub(1, 6)

    local text = eol_virt_text(bufnr, 0)
    assert.is_truthy(text:find("●", 1, true))
    assert.is_truthy(text:find("c" .. short, 1, true))
    assert.is_truthy(text:find("first line of the note", 1, true))
    -- Only the first body line renders collapsed.
    assert.is_nil(text:find("second line", 1, true))
    -- Single comment on the line: no n/m counter.
    assert.is_nil(text:find("1/1", 1, true))
    -- No popup window while collapsed.
    assert.is_true(wait_for_popup_count("first line of the note", 0))
  end)

  it("expands the real popup on the cursor line and closes it off-line", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("manicule").add({
      body = "expand me now",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    assert.is_true(wait_for_popup_count("expand me now", 0))

    -- Cursor onto the comment line: the full float-mode popup opens.
    move_cursor(bufnr, 2)
    assert.is_true(wait_for_popup_count("expand me now", 1))
    local winid = floating_windows_containing("expand me now")[1]
    assert.is_truthy(popup_title(winid):find("1/1", 1, true))
    -- Edit/delete keymaps stay reachable exactly as in float mode: the
    -- cursor hit-test they route through resolves the record here.
    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(records[1].id, require("manicule.ui.render").record_at_cursor(bufnr))

    -- Cursor off the line: popup closes, collapsed marker stays.
    move_cursor(bufnr, 1)
    assert.is_true(wait_for_popup_count("expand me now", 0))
    assert.is_truthy(eol_virt_text(bufnr, 1):find("expand me now", 1, true))
  end)

  it("shows the stack position collapsed and expands the vertical stack", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("manicule").add({
      body = "stack alpha",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    require("manicule").add({
      body = "stack beta",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })

    -- Collapsed: both markers carry their same-line stack position.
    local text = eol_virt_text(bufnr, 1)
    assert.is_truthy(text:find("1/2", 1, true))
    assert.is_truthy(text:find("2/2", 1, true))
    assert.is_true(wait_for_popup_count("stack alpha", 0))

    -- Expanded: the same vertical stack float mode renders.
    move_cursor(bufnr, 2)
    assert.is_true(wait_for_popup_count("stack alpha", 1))
    assert.is_true(wait_for_popup_count("stack beta", 1))
    local first = floating_windows_containing("stack alpha")[1]
    local second = floating_windows_containing("stack beta")[1]
    local first_row = tonumber(vim.api.nvim_win_get_config(first).row) or 0
    local second_row = tonumber(vim.api.nvim_win_get_config(second).row) or 0
    assert.is_true(math.abs(first_row - second_row) >= 3)
  end)

  it("keeps the expanded popup open while the comment editor is up", function()
    local bufnr = vim.api.nvim_get_current_buf()
    require("manicule").add({
      body = "edit without closing",
      range = { start = { 1, 0 }, end_ = { 1, 0 } },
    })
    move_cursor(bufnr, 2)
    assert.is_true(wait_for_popup_count("edit without closing", 1))
    local popup_winid = floating_windows_containing("edit without closing")[1]

    -- Open the comment editor from the expanded popup's record. Focus
    -- moves into a manicule float; the BufLeave/WinLeave editor
    -- exception applies in eol mode too, so the popup must not close
    -- mid-edit. (The editor float shows the same body text, so assert
    -- on the popup's winid rather than a window count.)
    local records = require("manicule").list({ _quiet = true })
    require("manicule").edit(records[1].id)
    assert.is_true(vim.wait(1000, function()
      return require("manicule.ui.editor").is_active()
    end, 10))

    vim.wait(50, function()
      return false
    end, 10)
    assert.is_true(vim.api.nvim_win_is_valid(popup_winid))

    require("manicule.ui.editor").close_active()
    assert.is_true(vim.wait(1000, function()
      return not require("manicule.ui.editor").is_active()
    end, 10))
  end)

  it("truncates the collapsed body to the leftover window width", function()
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 3)
    require("manicule").add({
      body = string.rep("x", 300),
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local win_width = vim.api.nvim_win_get_width(0)
    local line_width = vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    local text = eol_virt_text(bufnr, 0)
    assert.is_truthy(text:find("…", 1, true))
    assert.is_true(vim.fn.strdisplaywidth(text) <= win_width - line_width - 1)
  end)

  it("degrades to a bare marker when the line leaves no room", function()
    local win_width = vim.api.nvim_win_get_width(0)
    H.edit_project_file(ctx, "src/long.lua", {
      "-- " .. string.rep("y", win_width - 10),
      "return true",
    })
    local bufnr = vim.api.nvim_get_current_buf()
    move_cursor(bufnr, 2)
    require("manicule").add({
      body = "body that cannot fit",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })
    local records = require("manicule").list({ _quiet = true })
    local short = tostring(records[1].id):sub(1, 6)

    local text = eol_virt_text(bufnr, 0)
    assert.are.equal("● c" .. short, text)
  end)
end)
