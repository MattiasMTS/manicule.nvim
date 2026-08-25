local H = require("helpers")

local ctx

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

local ns = vim.api.nvim_create_namespace("manicule.review.panel")
local ns_current = vim.api.nvim_create_namespace("manicule.review.panel.current")

local function panel()
  return require("manicule.review.panel")
end

local function panel_lines()
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function marks_in(namespace)
  local bufnr = assert(panel().bufnr(), "panel buffer not open")
  return vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
end

---0-indexed rows carrying the full-line current-pair highlight.
local function current_rows()
  local rows = {}
  for _, mark in ipairs(marks_in(ns_current)) do
    if mark[4].line_hl_group == "ManiculePanelCurrent" then
      table.insert(rows, mark[2])
    end
  end
  return rows
end

---Content extmarks on `row` (0-indexed) using highlight group `hl`.
local function span_marks(row, hl)
  local found = {}
  for _, mark in ipairs(marks_in(ns)) do
    if mark[2] == row and mark[4].hl_group == hl then
      table.insert(found, mark)
    end
  end
  return found
end

local function add_comment(path, body, line)
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
  local ui = require("manicule.ui")
  local original_prompt = ui.prompt
  ui.prompt = function(_opts, cb)
    cb(body)
  end
  require("manicule").add()
  ui.prompt = original_prompt
end

describe("manicule review panel substrate", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("renders into an owned scratch buffer, not the quickfix list", function()
    local R = require("manicule.review")
    local qf_size_before = #vim.fn.getqflist()
    assert.is_true(R.start({ files = make_pairs(2), label = "substrate" }))

    local winid = assert(panel().winid(), "panel window not open")
    local bufnr = vim.api.nvim_win_get_buf(winid)
    assert.are.equal("manicule-panel", vim.bo[bufnr].filetype)
    assert.are.equal("nofile", vim.bo[bufnr].buftype)
    assert.is_truthy(vim.api.nvim_buf_get_name(bufnr):find("manicule://panel", 1, true))
    assert.is_false(vim.bo[bufnr].modifiable)

    -- Bottom full-width split, fixed height min(12, #files + 2).
    assert.are.equal(vim.o.columns, vim.api.nvim_win_get_width(winid))
    assert.are.equal(4, vim.api.nvim_win_get_height(winid))
    assert.is_true(vim.wo[winid].winfixheight)
    assert.is_true(vim.wo[winid].cursorline)
    for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if other ~= winid then
        assert.is_true(
          vim.api.nvim_win_get_position(winid)[1] > vim.api.nvim_win_get_position(other)[1],
          "panel is not the bottom-most window"
        )
      end
    end

    -- The review never touches the quickfix stack.
    assert.are.equal(qf_size_before, #vim.fn.getqflist())
  end)

  it("caps the panel height at 12 rows for large reviews", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(15), label = "tall" }))
    local winid = assert(panel().winid(), "panel window not open")
    assert.are.equal(12, vim.api.nvim_win_get_height(winid))
  end)

  it("leaves the user's quickfix and location lists untouched", function()
    local R = require("manicule.review")
    local files = make_pairs(1)

    vim.fn.setqflist({}, " ", { title = "user-list", items = { { filename = files[1].right, lnum = 1 } } })
    vim.cmd("copen")
    local qf_win = vim.api.nvim_get_current_win()
    vim.cmd.wincmd("p")
    vim.fn.setloclist(0, { { filename = files[1].right, lnum = 1 } })

    assert.is_true(R.start({ files = files, label = "qf-free" }))
    local p = panel()
    assert.is_true(p.toggle()) -- hide
    assert.is_true(p.toggle()) -- reopen
    R.stop()

    assert.is_true(vim.api.nvim_win_is_valid(qf_win), "review closed the user's quickfix window")
    local info = vim.fn.getqflist({ title = 1, items = 1 })
    assert.are.equal("user-list", info.title)
    assert.are.equal(1, #info.items)
  end)

  it("sets buffer-local keymaps with descriptions on the panel only", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "maps" }))
    local bufnr = assert(panel().bufnr())

    local by_lhs = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if type(map.desc) == "string" and map.desc:find("Manicule review", 1, true) then
        by_lhs[map.lhs:lower()] = true
      end
    end
    for _, lhs in ipairs({ "<cr>", "o", "r", "gr", "<esc>", "<tab>", "dd", "ce", "u", "<c-r>" }) do
      assert.is_true(by_lhs[lhs] == true, "missing panel keymap " .. lhs)
    end
  end)
end)

