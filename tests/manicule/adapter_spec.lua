-- Exercises `manicule.adapter` — temp-prefix detection, diff-pair
-- resolution, and `identify()` round-trips.

local adapter
local uri_mod
local tmp_state
local tmp_root

---Return a subdirectory under the test's current working directory so
---tests can create "working-tree" files that do NOT sit under a temp
---prefix (the adapter's heuristic rejects /tmp, /var/folders/..., and
---their /private/... aliases). `vim.fn.tempname()` on macOS always
---lives under `/var/folders/...`, which would make a working-tree
---buffer look like a reference side to the heuristic.
local function project_subdir(name)
  local base = vim.fs.normalize(vim.fn.fnamemodify(vim.loop.cwd() .. "/" .. name, ":p"))
  vim.fn.mkdir(base, "p")
  return base
end

local function setup_env()
  tmp_state = vim.fn.tempname()
  tmp_root = project_subdir(".manicule-test-root-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6)))
  vim.fn.mkdir(tmp_state, "p")
  vim.fn.mkdir(tmp_root .. "/.git", "p")

  require("manicule.store")._reset()
  require("manicule").setup({
    store = {
      dir = tmp_state .. "/",
      format = "json",
      canonicalize_symlinks = false,
    },
  })
  adapter = require("manicule.adapter")
  uri_mod = require("manicule.uri")
end

local function teardown_env()
  require("manicule.store")._reset()
  -- Reset to a single window with a nameless scratch so the next test
  -- doesn't inherit diff windows from the previous one.
  pcall(vim.cmd, "only")
  pcall(vim.cmd, "enew!")
  pcall(vim.fn.delete, tmp_state, "rf")
  pcall(vim.fn.delete, tmp_root, "rf")
end

describe("manicule.adapter temp detection", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("resolve_diff_pair returns nil when fewer than 2 diff windows", function()
    vim.cmd.edit(tmp_root .. "/a.lua")
    local bufnr = vim.api.nvim_get_current_buf()
    local pair, err = adapter.resolve_diff_pair(bufnr)
    assert.is_nil(pair)
    assert.is_nil(err)
  end)

  it("resolve_diff_pair returns nil+err when both diff windows are real (non-temp)", function()
    -- Plain `nvim -d a.lua b.lua` — both non-temp, ambiguous per spec.
    vim.cmd.edit(tmp_root .. "/a.lua")
    vim.cmd.diffthis()
    vim.cmd.vsplit(tmp_root .. "/b.lua")
    vim.cmd.diffthis()

    local cur = vim.api.nvim_get_current_buf()
    local pair, err = adapter.resolve_diff_pair(cur)
    assert.is_nil(pair)
    assert.are.equal("ambiguous diff pair", err)
  end)

  it("resolve_diff_pair identifies the temp side when one buffer sits under /tmp", function()
    -- /tmp on macOS resolves through /private/tmp, so compose the
    -- reference path with fs.normalize to match the heuristic.
    local temp_dir = "/tmp/git-blob-manicule-test"
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/ref.lua"
    vim.fn.writefile({ "ref" }, temp_file)

    local working = tmp_root .. "/working.lua"
    vim.fn.writefile({ "working" }, working)

    vim.cmd.edit(working)
    local working_bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()
    vim.cmd("vsplit " .. vim.fn.fnameescape(temp_file))
    local ref_bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()

    local pair = adapter.resolve_diff_pair(ref_bufnr)
    assert.is_truthy(pair)
    assert.are.equal(working_bufnr, pair.working_bufnr)
    assert.are.equal(ref_bufnr, pair.reference_bufnr)
    assert.are.equal(uri_mod.for_bufnr(working_bufnr), pair.working_uri)

    pcall(vim.fn.delete, temp_dir, "rf")
  end)

  it("identify returns project identity on a plain file buffer", function()
    vim.cmd.edit(tmp_root .. "/note.lua")
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(err)
    assert.is_truthy(id)
    assert.are.equal("project", id.scope)
    assert.is_true(id.is_writable)
    assert.is_nil(id.diff_side)
    assert.are.equal(uri_mod.for_bufnr(bufnr), id.uri)
  end)

  it("identify returns nil+err for a buffer without a bufname", function()
    vim.cmd.enew()
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(id)
    assert.is_truthy(err)
  end)

  it("identify refuses add on the reference side of a git diff pair", function()
    local temp_dir = "/tmp/git-blob-manicule-test2"
    vim.fn.mkdir(temp_dir, "p")
    local temp_file = temp_dir .. "/ref.lua"
    vim.fn.writefile({ "ref" }, temp_file)

    local working = tmp_root .. "/working2.lua"
    vim.fn.writefile({ "working" }, working)

    vim.cmd.edit(working)
    local working_bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()
    vim.cmd("vsplit " .. vim.fn.fnameescape(temp_file))
    local ref_bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()

    local id = adapter.identify(ref_bufnr)
    assert.is_truthy(id)
    assert.are.equal("reference", id.diff_side)
    assert.is_false(id.is_writable)
    assert.is_truthy(id.reject_reason)
    -- URI anchors to the working-tree side, not the temp file.
    assert.are.equal(uri_mod.for_bufnr(working_bufnr), id.uri)

    -- And the working-tree side IS writable with diff_side = working.
    local wid = adapter.identify(working_bufnr)
    assert.is_truthy(wid)
    assert.are.equal("working", wid.diff_side)
    assert.is_true(wid.is_writable)

    pcall(vim.fn.delete, temp_dir, "rf")
  end)

  it("identify in plain nvim -d treats each buffer as its own identity", function()
    -- Both sides are real paths → no pair → each buffer returns a
    -- writable project identity.
    vim.cmd.edit(tmp_root .. "/left.lua")
    local left = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()
    vim.cmd.vsplit(tmp_root .. "/right.lua")
    local right = vim.api.nvim_get_current_buf()
    vim.cmd.diffthis()

    local lid = adapter.identify(left)
    local rid = adapter.identify(right)
    assert.is_truthy(lid)
    assert.is_truthy(rid)
    assert.is_true(lid.is_writable)
    assert.is_true(rid.is_writable)
    assert.is_nil(lid.diff_side)
    assert.is_nil(rid.diff_side)
    assert.are_not.equal(lid.uri, rid.uri)
  end)
end)
