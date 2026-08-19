local H = require("helpers")

local ctx

describe("manicule review git plumbing", function()
  before_each(function()
    ctx = H.setup()
  end)
  after_each(function()
    H.teardown(ctx)
    ctx = nil
  end)

  it("lists modified, added, deleted, and untracked files vs a base", function()
    local G = require("manicule.review.git")
    local root, git = H.git_repo(ctx, {
      ["src/a.lua"] = { "return 1" },
      ["src/gone.lua"] = { "return 0" },
    })
    -- modify a.lua, delete gone.lua, add untracked new.lua
    vim.fn.writefile({ "return 2" }, root .. "/src/a.lua")
    vim.fn.delete(root .. "/src/gone.lua")
    vim.fn.writefile({ "return 3" }, root .. "/src/new.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local changed = assert(G.changed_files(root, base))
    local by_path = {}
    for _, entry in ipairs(changed) do
      by_path[entry.path] = entry.status
    end
    assert.are.equal("M", by_path["src/a.lua"])
    assert.are.equal("D", by_path["src/gone.lua"])
    assert.are.equal("A", by_path["src/new.lua"])
  end)

  it("stages baseline file versions into a directory", function()
    local G = require("manicule.review.git")
    local root = H.git_repo(ctx, { ["src/a.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/src/a.lua")
    vim.fn.writefile({ "return 3" }, root .. "/src/new.lua")

    local base = assert(G.rev_parse(root, "HEAD"))
    local dir = ctx.artifact_root .. "/staged"
    local files = G.stage_baseline(root, base, {
      { path = "src/a.lua", status = "M" },
      { path = "src/new.lua", status = "A" },
    }, dir)

    assert.are.equal(2, #files)
    local by_path = {}
    for _, pair in ipairs(files) do
      by_path[pair.path] = pair
    end
    -- Modified: left holds the committed content, right is the worktree file.
    assert.are.equal("return 1", table.concat(vim.fn.readfile(by_path["src/a.lua"].left), "\n"))
    assert.are.equal(root .. "/src/a.lua", by_path["src/a.lua"].right)
    -- Added: left is an empty staged file so diff shows all-added.
    assert.are.equal(0, vim.fn.getfsize(by_path["src/new.lua"].left))
  end)

  it("computes merge-base", function()
    local G = require("manicule.review.git")
    local root, git = H.git_repo(ctx, { ["a.txt"] = { "one" } })
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "two" }, root .. "/a.txt")
    git("commit", "-aqm", "feature change")
    local main = assert(G.rev_parse(root, "main"))
    local mb = assert(G.merge_base(root, "HEAD", "main"))
    assert.are.equal(main, mb)
  end)
end)
