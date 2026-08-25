local H = require("helpers")

local ctx

local ns = vim.api.nvim_create_namespace("manicule.review.panel")

local function panel()
  return require("manicule.review.panel")
end

local function make_pairs(n)
  local files = {}
  for i = 1, n do
    local left = ctx.artifact_root .. ("/left/f%d.lua"):format(i)
    local right = ctx.root .. ("/f%d.lua"):format(i)
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.writefile({ ("return %d -- old"):format(i) }, left)
    vim.fn.writefile({ ("return %d -- new"):format(i) }, right)
    files[i] = { left = left, right = right, status = "M", path = ("f%d.lua"):format(i) }
  end
  return files
end

local function start_review(n)
  assert.is_true(require("manicule.review").start({ files = make_pairs(n or 1), label = "tabs" }))
end

local function panel_lines()
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function winbar()
  return vim.wo[assert(panel().winid(), "panel window not open")].winbar
end

---Press `lhs` in the panel window on `row` THROUGH buffer-local maps.
local function press_in_panel(row, lhs)
  local winid = assert(panel().winid(), "panel window not open")
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, "x", false)
end

---Content extmarks on `row` (0-indexed) using highlight group `hl`.
local function span_marks(row, hl)
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    if mark[2] == row and mark[4].hl_group == hl then
      table.insert(found, mark)
    end
  end
  return found
end

---A minimal valid tab spec, fields overridable per test.
local function tab_spec(overrides)
  local spec = {
    name = "checks",
    title = "Checks",
    build = function()
      return { { text = "one check row" } }
    end,
  }
  for k, v in pairs(overrides or {}) do
    spec[k] = v
  end
  return spec
end

