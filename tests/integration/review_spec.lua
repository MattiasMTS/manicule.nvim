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

describe("manicule review session", function()
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

  it("opens a diff pair with a protected left buffer", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "test" }))

    local wins = vim.api.nvim_tabpage_list_wins(0)
    assert.are.equal(2, #wins)
    local saw_left, saw_right = false, false
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      assert.is_true(vim.wo[win].diff)
      if name:find("/left/", 1, true) then
        saw_left = true
        assert.is_false(vim.bo[buf].modifiable)
      else
        saw_right = true
        assert.is_true(vim.bo[buf].modifiable)
      end
    end
    assert.is_true(saw_left)
    assert.is_true(saw_right)
  end)

  it("cycles pairs with next/prev and wraps", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "test" }))
    assert.are.equal(1, R.state().index)
    R.next()
    assert.are.equal(2, R.state().index)
    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("f2.lua", 1, true))
    R.next() -- wraps
    assert.are.equal(1, R.state().index)
    R.prev() -- wraps back
    assert.are.equal(2, R.state().index)
  end)

  it("stop() clears state and closes the session tab", function()
    local R = require("manicule.review")
    local tabs_before = #vim.api.nvim_list_tabpages()
    assert.is_true(R.start({ files = make_pairs(1), label = "test" }))
    R.stop()
    assert.is_nil(R.state())
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
  end)

  it("rejects an empty file list", function()
    local R = require("manicule.review")
    local ok, err = R.start({ files = {}, label = "test" })
    assert.is_false(ok)
    assert.is_truthy(err:find("no files", 1, true))
  end)

  it("finish() sends only the session's comments to the sink", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    -- A comment on a file OUTSIDE the review session must not be sent.
    local outside = ctx.root .. "/outside.lua"
    vim.fn.writefile({ "return 0" }, outside)

    local sent
    require("manicule").register_sink({
      name = "capture",
      send = function(comments, _, cb)
        sent = comments
        cb(true)
      end,
    })

    assert.is_true(R.start({ files = files, label = "test", sink = "capture" }))

    -- Comment on pair 1's worktree file (the current buffer after start).
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("session comment")
    end
    require("manicule").add()
    ui.prompt = original_prompt

    -- Comment on the outside file.
    vim.cmd.edit(vim.fn.fnameescape(outside))
    ui.prompt = function(_opts, cb)
      cb("outside comment")
    end
    require("manicule").add()
    ui.prompt = original_prompt

    R.finish()
    vim.wait(200, function()
      return sent ~= nil
    end)
    assert.is_truthy(sent)
    assert.are.equal(1, #sent)
    assert.are.equal("session comment", sent[1].body)
  end)

  it("finish() with no comments notifies and does not dispatch", function()
    local R = require("manicule.review")
    local called = false
    require("manicule").register_sink({
      name = "capture",
      send = function(_, _, cb)
        called = true
        cb(true)
      end,
    })
    assert.is_true(R.start({ files = make_pairs(1), label = "test", sink = "capture" }))
    R.finish()
    assert.is_false(called)
  end)

  it("start_from_job wires files, label, and the socket sink", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    local job_path = ctx.artifact_root .. "/job.json"
    vim.fn.writefile({
      vim.json.encode({
        id = "job-7",
        label = "since-review",
        return_socket = ctx.artifact_root .. "/return.sock",
        files = files,
      }),
    }, job_path)

    assert.is_true(R.start_from_job(job_path))
    local state = R.state()
    assert.are.equal("since-review", state.label)
    assert.are.equal("socket", state.sink)
    assert.are.equal(ctx.artifact_root .. "/return.sock", state.sink_ctx.socket)
    assert.are.equal("job-7", state.sink_ctx.job)
  end)

  it("start_from_job rejects unreadable or invalid job files", function()
    local R = require("manicule.review")
    local ok, err = R.start_from_job(ctx.artifact_root .. "/absent.json")
    assert.is_false(ok)
    assert.is_truthy(err)

    local bad = ctx.artifact_root .. "/bad.json"
    vim.fn.writefile({ "{not json" }, bad)
    local ok2, err2 = R.start_from_job(bad)
    assert.is_false(ok2)
    assert.is_truthy(err2)
  end)

  it(":ManiculeReview <ref> starts a session via the git resolver", function()
    vim.cmd("runtime plugin/manicule.lua")
    local root = H.git_repo(ctx, { ["cmd.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/cmd.lua")
    local saved = (vim.uv or vim.loop).cwd()
    vim.cmd.cd(root)

    vim.cmd("ManiculeReview HEAD")
    local state = require("manicule.review").state()
    vim.cmd.cd(saved)

    assert.is_truthy(state)
    assert.are.equal("HEAD", state.label)
    assert.are.equal(1, #state.files)
    assert.are.equal("cmd.lua", state.files[1].path)
  end)

  it("deleted-file (D) pairs accept comments on the left buffer", function()
    vim.cmd("runtime plugin/manicule.lua")
    local root = H.git_repo(ctx, { ["gone.lua"] = { "return 1" } })
    -- Delete the file from worktree so git resolver stages status=D.
    vim.fn.delete(root .. "/gone.lua")
    local saved = (vim.uv or vim.loop).cwd()
    vim.cmd.cd(root)

    vim.cmd("ManiculeReview HEAD")
    local state = require("manicule.review").state()
    assert.is_truthy(state)
    assert.are.equal(1, #state.files)
    assert.are.equal("D", state.files[1].status)

    -- Current buffer is the left (staged baseline) for the D pair.
    -- Fake prompt and add a comment.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("deleted file note")
    end
    require("manicule").add()
    ui.prompt = original_prompt

    local records = require("manicule").list({ _quiet = true })
    assert.are.equal(1, #records)
    assert.are.equal("deleted file note", records[1].body)
    -- Scope is session because the staged left file path no longer
    -- matches the nvim-runtime pattern after sources.lua fix.
    assert.are.equal("session", records[1].scope)

    vim.cmd.cd(saved)
  end)
end)
