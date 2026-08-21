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
    -- 3 windows: 2 diff + 1 panel
    assert.are.equal(3, #wins)
    local saw_left, saw_right = false, false
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      -- Skip quickfix window
      if vim.bo[buf].buftype ~= "quickfix" then
        assert.is_true(vim.wo[win].diff)
        if name:find("/left/", 1, true) then
          saw_left = true
          assert.is_false(vim.bo[buf].modifiable)
        else
          saw_right = true
          assert.is_true(vim.bo[buf].modifiable)
        end
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

  it("maps <Tab>/<S-Tab> in review buffers and removes them on stop", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "tabnav" }))

    local right_buf = vim.fn.bufnr(R.state().files[1].right)
    assert.is_true(right_buf > 0, "right buffer not loaded")
    local function buf_map(bufnr, lhs)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if map.lhs:lower() == lhs:lower() then
          return map
        end
      end
      return nil
    end

    local tab_map = buf_map(right_buf, "<Tab>")
    assert.is_truthy(tab_map, "<Tab> not mapped in review buffer")
    assert.is_truthy(buf_map(right_buf, "<S-Tab>"), "<S-Tab> not mapped in review buffer")

    -- Invoking the mapping advances the pair.
    tab_map.callback()
    assert.are.equal(2, R.state().index)

    R.stop()
    assert.is_nil(buf_map(right_buf, "<Tab>"), "<Tab> map leaked past stop()")
    assert.is_nil(buf_map(right_buf, "<S-Tab>"), "<S-Tab> map leaked past stop()")
  end)

  it("stop() clears state and closes the session tab", function()
    local R = require("manicule.review")
    local tabs_before = #vim.api.nvim_list_tabpages()
    assert.is_true(R.start({ files = make_pairs(1), label = "test" }))
    R.stop()
    assert.is_nil(R.state())
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
  end)

  it("start() caches the session's root and uris once", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "cache" }))

    local state = R.state()
    local uri_mod = require("manicule.uri")
    local uri1 = uri_mod.for_path(files[1].right)
    local uri2 = uri_mod.for_path(files[2].right)
    -- Index-aligned array, membership set, and uri -> pair index map.
    assert.are.same({ uri1, uri2 }, state.uris)
    assert.is_true(state.uri_set[uri1])
    assert.is_true(state.uri_set[uri2])
    assert.are.equal(1, state.uri_index[uri1])
    assert.are.equal(2, state.uri_index[uri2])
    -- helpers.project_dir plants a .git marker in ctx.root.
    assert.are.equal(ctx.root, state.root)
  end)

  it("stop() deletes owned stage dirs and wipes buffers pointing into them", function()
    local R = require("manicule.review")
    -- Both sides staged, like a pr-head-not-checked-out session: the
    -- RIGHT buffer is a plain file buffer (no bufhidden=wipe), so stop()
    -- must wipe it before removing the files it points at.
    local stage = ctx.artifact_root .. "/owned-stage"
    local left = stage .. "/base/x.lua"
    local right = stage .. "/head/x.lua"
    vim.fn.mkdir(vim.fn.fnamemodify(left, ":h"), "p")
    vim.fn.mkdir(vim.fn.fnamemodify(right, ":h"), "p")
    vim.fn.writefile({ "return 1" }, left)
    vim.fn.writefile({ "return 2" }, right)
    local files = { { left = left, right = right, status = "M", path = "x.lua" } }

    assert.is_true(R.start({ files = files, label = "cleanup", stage_dirs = { stage } }))
    assert.is_true(vim.fn.bufnr(right) > 0, "right staged buffer not loaded")

    R.stop()

    assert.are.equal(0, vim.fn.isdirectory(stage), "owned stage dir survived stop()")
    assert.are.equal(-1, vim.fn.bufnr(right), "a buffer still points at a removed staged file")
  end)

  it("start_from_job leaves external stage dirs alone unless the job opts in", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    local dir = ctx.artifact_root .. "/driver-stage"
    vim.fn.mkdir(dir, "p")

    -- No stage_dirs in the job: the external driver owns its files.
    local job_a = ctx.artifact_root .. "/job-a.json"
    vim.fn.writefile({ vim.json.encode({ label = "ext", files = files }) }, job_a)
    assert.is_true(R.start_from_job(job_a))
    R.stop()
    assert.are.equal(1, vim.fn.isdirectory(dir), "stop() deleted a dir the session never owned")

    -- Opt-in: the job lists the dirs manicule should delete on stop.
    local job_b = ctx.artifact_root .. "/job-b.json"
    vim.fn.writefile({ vim.json.encode({ label = "ext", files = files, stage_dirs = { dir } }) }, job_b)
    assert.is_true(R.start_from_job(job_b))
    R.stop()
    assert.are.equal(0, vim.fn.isdirectory(dir), "opted-in stage dir survived stop()")
  end)

  it(":ManiculeReview HEAD owns its staged baseline dir and stop() removes it", function()
    vim.cmd("runtime plugin/manicule.lua")
    local root = H.git_repo(ctx, { ["own.lua"] = { "return 1" } })
    vim.fn.writefile({ "return 2" }, root .. "/own.lua")
    local saved = (vim.uv or vim.loop).cwd()
    vim.cmd.cd(root)
    vim.cmd("ManiculeReview HEAD")
    vim.cmd.cd(saved)

    local R = require("manicule.review")
    local state = assert(R.state(), "session did not start")
    assert.are.equal("table", type(state.stage_dirs))
    local dir = state.stage_dirs[1]
    assert.are.equal(1, vim.fn.isdirectory(dir))
    assert.are.equal(1, state.files[1].left:find(dir, 1, true))

    R.stop()
    assert.are.equal(0, vim.fn.isdirectory(dir), "staged baseline dir leaked past stop()")
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

    -- Find the right (non-qf) window and focus it
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype ~= "quickfix" and vim.bo[bufnr].modifiable then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end

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

  it(":ManiculeReview pr (bare) picks an open PR and labels with its title", function()
    vim.cmd("runtime plugin/manicule.lua")
    local root, git = H.git_repo(ctx, { ["a.lua"] = { "return 1" } })
    local base_oid = vim.trim(git("rev-parse", "HEAD").stdout)
    git("checkout", "-q", "-b", "pr-branch")
    vim.fn.writefile({ "return 2" }, root .. "/a.lua")
    git("commit", "-aqm", "pr change")
    local head_oid = vim.trim(git("rev-parse", "HEAD").stdout)

    -- Fake gh answering `pr list` (picker), `pr view` (resolver), and the
    -- comment-import endpoints.
    local bin = ctx.artifact_root .. "/bin"
    vim.fn.mkdir(bin, "p")
    vim.fn.writefile({
      "#!/bin/sh",
      'if [ "$1 $2" = "pr list" ]; then',
      '  echo \'[{"number":42,"title":"Add widgets","author":{"login":"octocat"}}]\';',
      'elif [ "$1 $2" = "pr view" ]; then',
      ('  echo \'{"baseRefOid":"%s","headRefOid":"%s","title":"Add widgets"}\';'):format(base_oid, head_oid),
      'elif [ "$1 $2" = "repo view" ]; then',
      '  echo \'{"nameWithOwner":"acme/widgets"}\';',
      "else",
      "  echo '[]';",
      "fi",
    }, bin .. "/gh")
    vim.fn.system({ "chmod", "+x", bin .. "/gh" })

    local saved_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. saved_path
    local saved_cwd = (vim.uv or vim.loop).cwd()
    vim.cmd.cd(root)

    local original_select = vim.ui.select
    local seen_item
    vim.ui.select = function(items, select_opts, on_choice)
      seen_item = select_opts.format_item(items[1])
      on_choice(items[1])
    end
    local ok, err = pcall(vim.cmd, "ManiculeReview pr")
    vim.ui.select = original_select
    vim.env.PATH = saved_path
    vim.cmd.cd(saved_cwd)
    assert.is_true(ok, err)

    assert.are.equal("#42 Add widgets \u{2014} octocat", seen_item)
    local state = require("manicule.review").state()
    assert.is_truthy(state, "picker did not start a session")
    assert.are.equal("pr 42: Add widgets", state.label)
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

  it("panel opens on start with file rows and focus returns to diff", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "panel-test" }))

    -- Panel should be open
    local found_panel = false
    local panel_winid
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype == "quickfix" then
        local ok, info = pcall(vim.fn.getqflist, { winid = winid, title = 1 })
        -- Plain find: `-` is a Lua pattern quantifier and would never
        -- match the literal hyphen in the title.
        if ok and info.title and info.title:find("manicule-review", 1, true) then
          found_panel = true
          panel_winid = winid
          break
        end
      end
    end
    assert.is_true(found_panel, "panel quickfix window not found")

    -- Focus should be in diff (non-qf window)
    local current_buf = vim.api.nvim_get_current_buf()
    assert.is_false(vim.bo[current_buf].buftype == "quickfix")

    -- Panel should have 2 rows (one per pair)
    local items = vim.fn.getqflist()
    assert.are.equal(2, #items)
    assert.is_truthy(items[1].text:find("f1.lua"))
    assert.is_truthy(items[1].text:find("0 comments"))
  end)

  it("panel queries comments once when building file rows", function()
    local R = require("manicule.review")
    local manicule = require("manicule")
    local original_list = manicule.list
    local list_calls = 0
    manicule.list = function(opts)
      list_calls = list_calls + 1
      return original_list(opts)
    end
    local ok, start_ok, start_err = pcall(R.start, { files = make_pairs(3), label = "panel-test" })
    manicule.list = original_list

    assert.is_true(ok)
    assert.is_true(start_ok, start_err)
    assert.are.equal(1, list_calls)
  end)

  it("panel comment count updates when a comment is added", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "panel-test" }))

    -- Initial count should be 0
    local items = vim.fn.getqflist()
    assert.is_truthy(items[1].text:find("0 comments"))

    -- Find the right (modifiable) window and focus it
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype ~= "quickfix" and vim.bo[bufnr].modifiable then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end

    -- Add a comment
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("test comment")
    end
    require("manicule").add()
    ui.prompt = original_prompt

    -- Wait for refresh
    vim.wait(200)

    -- Count should now be 1
    items = vim.fn.getqflist()
    assert.is_truthy(items[1].text:find("1 comments"))
  end)

  it("<CR> in panel files view switches to that pair and keeps panel open", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(3), label = "panel-test" }))

    -- Find panel window
    local panel_winid
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype == "quickfix" then
        panel_winid = winid
        break
      end
    end
    assert.is_truthy(panel_winid)

    -- Switch to panel and press <CR> on row 2 THROUGH buffer-local
    -- mappings (normal! bypasses maps and "\\<CR>" is literal chars).
    vim.api.nvim_set_current_win(panel_winid)
    vim.api.nvim_win_set_cursor(panel_winid, { 2, 0 })
    local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
    vim.api.nvim_feedkeys(cr, "x", false)

    -- Session index should now be 2
    assert.are.equal(2, R.state().index)

    -- Panel should still be open
    assert.is_true(vim.api.nvim_win_is_valid(panel_winid))
  end)

  it("panel shows files view with comment counts", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "panel-test" }))

    -- Find the right (modifiable) window and focus it
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype ~= "quickfix" and vim.bo[bufnr].modifiable then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end

    -- Add a comment so we have something in comments view
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("test comment")
    end
    require("manicule").add()
    ui.prompt = original_prompt
    vim.wait(200)

    -- Files view should show both files with comment counts
    local items = vim.fn.getqflist()
    -- Should have entries for each file
    assert.is_true(#items >= 1, "Expected at least 1 item, got " .. #items)
    -- Items should have comment count format
    assert.is_truthy(items[1].text:find("comments"))
  end)

  local function add_comment(path, body)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb(body)
    end
    require("manicule").add()
    ui.prompt = original_prompt
  end

  local function panel_win()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype == "quickfix" then
        return winid
      end
    end
  end

  ---Press `lhs` in the panel window on `row` THROUGH buffer-local maps.
  local function press_in_panel(row, lhs)
    local winid = panel_win()
    assert.is_truthy(winid, "panel window not found")
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_cursor(winid, { row, 0 })
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "x", false)
  end

  it("<CR> on a commented file scopes the comments view to that file", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[1].right, "first file comment")
    add_comment(files[2].right, "second file comment")

    press_in_panel(1, "<CR>")

    local items = vim.fn.getqflist()
    assert.are.equal(1, #items)
    assert.is_truthy(items[1].text:find("first file comment", 1, true))
  end)

  it("<Esc> in scoped comments view returns to files view", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[1].right, "first file comment")

    press_in_panel(1, "<CR>")
    assert.are.equal(1, #vim.fn.getqflist())

    press_in_panel(1, "<Esc>")
    local items = vim.fn.getqflist()
    assert.are.equal(2, #items)
    assert.is_truthy(items[1].text:find("(1 comments)", 1, true))
    assert.is_truthy(items[2].text:find("(0 comments)", 1, true))
  end)

  it("<CR> on a file without comments opens the pair", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[1].right, "first file comment")

    press_in_panel(2, "<CR>")

    assert.are.equal(2, R.state().index)
    -- Still files view.
    assert.is_truthy(vim.fn.getqflist()[1].text:find("comments)", 1, true))
  end)

  it("o on a commented file opens the pair anyway", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[2].right, "second file comment")

    press_in_panel(2, "o")

    assert.are.equal(2, R.state().index)
    assert.is_truthy(vim.fn.getqflist()[1].text:find("comments)", 1, true))
  end)

  it("<Tab> from a scoped comments view widens to ALL comments", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "drill" }))
    add_comment(files[1].right, "first file comment")
    add_comment(files[2].right, "second file comment")

    press_in_panel(1, "<CR>")
    assert.are.equal(1, #vim.fn.getqflist())

    press_in_panel(1, "<Tab>")
    local items = vim.fn.getqflist()
    assert.are.equal(2, #items)
    local texts = table.concat({ items[1].text, items[2].text }, "\n")
    assert.is_truthy(texts:find("first file comment", 1, true))
    assert.is_truthy(texts:find("second file comment", 1, true))
  end)

  ---Like add_comment, but places the comment on a specific line.
  local function add_comment_at(path, line, body)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb(body)
    end
    require("manicule").add()
    ui.prompt = original_prompt
  end

  it("<CR> in comments view rebuilds the pair's diff and jumps to the comment", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    vim.fn.writefile({ "return 2 -- new", "-- pad", "-- target", "-- pad" }, files[2].right)
    assert.is_true(R.start({ files = files, label = "jump" }))
    add_comment_at(files[2].right, 3, "jump target")
    -- add_comment_at edited pair 2's file into pair 1's diff window;
    -- restore the pair 1 layout before exercising the jump.
    R.open(1)

    press_in_panel(1, "<Tab>") -- comments view (ALL)
    press_in_panel(1, "<CR>")

    assert.are.equal(2, R.state().index)

    -- Focused window shows pair 2's RIGHT worktree file, cursor on the
    -- comment's line.
    local cur_win = vim.api.nvim_get_current_win()
    local cur_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(cur_win))
    assert.is_truthy(cur_name:find("/f2.lua", 1, true), "expected right file, got " .. cur_name)
    assert.is_nil(cur_name:find("/left/", 1, true), "jump landed in the left buffer: " .. cur_name)
    assert.are.equal(3, vim.api.nvim_win_get_cursor(cur_win)[1])

    -- Panel window is still open.
    local pwin = panel_win()
    assert.is_truthy(pwin, "panel window closed by jump")

    -- Regression: the OTHER diff window must show pair 2's LEFT staged
    -- file — the default qf jump used to replace a diff window with the
    -- target buffer, leaving a broken non-pair layout.
    local left_seen = false
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if winid ~= cur_win and winid ~= pwin then
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))
        assert.is_truthy(name:find("/left/f2.lua", 1, true), "other diff window shows " .. name)
        left_seen = true
      end
    end
    assert.is_true(left_seen, "no second diff window found")
  end)

  it("<CR> in comments view on a deleted-pair comment lands in the left buffer", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    -- Realpath the staged dir: records store canonical uris, and the
    -- macOS TMPDIR symlink (/var -> /private/var) would otherwise make
    -- the pair uri miss the record uri.
    local uv = vim.uv or vim.loop
    local left_dir = uv.fs_realpath(ctx.artifact_root .. "/left") or (ctx.artifact_root .. "/left")
    local left = left_dir .. "/gone.lua"
    vim.fn.writefile({ "return 0 -- deleted" }, left)
    files[2] = { left = left, right = ctx.root .. "/gone.lua", status = "D", path = "gone.lua" }
    assert.is_true(R.start({ files = files, label = "jump-d" }))
    add_comment_at(left, 1, "note on deleted file")
    R.open(1)

    press_in_panel(1, "<Tab>")
    press_in_panel(1, "<CR>")

    assert.are.equal(2, R.state().index)
    local cur_name = vim.api.nvim_buf_get_name(0)
    assert.is_truthy(cur_name:find("/left/gone.lua", 1, true), "expected left buffer, got " .. cur_name)
    assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_truthy(panel_win(), "panel window closed by jump")
  end)

  it("<CR> in comments view on an unmatched comment warns and keeps the layout", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "jump-warn" }))
    add_comment_at(files[1].right, 1, "orphan-to-be")
    R.open(1)

    press_in_panel(1, "<Tab>")

    -- Corrupt the item's uri so it matches no session pair (defensive path).
    local pwin = panel_win()
    local info = vim.fn.getqflist({ winid = pwin, id = 0, items = 1 })
    info.items[1].user_data.uri = "file:///nonexistent/orphan.lua"
    vim.fn.setqflist({}, "r", { id = info.id, items = info.items })

    local warned
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    press_in_panel(1, "<CR>")
    vim.notify = original_notify

    assert.is_truthy(warned, "expected a WARN notification")
    assert.are.equal(1, R.state().index)
    -- Layout unchanged: focus still in the panel, both pair 1 diff
    -- windows intact.
    assert.are.equal(pwin, vim.api.nvim_get_current_win())
    local saw_left, saw_right = false, false
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if winid ~= pwin then
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(winid))
        if name:find("/left/f1.lua", 1, true) then
          saw_left = true
        elseif name:find("/f1.lua", 1, true) then
          saw_right = true
        end
      end
    end
    assert.is_true(saw_left and saw_right, "pair 1 diff layout was disturbed")
  end)

  ---Persist an imported-from-GitHub record on `path` (project scope,
  ---line 1) with the given `meta.github` table.
  local function put_imported(path, gh_meta, body)
    local store = require("manicule.store")
    local now = os.time()
    local record = {
      id = require("manicule.id").new(),
      uri = require("manicule.uri").for_path(path),
      scope = "project",
      project_root = ctx.root,
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
      body = body or "from github",
      author = "octocat",
      created_at = now,
      updated_at = now,
      resolved = false,
      meta = { github = gh_meta },
    }
    store.put_record(record)
    assert(store.save(ctx.root))
    return record
  end

  it("r in comments view replies to an imported comment", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    put_imported(files[1].right, { id = 9001, imported = true, thread_id = 9001, pr = 42 })
    assert.is_true(R.start({ files = files, label = "reply" }))

    local ui = require("manicule.ui")
    local original_prompt = ui.prompt
    ui.prompt = function(_opts, cb)
      cb("sounds good")
    end
    press_in_panel(1, "<Tab>")
    press_in_panel(1, "r")
    ui.prompt = original_prompt

    local reply
    for _, r in ipairs(require("manicule.store").all(ctx.root)) do
      if r.body == "sounds good" then
        reply = r
      end
    end
    assert.is_truthy(reply, "reply record not created")
    assert.are.equal(require("manicule.uri").for_path(files[1].right), reply.uri)
    assert.are.same({ start = { 0, 0 }, end_ = { 0, 0 } }, reply.range)
    assert.are.same({ to = 9001, pr = 42 }, reply.meta.github_reply)
    assert.is_nil(reply.meta.github)
  end)

  it("r on a non-imported comment warns and creates nothing", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    assert.is_true(R.start({ files = files, label = "reply-warn" }))
    add_comment(files[1].right, "local note")

    local warned
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    press_in_panel(1, "<Tab>")
    press_in_panel(1, "r")
    vim.notify = original_notify

    assert.is_truthy(warned, "expected a WARN")
    assert.are.equal(1, #require("manicule").list({ _quiet = true, _root = ctx.root }))
  end)

  ---Fake gh on PATH that logs every argv line and answers any call
  ---with an empty JSON object (enough for graphql mutations).
  local function fake_gh_resolve(dir)
    local home = dir .. "/gh-resolve"
    local bin = home .. "/bin"
    vim.fn.mkdir(bin, "p")
    vim.fn.writefile({
      "#!/bin/sh",
      "dir=" .. vim.fn.shellescape(home),
      'echo "$*" >> "$dir/argv.log"',
      "echo '{\"data\":{}}'",
    }, bin .. "/gh")
    vim.fn.system({ "chmod", "+x", bin .. "/gh" })
    return {
      bin = bin,
      argv = function()
        local ok, lines = pcall(vim.fn.readfile, home .. "/argv.log")
        return ok and lines or {}
      end,
    }
  end

  it("gr in comments view toggles GitHub thread resolution", function()
    local gh = fake_gh_resolve(ctx.artifact_root)
    local saved_path = vim.env.PATH
    vim.env.PATH = gh.bin .. ":" .. saved_path
    local R = require("manicule.review")
    local files = make_pairs(1)
    local record = put_imported(
      files[1].right,
      { id = 9001, imported = true, thread_id = 9001, thread_node = "RT_kwDO1", resolved = false, pr = 42 }
    )
    assert.is_true(R.start({ files = files, label = "resolve" }))

    press_in_panel(1, "<Tab>")
    assert.is_nil(vim.fn.getqflist()[1].text:find("\u{2713}", 1, true))

    press_in_panel(1, "gr")

    -- The mutation runs through an async vim.system: the argv log, the
    -- flag flip, and the panel refresh all land in the callback.
    local store = require("manicule.store")
    vim.wait(2000, function()
      return store.get(ctx.root, record.id).meta.github.resolved == true
    end)

    local argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(argv:find("resolveReviewThread", 1, true))
    assert.is_truthy(argv:find("RT_kwDO1", 1, true))
    assert.is_nil(argv:find("unresolveReviewThread", 1, true))
    assert.is_true(store.get(ctx.root, record.id).meta.github.resolved)
    assert.is_truthy(vim.fn.getqflist()[1].text:find("\u{2713}", 1, true))

    press_in_panel(1, "gr")
    vim.wait(2000, function()
      return store.get(ctx.root, record.id).meta.github.resolved == false
    end)

    argv = table.concat(gh.argv(), "\n")
    assert.is_truthy(argv:find("unresolveReviewThread", 1, true))
    assert.is_false(store.get(ctx.root, record.id).meta.github.resolved)
    assert.is_nil(vim.fn.getqflist()[1].text:find("\u{2713}", 1, true))

    vim.env.PATH = saved_path
  end)

  it("gr on a non-imported comment warns", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    assert.is_true(R.start({ files = files, label = "resolve-warn" }))
    add_comment(files[1].right, "local note")

    local warned
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    press_in_panel(1, "<Tab>")
    press_in_panel(1, "gr")
    vim.notify = original_notify

    assert.is_truthy(warned, "expected a WARN")
  end)

  it("gr on an imported comment without a thread id warns", function()
    local R = require("manicule.review")
    local files = make_pairs(1)
    put_imported(files[1].right, { id = 9002, imported = true, thread_id = 9002, pr = 42 })
    assert.is_true(R.start({ files = files, label = "resolve-no-node" }))

    local warned
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    press_in_panel(1, "<Tab>")
    press_in_panel(1, "gr")
    vim.notify = original_notify

    assert.is_truthy(warned, "expected a WARN")
    assert.is_truthy(
      warned:find(":ManiculeReview pr", 1, true),
      "WARN must point at re-running :ManiculeReview pr <n>, got: " .. tostring(warned)
    )
  end)

  it("next/prev sync the panel's current-entry to the open pair", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(3), label = "sync" }))
    local pwin = panel_win()
    assert.is_truthy(pwin, "panel window not found")

    R.next()
    assert.are.equal(2, vim.fn.getqflist({ winid = pwin, idx = 0 }).idx)
    assert.are.equal(2, vim.api.nvim_win_get_cursor(pwin)[1])
    -- Focus must stay in the diff window, not the panel.
    assert.are_not.equal(pwin, vim.api.nvim_get_current_win())
    assert.is_false(vim.bo[vim.api.nvim_get_current_buf()].buftype == "quickfix")

    R.prev()
    assert.are.equal(1, vim.fn.getqflist({ winid = pwin, idx = 0 }).idx)
    assert.are.equal(1, vim.api.nvim_win_get_cursor(pwin)[1])
  end)

  it("comment-add refresh keeps the panel index on the open pair", function()
    local R = require("manicule.review")
    local files = make_pairs(3)
    assert.is_true(R.start({ files = files, label = "sync-refresh" }))
    R.next() -- pair 2 open

    -- Adding a comment fires User ManiculeAdded, which rebuilds the
    -- panel list; the rebuild must restore idx to the open pair.
    add_comment(files[2].right, "note on pair 2")
    vim.wait(200)

    local pwin = panel_win()
    assert.is_truthy(pwin, "panel window not found")
    assert.are.equal(2, vim.fn.getqflist({ winid = pwin, idx = 0 }).idx)
  end)

  it("next() in drill-down comments view leaves the comments list alone", function()
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "sync-drill" }))
    add_comment(files[1].right, "drill comment")
    R.open(1)

    press_in_panel(1, "<CR>") -- drill into pair 1's scoped comments view
    assert.are.equal(1, #vim.fn.getqflist())

    local ok, err = pcall(R.next)
    assert.is_true(ok, err)

    -- Comments list undisturbed by the pair switch.
    local items = vim.fn.getqflist()
    assert.are.equal(1, #items)
    assert.is_truthy(items[1].text:find("drill comment", 1, true))
  end)

  it(":ManiculeToggle hides the panel during a session and keeps it running", function()
    vim.cmd("runtime plugin/manicule.lua")
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "toggle" }))
    assert.is_truthy(panel_win(), "panel window not found")

    vim.cmd("ManiculeToggle")

    assert.is_nil(panel_win(), "panel window still open after toggle")
    assert.is_truthy(R.state(), "toggle killed the session")
  end)

  it(":ManiculeToggle twice restores the panel in the same view", function()
    vim.cmd("runtime plugin/manicule.lua")
    local R = require("manicule.review")
    local files = make_pairs(2)
    assert.is_true(R.start({ files = files, label = "toggle" }))
    add_comment(files[1].right, "first file comment")
    add_comment(files[2].right, "second file comment")

    -- Drill into a comments view scoped to file 1.
    press_in_panel(1, "<CR>")
    assert.are.equal(1, #vim.fn.getqflist())

    vim.cmd("ManiculeToggle")
    assert.is_nil(panel_win())
    vim.cmd("ManiculeToggle")

    local winid = panel_win()
    assert.is_truthy(winid, "panel window not reopened")
    -- Still the scoped comments view: one row, file 1's comment only.
    local items = vim.fn.getqflist()
    assert.are.equal(1, #items)
    assert.is_truthy(items[1].text:find("first file comment", 1, true))
  end)

  it(":ManiculeToggle without a session still toggles comment visuals", function()
    vim.cmd("runtime plugin/manicule.lua")
    local render = require("manicule.ui.render")
    assert.is_false(render.is_hidden())

    vim.cmd("ManiculeToggle")
    assert.is_true(render.is_hidden())

    vim.cmd("ManiculeToggle")
    assert.is_false(render.is_hidden())
  end)

  it("panel.toggle() without a session is a no-op returning false", function()
    assert.is_false(require("manicule.review.panel").toggle())
  end)

  it("finish() from a foreign cwd/unnamed buffer still sends session comments", function()
    local R = require("manicule.review")
    local files = make_pairs(1)

    local sent
    require("manicule").register_sink({
      name = "capture",
      send = function(comments, _, cb)
        sent = comments
        cb(true)
      end,
    })

    assert.is_true(R.start({ files = files, label = "root-hint", sink = "capture" }))
    add_comment(files[1].right, "session comment")

    -- Move to an unnamed scratch buffer with cwd OUTSIDE the reviewed
    -- project: list() resolves the store root from the CURRENT buffer,
    -- falling back to cwd, so without the session's `_root` hint the
    -- comment would be silently dropped ("review has no comments to send").
    local elsewhere = ctx.artifact_root .. "/elsewhere"
    vim.fn.mkdir(elsewhere, "p")
    local saved = (vim.uv or vim.loop).cwd()
    vim.cmd.enew()
    vim.cmd.cd(elsewhere)

    R.finish()
    vim.wait(200, function()
      return sent ~= nil
    end)
    vim.cmd.cd(saved)

    assert.is_truthy(sent, "sink never received the session's comments")
    assert.are.equal(1, #sent)
    assert.are.equal("session comment", sent[1].body)
  end)

  it("VimLeavePre autoflush wait tracks the socket sink's ack timeout", function()
    local R = require("manicule.review")
    -- Default socket ack_timeout_ms is 2000; the historical 2500 floor holds.
    assert.are.equal(2500, R._autoflush_wait_ms())

    -- A user-configured ack_timeout_ms at or above the old hard-coded 2500
    -- must extend the wait past the sink's ack timer, or nvim exits before
    -- the never-lose-comments submit.json fallback fires. No restore
    -- needed: before_each's setup() rebuilds the config from defaults.
    require("manicule.config").get().sinks.socket = { ack_timeout_ms = 5000 }
    assert.is_true(R._autoflush_wait_ms() > 5000, "wait must outlive the ack timer")
  end)

  it("recreates the session tab after :tabclose so next() does not error", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(2), label = "tabclose" }))
    local dead_tab = R.state().tab

    vim.cmd.tabclose() -- kill the review tab directly, bypassing stop()

    local ok, err = pcall(R.next)
    assert.is_true(ok, err)

    -- Session survived on a fresh, valid tab showing the next pair.
    local state = R.state()
    assert.is_truthy(state, "session died with the tab")
    assert.are.equal(2, state.index)
    assert.are_not.equal(dead_tab, state.tab)
    assert.is_true(vim.api.nvim_tabpage_is_valid(state.tab))
    assert.are.equal(state.tab, vim.api.nvim_get_current_tabpage())
    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("f2.lua", 1, true))
    -- The panel comes back with the recreated tab.
    assert.is_truthy(panel_win(), "panel not reopened with the recreated tab")
  end)

  it("stop() closes the panel and clears autocmds", function()
    local R = require("manicule.review")
    assert.is_true(R.start({ files = make_pairs(1), label = "panel-test" }))

    -- Panel should be open
    local panel_winid
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].buftype == "quickfix" then
        panel_winid = winid
        break
      end
    end
    assert.is_truthy(panel_winid)

    R.stop()

    -- Panel should be closed
    assert.is_false(vim.api.nvim_win_is_valid(panel_winid))
  end)
end)
