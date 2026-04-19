-- Exercises the reverse-map for nvim-runtime-staged buffer paths and
-- the `M.add` URI invariant canary.

local adapter
local uri_mod
local tmp_state
local tmp_root
local saved_home

local function project_subdir(name)
  local cwd = vim.loop.cwd() or vim.fn.getcwd()
  local base = vim.fs.normalize(vim.fn.fnamemodify(cwd .. "/" .. name, ":p"))
  vim.fn.mkdir(base, "p")
  return base
end

---Build a realistic-looking nvim-runtime staged path under the current
---`stdpath('run')`, creating the staged file with the given `body` so
---`fs_stat` succeeds. Mirrors what a tempname-based `:DiffTool` would
---produce.
local function make_staged_file(relative, body)
  local run = vim.fs.normalize(vim.fn.stdpath("run"))
  local bucket = run .. "/" .. tostring(math.random(1e9))
  local full = bucket .. "/" .. relative
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  vim.fn.writefile(body or { "" }, full)
  return full
end

local function setup_env()
  tmp_state = vim.fn.tempname()
  tmp_root = project_subdir(".manicule-reverse-map-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6)))
  vim.fn.mkdir(tmp_state, "p")
  vim.fn.mkdir(tmp_root .. "/.git", "p")

  -- Point HOME at a sandbox so the reverse-map's HOME fallback cannot
  -- collide with the runner's real `~/.config` tree.
  saved_home = vim.env.HOME
  local sandbox_home = vim.fn.tempname()
  vim.fn.mkdir(sandbox_home, "p")
  vim.env.HOME = sandbox_home

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
  pcall(vim.cmd, "only")
  pcall(vim.cmd, "enew!")
  pcall(vim.fn.delete, tmp_state, "rf")
  pcall(vim.fn.delete, tmp_root, "rf")
  if saved_home ~= nil then
    local cur_home = vim.env.HOME
    vim.env.HOME = saved_home
    if cur_home and cur_home ~= saved_home then
      pcall(vim.fn.delete, cur_home, "rf")
    end
  end
end

describe("manicule.uri nvim-runtime shape detection", function()
  it("is_nvim_runtime_staged_path matches the nvim.<user>/<run-id>/<N>/... shape", function()
    local uri = require("manicule.uri")
    assert.is_true(uri.is_nvim_runtime_staged_path("/var/folders/xx/yy/T/nvim.user/ABCDEF/1/.config/foo.txt"))
    assert.is_true(uri.is_nvim_runtime_staged_path("/private/var/folders/xx/yy/T/nvim.user/ABCDEF/1/src/foo.lua"))
    -- Three segments after the temp prefix but not matching nvim.<user>:
    -- must reject.
    assert.is_false(uri.is_nvim_runtime_staged_path("/var/folders/xx/yy/T/other/aaa/bbb/src.lua"))
    -- Plain /tmp file:
    assert.is_false(uri.is_nvim_runtime_staged_path("/tmp/foo.txt"))
    -- Not a temp path at all:
    assert.is_false(uri.is_nvim_runtime_staged_path("/Users/me/src/repo/file.lua"))
  end)
end)

describe("manicule.adapter reverse-map", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("reverse-maps a staged path to the real project file when unique", function()
    -- Create a real file inside tmp_root so the reverse-map has
    -- exactly one candidate under the project root.
    vim.fn.mkdir(tmp_root .. "/.config/cmux", "p")
    vim.fn.writefile({ "hello" }, tmp_root .. "/.config/cmux/settings.json")
    local staged = make_staged_file(".config/cmux/settings.json", { "hello" })

    -- cd into tmp_root so `vim.fs.root(0, ...)` has a chance at the
    -- marker (we also push the project root explicitly via `store`).
    local prev_cwd = vim.loop.cwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))

    vim.cmd.edit(vim.fn.fnameescape(staged))
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(err)
    assert.is_truthy(id)
    -- URI anchors to the real file inside the project root, NOT the
    -- staged path.
    local expected = vim.uri_from_fname(vim.fs.normalize(tmp_root .. "/.config/cmux/settings.json"))
    assert.are.equal(expected, id.uri)
    assert.is_true(id.is_writable)
    assert.are.equal("project", id.scope)

    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(prev_cwd))
  end)

  it("rejects when the reverse-map has no on-disk candidate", function()
    -- Stage a file whose suffix does NOT exist anywhere below the
    -- project root / cwd / HOME.
    local staged = make_staged_file("nonexistent/deep/path/does-not-exist.lua", { "x" })
    local prev_cwd = vim.loop.cwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))

    vim.cmd.edit(vim.fn.fnameescape(staged))
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(id)
    assert.is_truthy(err)
    assert.is_truthy(err:match("could not map to a real file"))

    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(prev_cwd))
  end)

  it("rejects when the reverse-map is ambiguous", function()
    -- Reverse-map looks at `vim.fs.root(0, …)`, `vim.fn.getcwd()`, and
    -- `$HOME` (dotfile-suffix only). Plant the same suffix under both
    -- cwd AND the sandbox HOME and pick a dotfile suffix so the HOME
    -- fallback engages — that guarantees two distinct candidates.
    vim.fn.mkdir(tmp_root .. "/.config/ambig", "p")
    vim.fn.writefile({ "a" }, tmp_root .. "/.config/ambig/x.txt")
    vim.fn.mkdir(vim.env.HOME .. "/.config/ambig", "p")
    vim.fn.writefile({ "b" }, vim.env.HOME .. "/.config/ambig/x.txt")

    local staged = make_staged_file(".config/ambig/x.txt", { "c" })
    local prev_cwd = vim.loop.cwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))

    vim.cmd.edit(vim.fn.fnameescape(staged))
    local bufnr = vim.api.nvim_get_current_buf()
    local id, err = adapter.identify(bufnr)
    assert.is_nil(id)
    assert.is_truthy(err)
    assert.is_truthy(err:match("ambiguous reverse%-map"))

    pcall(vim.cmd, "cd " .. vim.fn.fnameescape(prev_cwd))
  end)
