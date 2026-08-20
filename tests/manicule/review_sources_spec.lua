local H = require("helpers")

local ctx

local function fake_gh(dir, base_oid, head_oid, title)
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
    ('  echo \'{"baseRefOid":"%s","headRefOid":"%s","title":"%s"}\';'):format(base_oid, head_oid, title or ""),
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
  local default_threads = vim.json.encode({
    data = { repository = { pullRequest = { reviewThreads = { nodes = {} } } } },
  })
  vim.fn.writefile({ opts.threads_json or default_threads }, home .. "/threads.json")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    "dir=" .. vim.fn.shellescape(home),
    'if [ "$1 $2" = "pr view" ]; then',
    ('  echo \'{"baseRefOid":"%s","headRefOid":"%s"}\';'):format(opts.base_oid, opts.head_oid),
    'elif [ "$1 $2" = "repo view" ]; then',
    '  if [ -f "$dir/no-repo" ]; then echo "gh: no GitHub remote" >&2; exit 1; fi;',
    '  echo \'{"nameWithOwner":"acme/widgets"}\';',
    'elif [ "$1 $2" = "api graphql" ]; then',
    '  if [ -f "$dir/no-graphql" ]; then echo "gh: graphql boom" >&2; exit 1; fi;',
    '  case "$*" in',
    "  *cursor=CURSOR_PAGE_2*)",
    '    cat "$dir/threads2.json";;',
    "  *)",
    '    cat "$dir/threads.json";;',
    "  esac;",
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
    set_no_graphql = function()
      vim.fn.writefile({ "" }, home .. "/no-graphql")
    end,
    set_threads = function(nodes)
      vim.fn.writefile({
        vim.json.encode({ data = { repository = { pullRequest = { reviewThreads = { nodes = nodes } } } } }),
      }, home .. "/threads.json")
    end,
    -- Two GraphQL pages: page 1 advertises hasNextPage with the cursor
    -- the fake script branches on, page 2 is final.
    set_thread_pages = function(page1_nodes, page2_nodes)
      vim.fn.writefile({
        vim.json.encode({
          data = {
            repository = {
              pullRequest = {
                reviewThreads = {
                  pageInfo = { hasNextPage = true, endCursor = "CURSOR_PAGE_2" },
                  nodes = page1_nodes,
                },
              },
            },
          },
        }),
      }, home .. "/threads.json")
      vim.fn.writefile({
        vim.json.encode({
          data = {
            repository = {
              pullRequest = {
                reviewThreads = {
                  pageInfo = { hasNextPage = false },
                  nodes = page2_nodes,
                },
              },
            },
          },
        }),
      }, home .. "/threads2.json")
    end,
  }
end