describe("manicule panel tab registry", function()
  before_each(function()
    ctx = H.setup()
    panel()._reset_tabs()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    panel()._reset_tabs()
    H.teardown(ctx)
    ctx = nil
  end)

  it("validates the spec: name, title, build, duplicates, builtins", function()
    local p = panel()
    local ok, err = pcall(p.register_tab, { title = "T", build = function() end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("name", 1, true), tostring(err))

    ok, err = pcall(p.register_tab, { name = "x", build = function() end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("title", 1, true), tostring(err))

    ok, err = pcall(p.register_tab, { name = "x", title = "X" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("build", 1, true), tostring(err))

    p.register_tab(tab_spec())
    ok, err = pcall(p.register_tab, tab_spec())
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find('panel tab "checks" is already registered', 1, true), tostring(err))

    -- The builtin views are not registrable names.
    for _, name in ipairs({ "files", "comments" }) do
      ok, err = pcall(p.register_tab, tab_spec({ name = name }))
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("already registered", 1, true), tostring(err))
    end
  end)

  it("rejects reserved panel keys in spec.keymaps at register time", function()
    local p = panel()
    for _, lhs in ipairs({ "H", "L", "<Esc>", "q", "dd", "ce", "u", "<C-r>", "r", "gr", "v", "t", "za", "o" }) do
      local ok, err = pcall(p.register_tab, tab_spec({ keymaps = { [lhs] = function() end } }))
      assert.is_false(ok, lhs .. " was not rejected")
      assert.is_truthy(tostring(err):find("reserved", 1, true), tostring(err))
    end
    -- Termcode spelling variants of a reserved key are still reserved.
    local ok, err = pcall(p.register_tab, tab_spec({ keymaps = { ["<esc>"] = function() end } }))
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("reserved", 1, true), tostring(err))
    -- <CR> is allowed: custom rows need an activation key.
    p.register_tab(tab_spec({ keymaps = { ["<CR>"] = function() end } }))
  end)

  it("is re-exported as require('manicule').register_review_tab", function()
    require("manicule").register_review_tab(tab_spec())
    local ok = pcall(panel().register_tab, tab_spec())
    assert.is_false(ok, "re-export did not reach the panel registry")
  end)

  it("appears in the winbar after the builtins and H/L reach it, wrapping", function()
    panel().register_tab(tab_spec({ title = "Checks 7/9" }))
    start_review(1)

    local bar = winbar()
    assert.is_truthy(bar:find("%#ManiculePanelTab#Checks 7/9", 1, true), bar)
    assert.is_true(bar:find("Comments", 1, true) < bar:find("Checks", 1, true), "tab not after the builtins")

    press_in_panel(1, "L") -- files -> comments
    press_in_panel(1, "L") -- comments -> checks
    assert.is_truthy(winbar():find("%#ManiculePanelTabActive#Checks 7/9", 1, true), winbar())
    assert.are.same({ "one check row" }, panel_lines())

    press_in_panel(1, "L") -- checks wraps to files
    assert.is_truthy(winbar():find("%#ManiculePanelTabActive#Files", 1, true), winbar())
    press_in_panel(1, "H") -- files wraps back to checks
    assert.is_truthy(winbar():find("%#ManiculePanelTabActive#Checks 7/9", 1, true), winbar())
  end)

  it("renders build rows with spans and puts data in line_data under kind custom:<name>", function()
    local seen_ctx
    local rows_data = {}
    panel().register_tab(tab_spec({
      build = function(build_ctx)
        seen_ctx = build_ctx
        return {
          { text = "check: lint ok", spans = { { 7, 11, "DiagnosticOk" } }, data = { check = "lint" } },
          { text = "check: test bad", data = { check = "test" } },
        }
      end,
      keymaps = {
        x = function(row)
          rows_data[#rows_data + 1] = row
        end,
      },
    }))
    start_review(2)
    press_in_panel(1, "L")
    press_in_panel(1, "L") -- checks current

    assert.are.same({ "check: lint ok", "check: test bad" }, panel_lines())
    local marks = span_marks(0, "DiagnosticOk")
    assert.are.equal(1, #marks, "custom span not rendered")
    assert.are.equal("lint", panel_lines()[1]:sub(marks[1][3] + 1, marks[1][4].end_col))

    -- build ctx carries the session, panel bufnr, width, and refresh.
    assert.are.equal(require("manicule.review").state(), seen_ctx.session)
    assert.are.equal(panel().bufnr(), seen_ctx.bufnr)
    assert.is_true(type(seen_ctx.width) == "number" and seen_ctx.width > 0)
    assert.are.equal("function", type(seen_ctx.refresh))

    -- The tab keymap receives the line_data entry under the cursor.
    press_in_panel(2, "x")
    assert.are.equal(1, #rows_data)
    assert.are.equal("custom:checks", rows_data[1].kind)
    assert.are.equal("test", rows_data[1].check)
  end)

  it("tab keymaps are active only while the tab is current", function()
    local fired = 0
    -- `)` falls through to the harmless native sentence motion when
    -- the map is (correctly) absent.
    panel().register_tab(tab_spec({
      keymaps = {
        [")"] = function()
          fired = fired + 1
        end,
      },
    }))
    start_review(1)

    -- Not current yet: ) is not a panel map.
    press_in_panel(1, ")")
    assert.are.equal(0, fired)

    press_in_panel(1, "L")
    press_in_panel(1, "L") -- checks current
    press_in_panel(1, ")")
    assert.are.equal(1, fired)

    press_in_panel(1, "L") -- leave to files
    press_in_panel(1, ")")
    assert.are.equal(1, fired, "tab keymap survived leaving the tab")
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(assert(panel().bufnr()), "n")) do
      assert.are_not.equal(")", map.lhs, ") map not removed on leave")
    end
  end)

  it("<CR> routes to the tab's <CR> keymap when declared, else no-ops", function()
    local activated
    panel().register_tab(tab_spec({
      keymaps = {
        ["<CR>"] = function(row)
          activated = row
        end,
      },
    }))
    panel().register_tab(tab_spec({
      name = "plain",
      title = "Plain",
      build = function()
        return { { text = "no activation" } }
      end,
    }))
    start_review(1)
    press_in_panel(1, "L")
    press_in_panel(1, "L") -- checks current
    press_in_panel(1, "<CR>")
    assert.is_truthy(activated)
    assert.are.equal("custom:checks", activated.kind)

    press_in_panel(1, "L") -- plain current
    press_in_panel(1, "<CR>") -- no <CR> keymap: no-op, no error
    assert.is_truthy(winbar():find("%#ManiculePanelTabActive#Plain", 1, true), winbar())
  end)

  it("available=false skips the tab: absent from winbar, skipped by H/L", function()
    local seen_session
    panel().register_tab(tab_spec({
      available = function(session)
        seen_session = session
        return false
      end,
    }))
    start_review(1)

    assert.is_nil(winbar():find("Checks", 1, true), winbar())
    assert.are.equal(require("manicule.review").state(), seen_session)

    press_in_panel(1, "L") -- files -> comments
    press_in_panel(1, "L") -- comments wraps straight to files, skipping checks
    assert.is_truthy(winbar():find("%#ManiculePanelTabActive#Files", 1, true), winbar())
  end)

  it("resolves a title function per render: live counts and % escaping", function()
    local count = 1
    panel().register_tab(tab_spec({
      title = function()
        return ("Checks %d%%"):format(count)
      end,
    }))
    start_review(1)
    assert.is_truthy(winbar():find("Checks 1%%", 1, true), winbar())

    count = 2
    vim.api.nvim_exec_autocmds("User", { pattern = "ManiculeEdited" })
    vim.wait(200, function()
      return winbar():find("Checks 2%%", 1, true) ~= nil
    end, 10)
    assert.is_truthy(winbar():find("Checks 2%%", 1, true), winbar())
  end)

  it("fires on_show entering the tab (before build) and on_hide leaving it", function()
    local calls = {}
    panel().register_tab(tab_spec({
      build = function()
        calls[#calls + 1] = "build"
        return { { text = "row" } }
      end,
      on_show = function()
        calls[#calls + 1] = "show"
      end,
      on_hide = function()
        calls[#calls + 1] = "hide"
      end,
    }))
    start_review(1)
    press_in_panel(1, "L")
    press_in_panel(1, "L") -- enter checks
    assert.are.same({ "show", "build" }, calls)
    press_in_panel(1, "L") -- leave checks
    assert.are.same({ "show", "build", "hide" }, calls)
  end)

  it("ctx.refresh re-renders the open panel and no-ops once it is closed", function()
    local rows = { { text = "pending..." } }
    local saved_ctx
    panel().register_tab(tab_spec({
      on_show = function(tab_ctx)
        saved_ctx = tab_ctx
      end,
      build = function()
        return rows
      end,
    }))
    start_review(1)
    press_in_panel(1, "L")
    press_in_panel(1, "L")
    assert.are.same({ "pending..." }, panel_lines())

    -- The async-fetch shape: rows change, then a scheduled refresh.
    rows = { { text = "check a" }, { text = "check b" } }
    vim.schedule(saved_ctx.refresh)
    vim.wait(200, function()
      return #panel_lines() == 2
    end, 10)
    assert.are.same({ "check a", "check b" }, panel_lines())

    -- Refresh while NOT current re-renders the current view; harmless.
    press_in_panel(1, "L") -- back to files
    saved_ctx.refresh()
    assert.is_truthy(panel_lines()[1]:find("f1.lua", 1, true))

    panel().close()
    saved_ctx.refresh() -- must not error with the panel closed
    assert.is_nil(panel().winid())
  end)

  it("registering while the panel is open takes effect on the next render", function()
    start_review(1)
    assert.is_nil(winbar():find("Checks", 1, true))

    panel().register_tab(tab_spec())
    vim.api.nvim_exec_autocmds("User", { pattern = "ManiculeEdited" })
    vim.wait(200, function()
      return winbar():find("Checks", 1, true) ~= nil
    end, 10)
    assert.is_truthy(winbar():find("Checks", 1, true), winbar())
  end)

  it("_reset_tabs drops registered tabs and falls back to a builtin view", function()
    panel().register_tab(tab_spec())
    start_review(1)
    press_in_panel(1, "L")
    press_in_panel(1, "L") -- checks current

    panel()._reset_tabs()
    require("manicule.review.panel").refresh()
    assert.is_nil(winbar():find("Checks", 1, true), winbar())
    assert.is_truthy(winbar():find("%#ManiculePanelTabActive#Files", 1, true), winbar())
    -- Registration works again after the reset.
    panel().register_tab(tab_spec())
  end)
end)

describe("manicule panel tab registry in project mode", function()
  before_each(function()
    ctx = H.setup()
    panel()._reset_tabs()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    panel()._reset_tabs()
    panel().close()
    H.teardown(ctx)
    ctx = nil
  end)

  it("excludes registered tabs by default", function()
    panel().register_tab(tab_spec())
    H.edit_project_file(ctx, "a.lua", { "return 1" })
    panel().list()

    assert.is_nil(winbar():find("Checks", 1, true), winbar())
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(assert(panel().bufnr()), "n")) do
      assert.are_not.equal("H", map.lhs, "H leaked into the project-mode panel")
      assert.are_not.equal("L", map.lhs, "L leaked into the project-mode panel")
    end
  end)

  it("includes project = true tabs and wires H/L to reach them", function()
    panel().register_tab(tab_spec({ project = true }))
    H.edit_project_file(ctx, "a.lua", { "return 1" })
    panel().list()

    assert.is_truthy(winbar():find("%#ManiculePanelTab#Checks", 1, true), winbar())
    press_in_panel(1, "L") -- comments -> checks
    assert.is_truthy(winbar():find("%#ManiculePanelTabActive#Checks", 1, true), winbar())
    assert.are.same({ "one check row" }, panel_lines())
    press_in_panel(1, "L") -- wraps back to comments
    assert.is_truthy(winbar():find("%#ManiculePanelTabActive#Comments", 1, true), winbar())
  end)
end)

describe("manicule builtin tabs loader", function()
  before_each(function()
    ctx = H.setup()
    panel()._reset_tabs()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    package.preload["manicule.review.tabs.github"] = nil
    package.loaded["manicule.review.tabs.github"] = nil
    panel()._reset_tabs()
    H.teardown(ctx)
    ctx = nil
  end)

  it("tolerates the (not yet existing) builtin tab modules silently", function()
    local tabs = require("manicule.review.tabs")
    tabs._reset()
    tabs.setup() -- neither module exists: must not error
  end)

  it("calls setup() on each builtin tab module that loads", function()
    package.preload["manicule.review.tabs.github"] = function()
      return {
        setup = function()
          panel().register_tab({
            name = "github",
            title = "GitHub",
            build = function()
              return {}
            end,
          })
        end,
      }
    end
    local tabs = require("manicule.review.tabs")
    tabs._reset()
    tabs.setup()
    -- Registered: a duplicate registration now errors.
    local ok = pcall(panel().register_tab, { name = "github", title = "G", build = function() end })
    assert.is_false(ok, "loader did not register the stubbed builtin tab")
    -- Idempotent: the panel calls setup() on every open.
    tabs.setup()
  end)
end)
