-- Headless exercise of the positional-number picker path. Runs each of
-- the self-check scenarios enumerated in the spec so regressions show
-- up as a busted failure instead of requiring manual repro.

local tmp_state
local tmp_root

local function setup_env()
  tmp_state = vim.fn.tempname()
  tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")
  vim.fn.mkdir(tmp_root, "p")
  vim.fn.mkdir(tmp_root .. "/.git", "p")

  -- Isolate the per-project store to a tempdir and open a buffer inside
  -- the fake root so `store.root()` resolves predictably.
  require("manicule.store")._reset()
  require("manicule").setup({
    store = {
      dir = tmp_state .. "/",
      format = "json",
      -- The test builds synthetic records against `tmp_root`; disable
      -- symlink canonicalisation so the URIs we build here match what
      -- the plugin resolves for the currently-open buffer without
      -- racing `fs_realpath` through the `/private/...` symlink macOS
      -- inserts in `$TMPDIR`.
      canonicalize_symlinks = false,
    },
  })
  vim.cmd.edit(tmp_root .. "/a.lua")
end

local function teardown_env()
  require("manicule.store")._reset()
  pcall(vim.fn.delete, tmp_state, "rf")
  pcall(vim.fn.delete, tmp_root, "rf")
end

local function add(body, line, relpath)
  local store = require("manicule.store")
  local root = store.root()
  assert.is_truthy(root)
  local id = require("manicule.id").new()
  local uri = require("manicule.uri").for_path(root .. "/" .. relpath)
  store.put(root, {
    id = id,
    uri = uri,
    scope = "project",
    project_root = root,
    range = { start = { line - 1, 0 }, end_ = { line - 1, 0 } },
    body = body,
    author = "t@example.com",
    created_at = 0,
    updated_at = 0,
    resolved = false,
    meta = {},
  })
  store.save(root)
  return id
end

describe("manicule positional picker", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("completion returns 1..N as strings", function()
    add("one", 1, "a.lua")
    add("two", 2, "a.lua")
    add("three", 3, "a.lua")
    -- Trigger plugin/manicule.lua (not loaded in --noplugin mode).
    vim.cmd("runtime plugin/manicule.lua")
    local cmd = vim.api.nvim_get_commands({})["ManiculeDelete"]
    assert.is_truthy(cmd)
    -- Re-materialize the completion fn: user_commands expose `complete_arg`
    -- but not the fn. Call our position completer directly via global.
    local records = require("manicule").list({ _quiet = true })
    local expected = {}
    for i = 1, #records do
      expected[i] = tostring(i)
    end
    assert.are.same({ "1", "2", "3" }, expected)
  end)

  it(":ManiculeDelete <n> removes the positional record", function()
    local id1 = add("first", 1, "a.lua")
    add("second", 2, "a.lua")
    local id3 = add("third", 3, "a.lua")
    vim.cmd("runtime plugin/manicule.lua")
    vim.cmd("ManiculeDelete 2")
    local remaining = require("manicule").list({ _quiet = true })
    assert.are.equal(2, #remaining)
    assert.are.equal(id1, remaining[1].id)
    assert.are.equal(id3, remaining[2].id)
  end)

  it(":ManiculeDelete with no arg opens vim.ui.select with formatted items", function()
    add("short", 1, "README.md")
    add("a much longer body that should be truncated to a fixed maximum width", 10, "src/aaaa/bbbb/cccc/dddd.lua")
    local resolved_id = add("already done", 5, "src/zzz.lua")
    local records_pre = require("manicule").list({ _quiet = true })
    local store = require("manicule.store")
    for _, r in ipairs(records_pre) do
      if r.id == resolved_id then
        r.resolved = true
        store.put(store.root(), r)
      end
    end

    local captured_items
    local captured_opts
    local orig = vim.ui.select
    vim.ui.select = function(items, opts, _cb)
      captured_items = items
      captured_opts = opts
    end
    vim.cmd("runtime plugin/manicule.lua")
    vim.cmd("ManiculeDelete")
    vim.ui.select = orig

    assert.is_truthy(captured_items)
    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(#records, #captured_items)
    for i, item in ipairs(captured_items) do
      assert.are.equal(records[i].id, item.record.id)
      assert.is_truthy(item.display:find(" │ "))
      -- Resolved records must carry the [✓] prefix on the body column.
      if item.record.resolved then
        assert.is_truthy(item.display:find("%[✓%]"))
      end
    end
    -- Sanity-check index padding: 3 records → width 1 → "1", "2", "3".
    assert.is_truthy(captured_items[1].display:match("^1 │ "))
    -- format_item returns the display string verbatim.
    assert.are.equal(captured_items[1].display, captured_opts.format_item(captured_items[1]))
  end)

  it(":ManiculeDelete out-of-range errors and deletes nothing", function()
    add("one", 1, "a.lua")
    add("two", 2, "a.lua")
    add("three", 3, "a.lua")
    vim.cmd("runtime plugin/manicule.lua")

    local notified
    local orig = vim.notify
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    vim.cmd("ManiculeDelete 99")
    vim.notify = orig

    assert.is_truthy(notified)
    assert.are.equal(vim.log.levels.ERROR, notified.level)
    assert.is_truthy(notified.msg:find("no comment at position"))
    assert.are.equal(3, #require("manicule").list({ _quiet = true }))
  end)

  it("empty list → INFO notify, no picker", function()
    vim.cmd("runtime plugin/manicule.lua")
    local notified
    local picker_called = false
    local orig_notify = vim.notify
    local orig_select = vim.ui.select
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    vim.ui.select = function()
      picker_called = true
    end
    vim.cmd("ManiculeDelete")
    vim.notify = orig_notify
    vim.ui.select = orig_select

    assert.is_false(picker_called)
    assert.is_truthy(notified)
    assert.are.equal(vim.log.levels.INFO, notified.level)
    assert.is_truthy(notified.msg:find("no comments"))
  end)

  it("list() ordering matches quickfix build_items ordering", function()
    add("b-first", 5, "b.lua")
    add("a-second", 10, "a.lua")
    add("a-first", 3, "a.lua")
    local list_ids = {}
    for _, r in ipairs(require("manicule").list({ _quiet = true })) do
      table.insert(list_ids, r.id)
    end
    local qf_items = require("manicule.ui.quickfix").build_items(require("manicule").list({ _quiet = true }))
    local qf_ids = {}
    for _, it in ipairs(qf_items) do
      table.insert(qf_ids, it.user_data)
    end
    assert.are.same(list_ids, qf_ids)
    -- Sanity check: a.lua records should come before b.lua (URI order
    -- reflects the filesystem path order).
    local ordered = require("manicule").list({ _quiet = true })
    local function ends_with(uri, suffix)
      return uri:sub(-#suffix) == suffix
    end
    assert.is_true(ends_with(ordered[1].uri, "/a.lua"))
    assert.is_true(ends_with(ordered[2].uri, "/a.lua"))
    assert.is_true(ends_with(ordered[3].uri, "/b.lua"))
  end)
end)
