local H = require("helpers")

local ctx

local function setup_env(opts)
  ctx = H.setup(opts)
  H.edit_project_file(ctx, "src/float.lua", {
    "local value = 1",
    "return value",
  })
end

local function teardown_env()
  H.teardown(ctx)
  ctx = nil
end

local function floating_windows_containing(text)
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local cfg = vim.api.nvim_win_get_config(winid)
      if cfg.relative and cfg.relative ~= "" then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local lines = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if lines:find(text, 1, true) then
          table.insert(wins, winid)
        end
      end
    end
  end
  return wins
end

local function wait_for_popup(text)
  local wins = {}
  local ok = vim.wait(1000, function()
    wins = floating_windows_containing(text)
    return #wins == 1
  end, 10)
  assert.is_true(ok)
  return wins[1]
end

describe("manicule float transparency", function()
  before_each(function()
    setup_env({
      ui = {
        opacity = 0.5,
      },
    })
  end)
  after_each(teardown_env)

  it("converts fractional opacity to Neovim winblend", function()
    local float = require("manicule.ui.float")

    assert.are.equal(0, float.opacity_to_winblend(0))
    assert.are.equal(25, float.opacity_to_winblend(0.25))
    assert.are.equal(50, float.opacity_to_winblend(0.5))
    assert.are.equal(99, float.opacity_to_winblend(0.99))
    assert.are.equal(100, float.opacity_to_winblend(1))

    -- Legacy 0-100 values still behave like winblend percentages.
    assert.are.equal(50, float.opacity_to_winblend(50))
    assert.are.equal(100, float.opacity_to_winblend(150))
    assert.are.equal(0, float.opacity_to_winblend(-10))
  end)

  it("applies fractional opacity to the comment editor float", function()
    local editor = require("manicule.ui.editor")
    local cfg = require("manicule.config").get().ui

    assert.is_true(editor.open({
      title = "Comment",
      cfg = cfg,
    }, function() end))

    assert.is_true(editor.is_active())
    local winid = vim.api.nvim_get_current_win()
    assert.are.equal(50, vim.wo[winid].winblend)

    editor.close_active()
    assert.is_true(vim.wait(1000, function()
      return not editor.is_active()
    end, 10))
  end)

  it("applies fractional opacity to rendered comment popups", function()
    require("manicule").add({
      body = "transparent popup",
      range = { start = { 0, 0 }, end_ = { 0, 0 } },
    })

    local winid = wait_for_popup("transparent popup")
    assert.are.equal(50, vim.wo[winid].winblend)
  end)

  it("uses the float background for border and title cells", function()
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xeeeeee, bg = 0x111111 })
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xdddddd, bg = 0x222222 })
    vim.api.nvim_set_hl(0, "FloatBorder", { fg = 0xaaaaaa, bg = 0x333333 })
    vim.api.nvim_set_hl(0, "Comment", { fg = 0x999999 })

    require("manicule.ui.render").refresh_highlights()

    local border_hl = vim.api.nvim_get_hl(0, { name = "ManiculeCommentBorder", link = false })
    local meta_hl = vim.api.nvim_get_hl(0, { name = "ManiculeCommentMeta", link = false })

    assert.are.equal(0x222222, border_hl.bg)
    assert.are.equal(0x222222, meta_hl.bg)
    assert.are.equal(0xaaaaaa, border_hl.fg)
    assert.are.equal(0x999999, meta_hl.fg)
  end)
end)