---A git repo with a checked-out PR branch plus a fake gh answering the
---comments endpoint with `comments` (default: one range comment and one
---outdated comment with line=null).
local function pr_repo_with_comments(comments, threads)
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
    threads_json = threads and vim.json.encode({
      data = { repository = { pullRequest = { reviewThreads = { nodes = threads } } } },
    }) or nil,
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

    local bin = fake_gh(ctx.artifact_root, base_oid, head_oid, "Fix the frobnicator")
    local saved_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. saved_path

    local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s3" })
    vim.env.PATH = saved_path

    assert.is_nil(err)
    assert.are.equal("pr 42: Fix the frobnicator", job.label)
    -- The PR number must reach the session's sink context, or
    -- :ManiculeReviewFinish github falls back to `gh pr view` on the
    -- current branch and posts to the wrong PR.
    assert.are.same({ pr = 42 }, job.sink_ctx)
    assert.are.equal(1, #job.files)
    assert.are.equal("a.lua", job.files[1].path)
    assert.are.equal(root .. "/a.lua", job.files[1].right)
  end)

  it("resolves pr <n> with head not checked out, staging literal C-quotable paths", function()
    local S = require("manicule.review.sources")
    local root, git = H.git_repo(ctx, { ["å.txt"] = { "base content" } })
    local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    git("checkout", "-q", "-b", "pr-branch")
    vim.fn.writefile({ "head content" }, root .. "/å.txt")
    git("commit", "-aqm", "pr change")
    local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    -- Review the PR WITHOUT checking it out: both sides get staged.
    git("checkout", "-q", "main")

    local bin = fake_gh(ctx.artifact_root, base_oid, head_oid)
    local saved_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. saved_path

    local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s19" })
    vim.env.PATH = saved_path

    assert.is_nil(err)
    assert.are.same({ pr = 42 }, job.sink_ctx)
    assert.are.equal(1, #job.files)
    -- With core.quotePath=true a non -z diff reports `"\303\245.txt"`;
    -- the staged pair must use the literal path on both sides.
    assert.are.equal("å.txt", job.files[1].path)
    assert.are.equal("M", job.files[1].status)
    assert.are.equal("base content", table.concat(vim.fn.readfile(job.files[1].left), "\n"))
    assert.are.equal("head content", table.concat(vim.fn.readfile(job.files[1].right), "\n"))
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

    it("records thread ids and the PR number on imported comments", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments({
        {
          id = 1002,
          path = "a.lua",
          line = 2,
          body = "thread root",
          html_url = "https://example.test/r/1002",
          user = { login = "octocat" },
        },
        {
          id = 1004,
          path = "a.lua",
          line = 2,
          in_reply_to_id = 1002,
          body = "a reply",
          html_url = "https://example.test/r/1004",
          user = { login = "hubber" },
        },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s12" }))

      local by_id = {}
      for _, r in ipairs(require("manicule.store").all(root)) do
        by_id[r.meta.github.id] = r
      end
      assert.are.equal(1002, by_id[1002].meta.github.thread_id)
      assert.are.equal(1002, by_id[1004].meta.github.thread_id)
      assert.are.equal(42, by_id[1002].meta.github.pr)
    end)

    it("maps review thread node ids and resolved flags onto imported records", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments(nil, {
        { id = "RT_1", isResolved = true, comments = { nodes = { { databaseId = 1002 } } } },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s13" }))

      local records = require("manicule.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal("RT_1", records[1].meta.github.thread_node)
      assert.is_true(records[1].meta.github.resolved)
    end)

    it("imports without resolve support when the thread query fails", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments()
      gh.set_no_graphql()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local warned
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
          warned = msg
        end
        return original_notify(msg, level)
      end
      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s14" })
      vim.notify = original_notify

      assert.is_nil(err)
      assert.is_truthy(job)
      assert.is_truthy(warned, "expected a WARN about resolve support")
      local records = require("manicule.store").all(root)
      assert.are.equal(1, #records)
      assert.is_nil(records[1].meta.github.thread_node)
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

    it("skips LEFT-side and null-line comments instead of anchoring them to head lines", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments({
        {
          id = 3001,
          path = "a.lua",
          side = "RIGHT",
          line = 4,
          body = "head comment",
          html_url = "https://example.test/r/3001",
          user = { login = "octocat" },
        },
        {
          -- Anchored to base line 5: head line 5 is an unrelated line,
          -- so this must not import at head coordinates.
          id = 3002,
          path = "a.lua",
          side = "LEFT",
          line = 5,
          original_line = 5,
          body = "base-side comment",
          html_url = "https://example.test/r/3002",
          user = { login = "octocat" },
        },
        {
          -- Outdated position: line=null with original_line pointing at
          -- a superseded head commit — must not anchor via original_line.
          id = 3003,
          path = "a.lua",
          side = "RIGHT",
          line = vim.NIL,
          original_line = 3,
          body = "outdated comment",
          html_url = "https://example.test/r/3003",
          user = { login = "octocat" },
        },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      local notified = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        notified[#notified + 1] = msg
        return original_notify(msg, level)
      end
      local job, err = S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s17" })
      vim.notify = original_notify

      assert.is_nil(err)
      assert.is_truthy(job)
      local records = require("manicule.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal(3001, records[1].meta.github.id)
      assert.are.same({ start = { 3, 0 }, end_ = { 3, 0 } }, records[1].range)
      local summary
      for _, msg in ipairs(notified) do
        if msg:find("imported", 1, true) then
          summary = msg
        end
      end
      assert.is_truthy(summary, "expected an import summary notify")
      assert.is_truthy(summary:find("2 skipped", 1, true), "expected the skip count in: " .. summary)
    end)

    it("paginates review threads past the first GraphQL page", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments({
        {
          id = 1002,
          path = "a.lua",
          side = "RIGHT",
          line = 4,
          body = "second page thread",
          html_url = "https://example.test/r/1002",
          user = { login = "octocat" },
        },
      })
      gh.set_thread_pages({
        { id = "RT_1", isResolved = false, comments = { nodes = { { databaseId = 9999 } } } },
      }, {
        { id = "RT_2", isResolved = true, comments = { nodes = { { databaseId = 1002 } } } },
      })
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s18" }))

      local records = require("manicule.store").all(root)
      assert.are.equal(1, #records)
      assert.are.equal("RT_2", records[1].meta.github.thread_node)
      assert.is_true(records[1].meta.github.resolved)
    end)

    it("backfills thread data onto existing records on re-import", function()
      local S = require("manicule.review.sources")
      local root, _, gh = pr_repo_with_comments()
      vim.env.PATH = gh.bin .. ":" .. saved_path

      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s15" }))
      local store = require("manicule.store")
      local records = store.all(root)
      assert.are.equal(1, #records)
      assert.is_nil(records[1].meta.github.thread_node)

      gh.set_threads({
        { id = "RT_9", isResolved = true, comments = { nodes = { { databaseId = 1002 } } } },
      })
      assert(S.resolve({ "pr", "42" }, { cwd = root, stage_dir = ctx.artifact_root .. "/s16" }))

      records = store.all(root)
      assert.are.equal(1, #records)
      assert.are.equal("RT_9", records[1].meta.github.thread_node)
      assert.is_true(records[1].meta.github.resolved)

      -- Resolve now works on the backfilled record: RT_9 is resolved, so
      -- gr sends unresolveReviewThread and flips the local flag.
      require("manicule.review.github").toggle_resolve({ id = records[1].id, project_root = root })
      assert.is_false(store.get(root, records[1].id).meta.github.resolved)
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