describe("manicule review panel files view", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("renders one `[S] path  · N comments` line per pair", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "rows" }))
    local lines = panel_lines()
    assert.are.equal(2, #lines)
    assert.are.equal("  [M] f1.lua  \u{00B7} 0 comments", lines[1])
    assert.are.equal("  [M] f2.lua  \u{00B7} 0 comments", lines[2])
  end)

  it("links status letters to diagnostic groups, M stays default", function()
    local R = require("manicule.review")
    local files = make_pairs(3)
    files[2].status = "A"
    files[3].status = "D"
    assert.is_true(R.start({ files = files, label = "status" }))

    assert.are.equal(0, #span_marks(0, "ManiculePanelStatusA") + #span_marks(0, "ManiculePanelStatusD"))
    assert.are.equal(1, #span_marks(1, "ManiculePanelStatusA"))
    assert.are.equal(1, #span_marks(2, "ManiculePanelStatusD"))
    -- Linked, not hardcoded.
    assert.are.equal("DiagnosticOk", vim.api.nvim_get_hl(0, { name = "ManiculePanelStatusA" }).link)
    assert.are.equal("DiagnosticError", vim.api.nvim_get_hl(0, { name = "ManiculePanelStatusD" }).link)
  end)

  it("dims the comment count tail", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "counts" }))
    local mark = span_marks(0, "ManiculePanelCount")[1]
    assert.is_truthy(mark, "count span missing")
    local line = panel_lines()[1]
    assert.are.equal("  \u{00B7} 0 comments", line:sub(mark[3] + 1, mark[4].end_col))
  end)
end)

describe("manicule review panel current-pair highlight", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("marks exactly one line and follows next()/prev()", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(3), label = "current" }))
    assert.are.same({ 0 }, current_rows())

    R.next()
    assert.are.same({ 1 }, current_rows())
    R.prev()
    assert.are.same({ 0 }, current_rows())
  end)

  it("overlays the ▸ marker and bolds the open pair's filename", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "marker" }))
    R.next()

    local overlay, bold
    for _, mark in ipairs(marks_in(ns_current)) do
      local details = mark[4]
      if details.virt_text then
        overlay = { row = mark[2], chunk = details.virt_text[1] }
      elseif details.hl_group == "ManiculePanelCurrentFile" then
        bold = { row = mark[2], text = panel_lines()[mark[2] + 1]:sub(mark[3] + 1, details.end_col) }
      end
    end
    assert.are.same({ row = 1, chunk = { "\u{25B8} ", "ManiculePanelCurrent" } }, overlay)
    assert.are.same({ row = 1, text = "f2.lua" }, bold)
    assert.is_true(vim.api.nvim_get_hl(0, { name = "ManiculePanelCurrentFile" }).bold)
  end)

  it("derives the current-line background from Normal via blend", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xCDD6F4, bg = 0x1E1E2E })
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "blend" }))

    local expected = require("manicule.ui.render").blend(0x1E1E2E, 0xCDD6F4, 0.08)
    assert.are.equal(expected, vim.api.nvim_get_hl(0, { name = "ManiculePanelCurrent" }).bg)

    -- Recomputed when the colorscheme changes while the panel is open.
    vim.api.nvim_set_hl(0, "Normal", { fg = 0x000000, bg = 0xFFFFFF })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    expected = require("manicule.ui.render").blend(0xFFFFFF, 0x000000, 0.08)
    assert.are.equal(expected, vim.api.nvim_get_hl(0, { name = "ManiculePanelCurrent" }).bg)
  end)

  it("falls back to CursorLine on transparent themes", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xCDD6F4 })
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "transparent" }))
    assert.are.equal("CursorLine", vim.api.nvim_get_hl(0, { name = "ManiculePanelCurrent" }).link)
  end)
end)

describe("manicule review panel refresh", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("preserves the panel cursor across a live refresh", function()
    local R = require("manicule.review")
    local files = make_pairs(3)
    assert.is_true(R.start({ files = files, label = "cursor" }))
    local winid = assert(panel().winid())
    vim.api.nvim_win_set_cursor(winid, { 3, 0 })

    add_comment(files[1].right, "count me")
    vim.wait(200)

    assert.is_truthy(panel_lines()[1]:find("1 comments", 1, true), "count did not refresh")
    assert.are.equal(3, vim.api.nvim_win_get_cursor(winid)[1])
  end)

  it("refreshes on ManiculeRestored so panel-local undo shows the comment again", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    assert.is_true(R.start({ files = files, label = "undo" }))
    add_comment(files[1].right, "restore me")
    vim.wait(200)
    assert.is_truthy(panel_lines()[1]:find("1 comments", 1, true))

    require("manicule").delete(require("manicule").list({ _quiet = true, _root = ctx.root })[1].id)
    vim.wait(200)
    assert.is_truthy(panel_lines()[1]:find("0 comments", 1, true))

    require("manicule").undo_delete()
    vim.wait(200)
    assert.is_truthy(panel_lines()[1]:find("1 comments", 1, true), "ManiculeRestored did not refresh the panel")
  end)
end)

