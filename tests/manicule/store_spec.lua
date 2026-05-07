-- Exercises the session-scope store round-trip and a few invariants of
-- the polymorphic dispatcher (project + session merge semantics).

local tmp_state
local tmp_root

local function setup_env()
  tmp_state = vim.fn.tempname()
  tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_state, "p")
  vim.fn.mkdir(tmp_root, "p")
  vim.fn.mkdir(tmp_root .. "/.git", "p")

  require("manicule.store")._reset()
  require("manicule").setup({
    store = {
      dir = tmp_state .. "/",
      format = "json",
      canonicalize_symlinks = false,
    },
  })
end

local function teardown_env()
  require("manicule.store")._reset()
  pcall(vim.fn.delete, tmp_state, "rf")
  pcall(vim.fn.delete, tmp_root, "rf")
end

describe("manicule.store session scope", function()
  before_each(setup_env)
  after_each(teardown_env)

  it("session_put then session_save lands records on disk and reloads", function()
    local store = require("manicule.store")
    local uv = vim.uv or vim.loop

    local record = {
      id = "abc123",
      uri = "term://foo/1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "session note",
      author = "t@example.com",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    }
    store.session_put(record)
    local ok, err = store.session_save()
    assert.is_true(ok)
    assert.is_nil(err)

    -- File exists.
    assert.is_truthy(uv.fs_stat(store.session_path()))

    -- Reset cache and reload — records should come back.
    store._reset()
    local reloaded = store.session_all()
    assert.are.equal(1, #reloaded)
    assert.are.equal("abc123", reloaded[1].id)
    assert.are.equal("session note", reloaded[1].body)
    assert.are.equal("term://foo/1", reloaded[1].uri)

    -- session_for_uri filters.
    local hits = store.session_for_uri("term://foo/1")
    assert.are.equal(1, #hits)
    assert.are.equal("abc123", hits[1].id)

    assert.are.same({}, store.session_for_uri("file:///nope"))
  end)

  it("writes versioned envelopes and reads legacy bare arrays", function()
    local store = require("manicule.store")
    local legacy = {
      {
        id = "legacy",
        uri = "term://legacy/1",
        scope = "session",
        range = { start = { 0, 0 }, end_ = { 0, 0 } },
        body = "from old store",
        author = "",
        created_at = 0,
        updated_at = 0,
        resolved = false,
        meta = {},
      },
    }

    vim.fn.writefile({ vim.json.encode(legacy) }, store.session_path())
    store._reset()

    local reloaded = store.session_all()
    assert.are.equal(1, #reloaded)
    assert.are.equal("legacy", reloaded[1].id)

    store.session_mark_dirty()
    assert.is_true(store.session_save())

    local encoded = table.concat(vim.fn.readfile(store.session_path()), "\n")
    local payload = vim.json.decode(encoded)
    assert.are.equal(store.schema_version(), payload.version)
    assert.are.equal("legacy", payload.records[1].id)
  end)

  it("session_remove drops the record and survives save/reload", function()
    local store = require("manicule.store")
    store.session_put({
      id = "one",
      uri = "file:///a",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "a",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_put({
      id = "two",
      uri = "file:///b",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "b",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_save()
    assert.are.equal(2, #store.session_all())

    local removed = store.session_remove("one")
    assert.is_truthy(removed)
    assert.are.equal("one", removed.id)
    store.session_save()

    store._reset()
    local reloaded = store.session_all()
    assert.are.equal(1, #reloaded)
    assert.are.equal("two", reloaded[1].id)
  end)

  it("put_record routes by scope", function()
    local store = require("manicule.store")
    local proj = {
      id = "p1",
      uri = "file://" .. tmp_root .. "/x.lua",
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "proj",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    }
    local sess = {
      id = "s1",
      uri = "term://1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "sess",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    }
    store.put_record(proj)
    store.put_record(sess)
    assert.are.equal(proj, store.get(tmp_root, "p1"))
    assert.are.equal(1, #store.session_all())
    assert.are.equal("s1", store.session_all()[1].id)
  end)

  it("flush_all flushes both caches", function()
    local store = require("manicule.store")
    local uv = vim.uv or vim.loop
    store.put(tmp_root, {
      id = "p1",
      uri = "file://" .. tmp_root .. "/a.lua",
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "a",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_put({
      id = "s1",
      uri = "term://1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "b",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.flush_all()
    assert.is_truthy(uv.fs_stat(store.path(tmp_root)))
    assert.is_truthy(uv.fs_stat(store.session_path()))
  end)

  it("all_for_uri merges project + session records keyed on same URI", function()
    local store = require("manicule.store")
    -- Point store.root() at the fake root by opening a buffer inside
    -- it, so all_for_uri's root resolution lands here. The buffer's
    -- resolved root may canonicalize differently from `tmp_root`
    -- (macOS aliases /var/folders ↔ /private/var/folders), so grab
    -- whatever `store.root()` resolves to and use that as the key.
    vim.cmd.edit(tmp_root .. "/merge.lua")
    local resolved_root = store.root()
    assert.is_truthy(resolved_root)
    local uri = require("manicule.uri").for_bufnr(0)
    store.put(resolved_root, {
      id = "p",
      uri = uri,
      scope = "project",
      project_root = resolved_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "project",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_put({
      id = "s",
      uri = uri,
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "session",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    local merged = store.all_for_uri(uri)
    assert.are.equal(2, #merged)
    local ids = { merged[1].id, merged[2].id }
    table.sort(ids)
    assert.are.same({ "p", "s" }, ids)
  end)

  it("all_for_uri accepts an explicit project root for non-current buffers", function()
    local store = require("manicule.store")
    local uri = require("manicule.uri").for_path(tmp_root .. "/target.lua")
    store.put(tmp_root, {
      id = "p",
      uri = uri,
      scope = "project",
      project_root = tmp_root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "project",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })
    store.session_put({
      id = "s",
      uri = uri,
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "session",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = {},
    })

    vim.cmd.enew()

    local explicit = store.all_for_uri(uri, tmp_root)
    assert.are.equal(2, #explicit)

    local session_only = store.all_for_uri(uri, nil)
    assert.are.equal(1, #session_only)
    assert.are.equal("s", session_only[1].id)
  end)

  it("session_save keeps ephemeral unnamed-buffer records in memory but off disk", function()
    local store = require("manicule.store")
    store.session_put({
      id = "ephemeral",
      uri = "manicule://buffer/1/1",
      scope = "session",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = "scratch",
      author = "",
      created_at = 0,
      updated_at = 0,
      resolved = false,
      meta = { ephemeral = true },
    })

    local ok = store.session_save()
    assert.is_true(ok)
    assert.are.equal(1, #store.session_all())

    store._reset()
    assert.are.equal(0, #store.session_all())
  end)
end)
