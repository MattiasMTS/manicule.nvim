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
    for _, lhs in ipairs({ "<cr>", "o", "v", "r", "gr", "<esc>", "<tab>", "dd", "ce", "u", "<c-r>" }) do
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

  it("renders one `[S] path  +A \u{2212}R  · N comments` line per pair", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "rows" }))
    local lines = panel_lines()
    assert.are.equal(2, #lines)
    -- make_pairs writes a one-line change per pair: +1 −1.
    assert.are.equal("  [M] f1.lua  +1 \u{2212}1  \u{00B7} 0 comments", lines[1])
    assert.are.equal("  [M] f2.lua  +1 \u{2212}1  \u{00B7} 0 comments", lines[2])
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

describe("manicule review panel diffstat", function()
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

  ---Pair over explicit line contents; nil lines leave that side unwritten.
  local function pair_of(name, status, left_lines, right_lines)
    local left = ctx.artifact_root .. "/left/" .. name
    local right = ctx.root .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    if left_lines then
      vim.fn.writefile(left_lines, left)
    end
    if right_lines then
      vim.fn.writefile(right_lines, right)
    end
    return { left = left, right = right, status = status, path = name }
  end

  it("sums added and removed lines across hunks for M pairs", function()
    local R = require("manicule.review")
    -- One changed line + one appended line: +2 −1.
    local files = { pair_of("m.lua", "M", { "a", "b", "c" }, { "a", "B", "c", "d" }) }
    assert.is_true(R.start({ files = files, label = "stat-m" }))
    assert.are.equal("  [M] m.lua  +2 \u{2212}1  \u{00B7} 0 comments", panel_lines()[1])
  end)

  it("A pairs show the right side's line count, D pairs the left's", function()
    local R = require("manicule.review")
    local files = {
      -- Added file: no left side exists at all.
      pair_of("a.lua", "A", nil, { "one", "two", "three" }),
      pair_of("d.lua", "D", { "one", "two" }, nil),
    }
    assert.is_true(R.start({ files = files, label = "stat-ad" }))
    local lines = panel_lines()
    assert.are.equal("  [A] a.lua  +3  \u{00B7} 0 comments", lines[1])
    assert.are.equal("  [D] d.lua  \u{2212}2  \u{00B7} 0 comments", lines[2])
  end)

  it("omits the counts entirely when nothing changed or a side is unreadable", function()
    local R = require("manicule.review")
    local files = {
      pair_of("same.lua", "M", { "return 1" }, { "return 1" }),
      -- Left never written: job-staged files may vanish; render, no error.
      pair_of("gone.lua", "M", nil, { "return 2" }),
    }
    assert.is_true(R.start({ files = files, label = "stat-none" }))
    local lines = panel_lines()
    assert.are.equal("  [M] same.lua  \u{00B7} 0 comments", lines[1])
    assert.are.equal("  [M] gone.lua  \u{00B7} 0 comments", lines[2])
  end)

  it("highlights the counts via Added/Removed-linked span groups", function()
    local R = require("manicule.review")
    local files = { pair_of("m.lua", "M", { "a", "b", "c" }, { "a", "B", "c", "d" }) }
    assert.is_true(R.start({ files = files, label = "stat-hl" }))

    local line = panel_lines()[1]
    local added = span_marks(0, "ManiculePanelAdded")
    assert.are.equal(1, #added, "added span missing")
    assert.are.equal("+2", line:sub(added[1][3] + 1, added[1][4].end_col))
    local removed = span_marks(0, "ManiculePanelRemoved")
    assert.are.equal(1, #removed, "removed span missing")
    assert.are.equal("\u{2212}1", line:sub(removed[1][3] + 1, removed[1][4].end_col))

    -- Linked to the builtin diff groups, not hardcoded colors.
    assert.are.equal("Added", vim.api.nvim_get_hl(0, { name = "ManiculePanelAdded" }).link)
    assert.are.equal("Removed", vim.api.nvim_get_hl(0, { name = "ManiculePanelRemoved" }).link)
  end)

  it("computes the stat once per session: later renders keep the first counts", function()
    local R = require("manicule.review")
    local files = { pair_of("m.lua", "M", { "a" }, { "b" }) }
    assert.is_true(R.start({ files = files, label = "stat-cache" }))
    assert.are.equal("  [M] m.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[1])

    -- The worktree side changes mid-session; the panel refresh must NOT
    -- re-read the pair — the stat is as-of the first render by design.
    vim.fn.writefile({ "b", "c", "d" }, files[1].right)
    vim.api.nvim_exec_autocmds("User", { pattern = "ManiculeEdited" })
    vim.wait(200, function()
      return false
    end, 10)
    assert.are.equal("  [M] m.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[1])
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
    -- prev() marks pair 2 viewed and skips the (auto-viewed) pair 1,
    -- wrapping to pair 3 — see the viewed-tracking specs.
    R.prev()
    assert.are.same({ 2 }, current_rows())
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

  it("coalesces a synchronous burst of mutation events into one render", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "burst" }))

    -- Drain callbacks already scheduled by start so the spy below only
    -- sees renders caused by the burst fired here.
    vim.wait(50, function()
      return false
    end, 10)

    -- Every files-view render fetches counts through ONE manicule.list
    -- call, so list calls count renders.
    local manicule = require("manicule")
    local original_list = manicule.list
    local list_calls = 0
    manicule.list = function(...)
      list_calls = list_calls + 1
      return original_list(...)
    end

    -- Five synchronous events, zero event-loop ticks in between — the
    -- burst shape a consuming send produces (one ManiculeDeleted per
    -- cleared record).
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("User", { pattern = "ManiculeEdited" })
    end
    assert.is_true(vim.wait(1000, function()
      return list_calls > 0
    end, 10))
    vim.wait(50, function()
      return false
    end, 10)
    manicule.list = original_list

    assert.are.equal(1, list_calls)
  end)

  it("skips the buffer rewrite when a refresh produces identical rows", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "nowrite" }))
    local bufnr = assert(panel().bufnr())

    local writes = 0
    vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = function()
        writes = writes + 1
      end,
    })

    -- Nothing changed since the initial render: the refresh must not
    -- rewrite the buffer.
    vim.api.nvim_exec_autocmds("User", { pattern = "ManiculeEdited" })
    vim.wait(100, function()
      return false
    end, 10)
    assert.are.equal(0, writes)

    -- A real change (a live count flips 0 → 1) still rewrites — once.
    add_comment(files[1].right, "count me")
    vim.wait(1000, function()
      return writes > 0
    end, 10)
    vim.wait(50, function()
      return false
    end, 10)
    assert.is_truthy(panel_lines()[1]:find("1 comments", 1, true))
    assert.are.equal(1, writes)
  end)

  it("panel renders skip the editor-wide position sync", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    assert.is_true(R.start({ files = files, label = "nosync" }))
    add_comment(files[1].right, "synced by the mutating path")
    -- Drain the add's own scheduled refresh before installing the spy.
    vim.wait(200, function()
      return false
    end, 10)

    -- `sync_positions_for_buffer` reaches `capture_position_patches`
    -- for every loaded buffer that owns records — the only caller of
    -- that render API, so it is a clean seam for "did list() sync?".
    local render = require("manicule.ui.render")
    local original = render.capture_position_patches
    local sync_calls = 0
    render.capture_position_patches = function(...)
      sync_calls = sync_calls + 1
      return original(...)
    end

    vim.api.nvim_exec_autocmds("User", { pattern = "ManiculeEdited" })
    vim.wait(100, function()
      return false
    end, 10)
    render.capture_position_patches = original

    assert.are.equal(0, sync_calls)
  end)

  it("editor-wide sweeps skip manicule's own panel buffer", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    assert.is_true(R.start({ files = files, label = "own-surface" }))
    add_comment(files[1].right, "sweep me")
    local manicule = require("manicule")
    local record = manicule.list({ _quiet = true, _root = ctx.root })[1]
    local panel_bufnr = assert(panel().bufnr())
    vim.wait(200, function()
      return false
    end, 10)

    local adapter = require("manicule.adapter")
    local original_identify = adapter.identify
    local panel_identify_calls = 0
    adapter.identify = function(bufnr, ...)
      if bufnr == panel_bufnr then
        panel_identify_calls = panel_identify_calls + 1
      end
      return original_identify(bufnr, ...)
    end

    -- delete() runs the paint sweep (refresh_all_loaded); a syncing
    -- list() runs the position-sync sweep. Neither may pay identify /
    -- store work on the panel, which can never hold records.
    manicule.delete(record.id, { scope = record.scope, project_root = record.project_root })
    manicule.list({ _quiet = true, _root = ctx.root })
    vim.wait(100, function()
      return false
    end, 10)
    adapter.identify = original_identify

    assert.are.equal(0, panel_identify_calls)
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
        ("  @ [M] f%d.lua  +1 \u{2212}1  \u{00B7} 0 comments"):format(i),
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
    assert.are.equal("  [M] f1.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[1])
  end)

  it("omits the icon when no provider is loadable (auto)", function()
    assert.is_true(require("manicule.review").start({ files = make_pairs(1), label = "panel-icons-auto-none" }))
    assert.are.equal("  [M] f1.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[1])
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
    assert.are.equal("    [M] f1.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[1])
  end)
end)

---Press `lhs` in the panel window on `row` THROUGH buffer-local maps.
local function press_in_panel(row, lhs)
  local winid = assert(panel().winid(), "panel window not open")
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, "x", false)
end

describe("manicule review panel viewed tracking", function()
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

  it("v toggles the row's viewed state: \u{2713} lead, dim, progress", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "viewed" }))
    local winid = assert(panel().winid())
    assert.are.equal("0/2 viewed", vim.wo[winid].winbar)

    press_in_panel(2, "v")
    assert.is_true(R.state().viewed[2])
    assert.are.equal("\u{2713} [M] f2.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[2])
    assert.are.equal("1/2 viewed", vim.wo[winid].winbar)
    assert.is_true(#span_marks(1, "ManiculePanelViewed") > 0, "viewed row not dimmed")
    -- Unviewed row untouched.
    assert.are.equal("  [M] f1.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[1])
    assert.are.equal(0, #span_marks(0, "ManiculePanelViewed"))

    -- Second press un-marks.
    press_in_panel(2, "v")
    assert.is_nil(R.state().viewed[2])
    assert.are.equal("  [M] f2.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[2])
    assert.are.equal("0/2 viewed", vim.wo[winid].winbar)
    assert.are.equal(0, #span_marks(1, "ManiculePanelViewed"))
  end)

  it("dims the whole viewed row EXCEPT the diffstat spans", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "viewed-dim" }))
    R.set_viewed(1, true)

    -- The +/− spans stay colored (Pierre keeps them visible).
    local added = span_marks(0, "ManiculePanelAdded")
    local removed = span_marks(0, "ManiculePanelRemoved")
    assert.are.equal(1, #added)
    assert.are.equal(1, #removed)

    -- Dim segments never overlap the diffstat spans and cover the rest
    -- of the row (start of line through the tail).
    local dims = span_marks(0, "ManiculePanelViewed")
    assert.is_true(#dims > 0, "no dim spans on the viewed row")
    local colored = { { added[1][3], added[1][4].end_col }, { removed[1][3], removed[1][4].end_col } }
    local covered = 0
    for _, dim in ipairs(dims) do
      local dim_start, dim_end = dim[3], dim[4].end_col
      covered = covered + (dim_end - dim_start)
      for _, span in ipairs(colored) do
        assert.is_true(dim_end <= span[1] or dim_start >= span[2], "dim span overlaps a diffstat span")
      end
    end
    local line = panel_lines()[1]
    local stat_bytes = (added[1][4].end_col - added[1][3]) + (removed[1][4].end_col - removed[1][3])
    assert.are.equal(#line - stat_bytes, covered, "dim spans do not cover the rest of the row")
    -- Dim group is a default Comment link, so user overrides win.
    assert.are.equal("Comment", vim.api.nvim_get_hl(0, { name = "ManiculePanelViewed" }).link)
  end)

  it("next() auto-marks the pair it leaves and the panel shows it", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "viewed-auto" }))
    R.next()
    assert.is_true(R.state().viewed[1])
    assert.are.equal("\u{2713} [M] f1.lua  +1 \u{2212}1  \u{00B7} 0 comments", panel_lines()[1])
    assert.are.equal("1/2 viewed", vim.wo[assert(panel().winid())].winbar)
  end)
end)

describe("manicule review panel placement", function()
  after_each(function()
    pcall(function()
      require("manicule.review").stop()
    end)
    H.teardown(ctx)
    ctx = nil
  end)

  local function side_width()
    return math.min(46, math.max(30, math.floor(vim.o.columns * 0.3)))
  end

  it("left: full-height side split at the far left", function()
    ctx = H.setup({ review = { panel = { position = "left" } } })
    assert.is_true(require("manicule.review").start({ files = make_pairs(2), label = "left" }))
    local winid = assert(panel().winid())
    assert.are.equal(0, vim.api.nvim_win_get_position(winid)[2])
    assert.are.equal(side_width(), vim.api.nvim_win_get_width(winid))
    assert.is_true(vim.wo[winid].winfixwidth)
    for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if other ~= winid then
        assert.is_true(vim.api.nvim_win_get_position(other)[2] > 0, "panel is not the left-most window")
      end
    end
  end)

  it("right: full-height side split placed OUTERMOST", function()
    ctx = H.setup({ review = { panel = { position = "right" } } })
    assert.is_true(require("manicule.review").start({ files = make_pairs(2), label = "right" }))
    local winid = assert(panel().winid())
    local col = vim.api.nvim_win_get_position(winid)[2]
    assert.are.equal(vim.o.columns, col + vim.api.nvim_win_get_width(winid))
    assert.are.equal(side_width(), vim.api.nvim_win_get_width(winid))
    assert.is_true(vim.wo[winid].winfixwidth)
  end)

  it("size overrides the per-position default", function()
    ctx = H.setup({ review = { panel = { position = "bottom", size = 5 } } })
    assert.is_true(require("manicule.review").start({ files = make_pairs(1), label = "sized" }))
    local winid = assert(panel().winid())
    assert.are.equal(5, vim.api.nvim_win_get_height(winid))

    require("manicule.review").stop()
    -- Runtime mutation (same pattern as ui.icons above): the panel
    -- reads placement at open time.
    require("manicule.config").get().review.panel = { position = "right", size = 40 }
    assert.is_true(require("manicule.review").start({ files = make_pairs(1), label = "sized-right" }))
    winid = assert(panel().winid())
    assert.are.equal(40, vim.api.nvim_win_get_width(winid))
  end)

  it("float: centered editor-relative window that takes focus", function()
    ctx = H.setup({ review = { panel = { position = "float" } } })
    assert.is_true(require("manicule.review").start({ files = make_pairs(2), label = "float" }))
    local winid = assert(panel().winid())
    local cfg = vim.api.nvim_win_get_config(winid)
    assert.are.equal("editor", cfg.relative)
    local width = math.floor(vim.o.columns * 0.6)
    local height = math.floor(vim.o.lines * 0.4)
    assert.are.equal(width, cfg.width)
    assert.are.equal(height, cfg.height)
    assert.are.equal(math.floor((vim.o.lines - height) / 2), cfg.row)
    assert.are.equal(math.floor((vim.o.columns - width) / 2), cfg.col)
    assert.is_truthy(cfg.border, "float has no border")
    -- Modal-ish: the float takes focus on open (splits never do).
    assert.are.equal(winid, vim.api.nvim_get_current_win())
  end)

  it("float: q closes the panel and keeps the session", function()
    ctx = H.setup({ review = { panel = { position = "float" } } })
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "float-q" }))
    press_in_panel(1, "q")
    assert.is_nil(panel().winid(), "q did not close the float panel")
    assert.is_truthy(R.state(), "q killed the session")
    -- Toggle reopens it.
    assert.is_true(panel().toggle())
    assert.is_truthy(panel().winid())
  end)

  it("q is not mapped for split positions", function()
    ctx = H.setup()
    assert.is_true(require("manicule.review").start({ files = make_pairs(1), label = "no-q" }))
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(assert(panel().bufnr()), "n")) do
      assert.are_not.equal("q", map.lhs, "q leaked into a split-position panel")
    end
  end)

  it("rejects an unknown position and a bad size", function()
    ctx = H.setup()
    local config = require("manicule.config")
    local ok, err = pcall(config.setup, { review = { panel = { position = "top" } } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("review.panel.position", 1, true))

    local ok2, err2 = pcall(config.setup, { review = { panel = { size = 0 } } })
    assert.is_false(ok2)
    assert.is_truthy(tostring(err2):find("review.panel.size", 1, true))

    local ok3, err3 = pcall(config.setup, { review = { panel = { size = 2.5 } } })
    assert.is_false(ok3)
    assert.is_truthy(tostring(err3):find("review.panel.size", 1, true))
  end)
end)
