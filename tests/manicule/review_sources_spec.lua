local H = require("helpers")

local ctx

local function fake_gh(dir, base_oid, head_oid)
  local bin = dir .. "/bin"
  vim.fn.mkdir(bin, "p")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    ('echo \'{"baseRefOid":"%s","headRefOid":"%s"}\''):format(base_oid, head_oid),
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return bin
end

describe("manicule review sources", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("resolves a bare invocation to HEAD-vs-worktree", function()
    local S = require("manicule.review.sources")
    local root = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")

    local job = assert(S.resolve({}, { cwd = root, stage_dir = ctx.artifact_root .. "/s1" }))
    assert.are.equal("HEAD", job.label)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
    assert.are.equal(root .. "/a.lua", job.files[1].right)
  end)

  it("resolves a branch name via merge-base (only your changes)", function()
    local S = require("manicule.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    -- main moves ahead AFTER we branch; its change must not appear.
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "feature work")
    git("checkout", "-q", "main")
    vim.fn.writefile({ "-- main moved" }, root .. "/main-only.lua")
    git("add", "main-only.lua")
    git("commit", "-qm", "main work")
    git("checkout", "-q", "feature")

    local job = assert(S.resolve({ "main" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s2" }))
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
  end)

  it("resolves two directories without git", function()
    local S = require("manicule.review.sources")
    local left = ctx.artifact_root .. "/L"
    local right = ctx.artifact_root .. "/R"
    vim.fn.mkdir(left .. "/sub", "p")
    vim.fn.mkdir(right .. "/sub", "p")
    vim.fn.writefile({ "old" }, left .. "/sub/m.txt")
    vim.fn.writefile({ "new" }, right .. "/sub/m.txt")
    vim.fn.writefile({ "same" }, left .. "/same.txt")
    vim.fn.writefile({ "same" }, right .. "/same.txt")
    vim.fn.writefile({ "gone" }, left .. "/gone.txt")
    vim.fn.writefile({ "added" }, right .. "/added.txt")

    local job = assert(S.resolve({ left, right }, {}))
    local by_path = {}
    for _, pair in ipairs(job.files) do
      by_path[pair.path] = pair.status
    end
    assert.are.equal("M", by_path["sub/m.txt"])
    assert.are.equal("D", by_path["gone.txt"])
    assert.are.equal("A", by_path["added.txt"])
    assert.is_nil(by_path["same.txt"])
  end)

  it("errors outside a git repo for ref arguments", function()
    local S = require("manicule.review.sources")
    local job, err = S.resolve({ "main" }, { cwd = ctx.artifact_root })
    assert.is_nil(job)
    assert.is_truthy(err)
  end)

  it("resolves pr <n> via gh with head checked out", function()
    local S = require("manicule.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    git("checkout", "-q", "-b", "pr-branch")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "pr change")
    local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)

    local bin = fake_gh(ctx.artifact_root, base_oid, head_oid)
    local saved_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. saved_path

    local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s3" })
    vim.env.PATH = saved_path

    assert.is_nil(err)
    assert.are.equal("pr 42", job.label)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
    assert.are.equal(root .. "/a.lua", job.files[1].right)
  end)
end)