describe("manicule review panel lifecycle", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("tears down when the user :quits the panel window and toggle reopens", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "winclosed" }))
    local p = panel()
    local winid = assert(p.winid())

    vim.api.nvim_win_close(winid, true)
    vim.wait(100, function()
      return p.winid() == nil
    end)

    assert.is_nil(p.winid(), "panel state survived the window close")
    local ok = pcall(vim.api.nvim_get_autocmds, { group = "ManiculeReviewPanel" })
    assert.is_false(ok, "panel augroup leaked past the window close")

    assert.is_true(p.toggle())
    assert.is_truthy(p.winid(), "toggle did not reopen the panel")
  end)

  it("close() is idempotent and stop() leaves no panel state behind", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "close" }))
    local p = panel()
    p.close()
    p.close()
    assert.is_nil(p.winid())
    assert.is_false(p.is_open())

    R.stop()
    -- A fresh session starts clean in files view.
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "fresh" }))
    assert.are.equal(2, #panel_lines())
    assert.is_truthy(panel_lines()[1]:find("f1.lua", 1, true))
  end)
end)

describe("manicule review panel file icons", function()
  local function stub_mini_icons(icon, hl)
    package.preload["mini.icons"] = function()
      return {
        get = function(_category, _name)
          return icon or "@", hl or "MiniIconsAzure", false
        end,
      }
    end
  end

  local function clear_provider_stubs()
    package.preload["mini.icons"] = nil
    package.loaded["mini.icons"] = nil
    package.preload["nvim-web-devicons"] = nil
    package.loaded["nvim-web-devicons"] = nil
  end

  before_each(function()
    clear_provider_stubs()
    ctx = H.setup()
    require("manicule.ui.icons")._reset()
  end)

  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    clear_provider_stubs()
    pcall(function()
      require("manicule.ui.icons")._reset()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  it("prepends the filetype icon with its highlight when icons are enabled", function()
    -- ui.icons defaults to "auto"; the stubbed provider makes it live.
    stub_mini_icons("@", "MiniIconsAzure")
    assert.is_true(require("manicule.review").start({ files = make_pairs(2), label = "panel-icons" }))
    local lines = panel_lines()
    assert.are.equal(2, #lines)
    for i, line in ipairs(lines) do
      assert.are.equal(
        ("  @ [M] f%d.lua  \u{00B7} 0 comments"):format(i),
        line,
        ("line %d changed shape: %q"):format(i, line)
      )
      -- The provider's highlight rides along as an extmark — the old
      -- quickfix substrate could never color the glyph.
      local icon_marks = span_marks(i - 1, "MiniIconsAzure")
      assert.are.equal(1, #icon_marks, ("line %d missing icon highlight"):format(i))
      assert.are.equal(2, icon_marks[1][3], "icon highlight is not on the glyph column")
    end
  end)

  it("omits the icon when ui.icons = false", function()
    stub_mini_icons("@")
    require("manicule.config").current.ui.icons = false
    assert.is_true(require("manicule.review").start({ files = make_pairs(1), label = "panel-icons-off" }))
    assert.are.equal("  [M] f1.lua  \u{00B7} 0 comments", panel_lines()[1])
  end)

  it("omits the icon when no provider is loadable (auto)", function()
    assert.is_true(require("manicule.review").start({ files = make_pairs(1), label = "panel-icons-auto-none" }))
    assert.are.equal("  [M] f1.lua  \u{00B7} 0 comments", panel_lines()[1])
  end)

  it("keeps the icon column aligned when the provider yields no icon", function()
    package.preload["mini.icons"] = function()
      return {
        get = function()
          error("mini.icons not set up")
        end,
      }
    end
    assert.is_true(require("manicule.review").start({ files = make_pairs(1), label = "panel-icons-erroring" }))
    -- Provider loadable (icons enabled) but erroring: a blank cell
    -- keeps the column so mixed successes/failures still line up.
    assert.are.equal("    [M] f1.lua  \u{00B7} 0 comments", panel_lines()[1])
  end)
end)
