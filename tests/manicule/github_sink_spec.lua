local H = require("helpers")

local ctx

---Fake gh on PATH: logs every argv line to `<dir>/gh/argv.log`, copies any
---`--input` file to `<dir>/gh/api-input.json`, and answers `pr view`,
---`repo view`, and `api` with canned JSON. Drop a `<dir>/gh/no-pr` marker
---to make `pr view` fail like gh does outside a PR branch.
local function fake_gh(dir)
  local home = dir .. "/gh"
  local bin = home .. "/bin"
  vim.fn.mkdir(bin, "p")
  local script = bin .. "/gh"
  vim.fn.writefile({
    "#!/bin/sh",
    "dir=" .. vim.fn.shellescape(home),
    'echo "$*" >> "$dir/argv.log"',
    'if [ "$1 $2" = "pr view" ]; then',
    '  if [ -f "$dir/no-pr" ]; then',
    '    echo "no pull requests found for branch" >&2; exit 1;',
    "  fi;",
    "  echo '{\"number\":42}';",
    'elif [ "$1 $2" = "repo view" ]; then',
    '  echo \'{"nameWithOwner":"acme/widgets"}\';',
    'elif [ "$1" = "api" ]; then',
    '  while [ "$#" -gt 0 ]; do',
    '    if [ "$1" = "--input" ]; then shift; cp "$1" "$dir/api-input.json"; fi;',
    "    shift;",
    "  done;",
    "  echo '{}';",
    "else",
    "  exit 2;",
    "fi",
  }, script)
  vim.fn.system({ "chmod", "+x", script })
  return {
    bin = bin,
    home = home,
    argv = function()
      local ok, lines = pcall(vim.fn.readfile, home .. "/argv.log")
      return ok and lines or {}
    end,
    api_input = function()
      return vim.json.decode(table.concat(vim.fn.readfile(home .. "/api-input.json"), "\n"))
    end,
    set_no_pr = function()
      vim.fn.writefile({ "" }, home .. "/no-pr")
    end,
  }
end

local function record(opts)
  opts = opts or {}
  return {
    body = opts.body or "needs a guard",
    project_root = opts.project_root or ctx.root,
    uri = opts.uri or ("file://" .. ctx.root .. "/src/a.lua"),
    range = opts.range or { start = { 4, 0 }, end_ = { 4, 0 } },
  }
end

local function send(spec, comments, send_ctx)
  local got_ok, got_err
  spec.send(comments, send_ctx or {}, function(ok, err)
    got_ok, got_err = ok, err
  end)
  vim.wait(2000, function()
    return got_ok ~= nil
  end)
  return got_ok, got_err
end

