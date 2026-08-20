local H = require("helpers")

local ctx

local function fake_gh(dir, base_oid, head_oid)
  local bin = dir .. "/bin"
  vim.fn.mkdir(bin, "p")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    'if [ "$1 $2" = "repo view" ]; then',
    '  echo \'{"nameWithOwner":"acme/widgets"}\';',
    'elif [ "$1" = "api" ]; then',
    "  echo '[]';",
    "else",
    ('  echo \'{"baseRefOid":"%s","headRefOid":"%s"}\';'):format(base_oid, head_oid),
    "fi",
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return bin
end

---Fake gh on PATH answering `pr view`, `repo view`, and the PR review
---comments endpoint (`api .../comments --paginate`). Drop a
---`<home>/no-repo` marker to make `repo view` fail like gh does outside
---a GitHub remote.
local function fake_gh_pr(dir, opts)
  local home = dir .. "/gh-import"
  local bin = home .. "/bin"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({ opts.comments_json or "[]" }, home .. "/comments.json")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    "dir=" .. vim.fn.shellescape(home),
    'if [ "$1 $2" = "pr view" ]; then',
    ('  echo \'{"baseRefOid":"%s","headRefOid":"%s"}\';'):format(opts.base_oid, opts.head_oid),
    'elif [ "$1 $2" = "repo view" ]; then',
    '  if [ -f "$dir/no-repo" ]; then echo "gh: no GitHub remote" >&2; exit 1; fi;',
    '  echo \'{"nameWithOwner":"acme/widgets"}\';',
    'elif [ "$1" = "api" ]; then',
    '  case "$*" in',
    "  *--slurp*)",
    '    if [ -f "$dir/no-slurp" ]; then echo "unknown flag: --slurp" >&2; exit 1; fi;',
    "    printf '['; cat \"$dir/comments.json\"; printf ']';;",
    "  *)",
    '    cat "$dir/comments.json";;',
    "  esac;",
    "else",
    "  exit 2;",
    "fi",
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return {
    bin = bin,
    home = home,
    set_no_repo = function()
      vim.fn.writefile({ "" }, home .. "/no-repo")
    end,
    set_no_slurp = function()
      vim.fn.writefile({ "" }, home .. "/no-slurp")
    end,
  }
end

---A git repo with a checked-out PR branch plus a fake gh answering the
---comments endpoint with `comments` (default: one range comment and one
---outdated comment with line=null).
local function pr_repo_with_comments(comments)
  local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1", "-- two", "-- three", "-- four", "-- five" } })
  local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
  git("checkout", "-q", "-b", "pr-branch")
  vim.fn.writefile({ "return 2", "-- two", "-- three", "-- four", "-- five" }, root .. "/a.lua")
  git("commit", "-aqm", "pr change")
  local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)
  local gh = fake_gh_pr(ctx.artifact_root, {
    base_oid = base_oid,
    head_oid = head_oid,
    comments_json = vim.json.encode(comments or {
      {
        id = 1002,
        path = "a.lua",
        line = 4,
        start_line = 2,
        body = "range comment",
        html_url = "https://example.test/r/1002",
        user = { login = "octocat" },
      },
      {
        id = 1003,
        path = "a.lua",
        line = vim.NIL,
        original_line = vim.NIL,
        body = "outdated comment",
        html_url = "https://example.test/r/1003",
        user = { login = "ghost" },
      },
    }),
  })
  return root, git, gh
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

  it("resolves a remote-tracking ref via merge-base", function()
    local S = require("manicule.review.sources")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    -- Simulate a fetched remote branch with a ref under refs/remotes.
    git("update-ref", "refs/remotes/origin/main", vim.trim(git("rev-parse", "HEAD").stdout))
    git("checkout", "-q", "-b", "feature")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "feature work")

    local job = assert(S.resolve({ "origin/main" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s4" }))
    assert.are.equal("origin/main", job.label)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
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

  describe("pr comment import", function()
    local saved_path

    before_each(function()
      saved_path = vim.env.PATH
    end)
    after_each(function()
      vim.env.PATH = saved_path
      pcall(function()
        require("manicule.review").stop()
      end)
    end)

    it("imports PR review comments as records and skips line=null comments", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s5" })

      assert.is_nil(err)
      assert.is_truthy(job)
      local records = require("manicule.store").all(root)
      assert.are.equal(1, #records)
      local r = records[1]
      assert.are.equal(require("manicule.uri").for_path(root .. "/a.lua"), r.uri)
      assert.are.same({ start = { 1, 0 }, end_ = { 3, 0 } }, r.range)
      assert.are.equal("range comment", r.body)
      assert.are.equal("octocat", r.author)
      assert.are.equal("project", r.scope)
      assert.are.equal(root, r.project_root)
      assert.are.equal(1002, r.meta.github.id)
      assert.are.equal("https://example.test/r/1002", r.meta.github.url)
      assert.is_true(r.meta.github.imported)
    end)

    it("preserves comment bodies containing `][` byte-for-byte", function()
      local S = require("manicule.review.sources")
      local body = "see [ref][1] and t[1][2]"
      local root, _, gh = pr_repo_with_comments({
        {
          id = 2001,
          path = "a.lua",
          line = 1,
          body = body,
          html_url = "https://example.test/r/2001",
          user = { login = "octocat" },
        },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s10" }))

      local records = require("manicule.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal(body, records[1].body)
    end)

    it("falls back to manual paging when gh lacks --slurp", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments()
      gh.set_no_slurp()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s11" }))

      local records = require("manicule.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal("range comment", records[1].body)
    end)

    it("re-resolving the same PR does not duplicate imported records", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s6" }))
      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s7" }))

      assert.are.equal(1, #require("manicule.store").all(root))
    end)

    it("still returns a job when the comment fetch fails", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments()
      gh.set_no_repo()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s8" })

      assert.is_nil(err)
      assert.is_truthy(job)
      assert.are.equal(1, #job.files)
      assert.are.equal(0, #require("manicule.store").all(root))
    end)

    it("finish() batch excludes imported records", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local job = assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s9" }))
      assert.are.equal(1, #require("manicule.store").all(root))

      local sent
      require("manicule").register_sink({
        name = "capture",
        send = function(comments, _, cb)
          sent = comments
          cb(true)
        end,
      })

      local R = require("manicule.review")
      assert.is_true(R.start({ files = job.files, label = job.label, sink = "capture" }))

      -- Focus the right (worktree) window and add one local comment.
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].buftype ~= "quickfix" and vim.bo[bufnr].modifiable then
          vim.api.nvim_set_current_win(winid)
          break
        end
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ui = require("manicule.ui")
      local original_prompt = ui.prompt
      ui.prompt = function(_opts, cb)
        cb("local comment")
      end
      require("manicule").add()
      ui.prompt = original_prompt

      R.finish()
      vim.wait(500, function()
        return sent ~= nil
      end)
      R.stop()

      assert.is_truthy(sent)
      assert.are.equal(1, #sent)
      assert.are.equal("local comment", sent[1].body)
    end)
  end)
end)
