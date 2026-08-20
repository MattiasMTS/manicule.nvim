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