end)

describe("manicule M.add invariant canary", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("refuses to persist when identify is injected to diverge", function()
    local manicule = require("manicule")
    local store = require("manicule.store")
    local adapter_mod = require("manicule.adapter")
    vim.cmd.edit(tmp_root .. "/canary.lua")
    local bufnr = vim.api.nvim_get_current_buf()

    -- Drive the whole record build, then swap `identify` at the last
    -- moment so the post-build verification sees a different URI and
    -- the canary fires. (The canary runs inline in M.add, so we patch
    -- after the initial identify call happened.)
    local orig_identify = adapter_mod.identify
    local call = 0
    adapter_mod.identify = function(b)
      call = call + 1
      if call == 1 then
        return orig_identify(b)
      end
      local id = orig_identify(b)
      if id then
        id = vim.deepcopy(id)
        id.uri = "file:///this/is/a/different/uri.lua"
      end
      return id
    end

    local notifications = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, lvl)
      table.insert(notifications, { msg = msg, level = lvl })
    end

    manicule.add({ body = "canary", range = { start = { 0, 0 }, end_ = { 0, 0 } } })

    adapter_mod.identify = orig_identify
    vim.notify = orig_notify

    -- No record should have landed.
    local root = store.root()
    if root then
      assert.are.equal(0, #store.all(root))
    end
    assert.are.equal(0, #store.session_all())

    -- An ERROR-level notify with the invariant message should have
    -- fired.
    local matched = false
    for _, n in ipairs(notifications) do
      if type(n.msg) == "string" and n.msg:match("URI invariant violated") then
        matched = true
        break
      end
    end
    assert.is_true(matched)
  end)
end)