describe("manicule github sink", function()
  local saved_path

  before_each(function()
    ctx = H.setup()
    saved_path = vim.env.PATH
  end)
  after_each(function()
    vim.env.PATH = saved_path
    H.teardown(ctx)
    ctx = nil
  end)

  it("posts a PR review with correct JSON via gh api", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local ok, err = send(spec, { record({ body = "needs a guard" }) })

    assert.is_true(ok, err)
    local argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(argv:find("api repos/acme/widgets/pulls/42/reviews --method POST --input", 1, true))
    local body = gh.api_input()
    assert.are.equal("COMMENT", body.event)
    assert.are.equal(1, #body.comments)
    assert.are.equal("src/a.lua", body.comments[1].path)
    assert.are.equal(5, body.comments[1].line)
    assert.are.equal("RIGHT", body.comments[1].side)
    assert.are.equal("needs a guard", body.comments[1].body)
    assert.is_nil(body.comments[1].start_line)
  end)

  it("uses start_line + line for multi-line ranges", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local ok, err = send(spec, { record({ range = { start = { 4, 0 }, end_ = { 6, 0 } } }) })

    assert.is_true(ok, err)
    local comment = gh.api_input().comments[1]
    assert.are.equal(5, comment.start_line)
    assert.are.equal(7, comment.line)
    assert.are.equal("RIGHT", comment.side)
  end)

  it("honours opts.event and opts.pre_text", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({ event = "REQUEST_CHANGES", pre_text = "Please fix" })

    local ok, err = send(spec, { record() })

    assert.is_true(ok, err)
    local body = gh.api_input()
    assert.are.equal("REQUEST_CHANGES", body.event)
    assert.is_truthy(body.body:find("Please fix", 1, true))
  end)

  it("ctx.event overrides opts.event", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({ event = "COMMENT" })

    local ok, err = send(spec, { record() }, { event = "APPROVE" })

    assert.is_true(ok, err)
    assert.are.equal("APPROVE", gh.api_input().event)
  end)

  it("rejects an invalid ctx.event", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local ok, err = send(spec, { record() }, { event = "SHIP_IT" })

    assert.is_false(ok)
    assert.is_truthy(err:find("event", 1, true))
  end)

  it("rejects an invalid event at setup", function()
    local ok, err = pcall(function()
      require("manicule.sinks.github").setup({ event = "SHIP_IT" })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("event", 1, true))
  end)

  it("ctx.pr overrides gh pr view", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local ok, err = send(spec, { record() }, { pr = 7 })

    assert.is_true(ok, err)
    local argv = table.concat(gh.argv(), "\n")
    assert.is_nil(argv:find("pr view", 1, true))
    assert.is_truthy(argv:find("pulls/7/reviews", 1, true))
  end)

  it("fails with an actionable error when no PR exists for the branch", function()
    local gh = fake_gh(ctx.artifact_root)
    gh.set_no_pr()
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local ok, err = send(spec, { record() })

    assert.is_false(ok)
    assert.is_truthy(err:find("no open PR for this branch", 1, true))
    assert.is_truthy(err:find("ctx.pr", 1, true))
  end)

  it("skips unresolvable records and counts them in the review body", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local ok, err = send(spec, {
      record(),
      record({ body = "scratch note", uri = "term://scratch", project_root = nil }),
    })

    assert.is_true(ok, err)
    local body = gh.api_input()
    assert.are.equal(1, #body.comments)
    assert.are.equal("src/a.lua", body.comments[1].path)
    assert.is_truthy(body.body:find("1 skipped", 1, true))
  end)

  it("skips imported GitHub comments and counts them in the summary", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local imported = record({ body = "from github" })
    imported.meta = { github = { id = 9, url = "https://example.test/r/9", imported = true } }
    local ok, err = send(spec, { record(), imported })

    assert.is_true(ok, err)
    local body = gh.api_input()
    assert.are.equal(1, #body.comments)
    assert.are.equal("needs a guard", body.comments[1].body)
    assert.is_truthy(body.body:find("1 skipped: imported from GitHub", 1, true))
  end)

  it("posts meta.github_reply records via the replies endpoint", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local reply = record({ body = "sounds good" })
    reply.meta = { github_reply = { to = 9001, pr = 7 } }
    local ok, err = send(spec, { record(), reply })

    assert.is_true(ok, err)
    local argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(
      argv:find("api repos/acme/widgets/pulls/7/comments/9001/replies --method POST -f body=sounds good", 1, true)
    )
    local body = gh.api_input()
    assert.are.equal(1, #body.comments)
    assert.are.equal("needs a guard", body.comments[1].body)
    assert.is_truthy(body.body:find("1 thread reply", 1, true))
  end)

  it("sends a reply-only batch without posting a review", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local reply = record({ body = "will do" })
    reply.meta = { github_reply = { to = 9001 } }
    local ok, err = send(spec, { reply })

    assert.is_true(ok, err)
    local argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(
      argv:find("api repos/acme/widgets/pulls/42/comments/9001/replies --method POST -f body=will do", 1, true)
    )
    assert.is_nil(argv:find("/reviews", 1, true))
  end)

  it("fails when no record resolves to a repository path", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local ok, err = send(spec, { record({ uri = "term://scratch", project_root = nil }) })

    assert.is_false(ok)
    assert.is_truthy(err:find("resolvable", 1, true))
  end)

  it("validate fails without a gh executable", function()
    local emptybin = ctx.artifact_root .. "/emptybin"
    vim.fn.mkdir(emptybin, "p")
    vim.env.PATH = emptybin
    local spec = require("manicule.sinks.github").setup({})

    local ok, err = spec.validate({})

    assert.is_false(ok)
    assert.is_truthy(err:find("gh", 1, true))
  end)

  it("validate fails outside a git repository", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local nongit = ctx.artifact_root .. "/nongit"
    vim.fn.mkdir(nongit, "p")
    local ok, err = spec.validate({ cwd = nongit })

    assert.is_false(ok)
    assert.is_truthy(err:find("git", 1, true))
  end)

  it("registers as a builtin integration when gh is available", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    require("manicule.sinks")._reset()
    require("manicule.sinks").setup({ clipboard = false, cmux = false, socket = false })

    assert.are.same({ "github" }, require("manicule.sinks").list())
    local spec = require("manicule.sinks").get("github")
    assert.are.equal("integration", spec.type)
    assert.is_false(spec.clear_on_success)
  end)

  it("stays unregistered when gh is missing", function()
    local emptybin = ctx.artifact_root .. "/emptybin"
    vim.fn.mkdir(emptybin, "p")
    vim.env.PATH = emptybin
    require("manicule.sinks")._reset()
    require("manicule.sinks").setup({ clipboard = false, cmux = false, socket = false })

    assert.are.same({}, require("manicule.sinks").list())
  end)

  it("reports health with gh path", function()
    local gh = fake_gh(ctx.artifact_root)
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local spec = require("manicule.sinks.github").setup({})

    local health = spec.health()

    assert.is_true(health.available)
    assert.is_truthy(tostring(health.gh):find("/gh", 1, true))
  end)

  describe(":ManiculeSend verdicts", function()
    it("maps a verdict argument to ctx.event", function()
      vim.cmd("runtime plugin/manicule.lua")
      local calls = H.register_fake_sink("github")

      vim.cmd("ManiculeSend github approve")
      vim.wait(200, function()
        return #calls > 0
      end)

      assert.are.equal(1, #calls)
      assert.are.equal("APPROVE", calls[1].ctx.event)
    end)

    it("errors on an unknown verdict without dispatching", function()
      vim.cmd("runtime plugin/manicule.lua")
      local calls = H.register_fake_sink("github")

      local errored
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          errored = msg
        end
      end
      vim.cmd("ManiculeSend github ship-it")
      vim.notify = original_notify

      assert.is_truthy(errored, "expected an ERROR notification")
      assert.is_truthy(errored:find("ship-it", 1, true))
      assert.are.equal(0, #calls)
    end)

    it("completes the verdict words after `github `", function()
      vim.cmd("runtime plugin/manicule.lua")

      local comps = vim.fn.getcompletion("ManiculeSend github ", "cmdline")
      table.sort(comps)

      assert.are.same({ "approve", "comment", "request-changes" }, comps)
    end)

    it("still completes sink names for the first argument", function()
      vim.cmd("runtime plugin/manicule.lua")
      H.register_fake_sink("github")

      local comps = vim.fn.getcompletion("ManiculeSend ", "cmdline")

      assert.are.same({ "github" }, comps)
    end)
  end)
end)
