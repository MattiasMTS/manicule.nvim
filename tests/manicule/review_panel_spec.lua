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

---Count buffer-local normal-mode maps the PANEL owns — the ones
---setup_panel_keymaps sets, all desc'd "Manicule review: …". The
---generic "Manicule: …" quickfix maps (dd/ce/u/<C-r>) are excluded:
---init.lua's FileType-qf autocmd attaches those independently, so
---they say nothing about which window the panel bound itself to.
local function panel_keymap_count(bufnr)
  local count = 0
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if type(map.desc) == "string" and map.desc:find("Manicule review", 1, true) then
      count = count + 1
    end
  end
  return count
end

describe("manicule review panel with a location list open", function()
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

  it("binds the panel to the quickfix window, not a location list", function()
    local R = require("manicule.review")
    local panel = require("manicule.review.panel")
    assert.is_true(R.start({ files = make_pairs(2), label = "panel-loclist" }))

    -- Hide the panel, then open a location list in the review tab.
    -- Loclist windows also have buftype "quickfix", and this one sits
    -- ABOVE the botright panel in the tab's window order, so a naive
    -- buftype scan on reopen would capture it instead of the panel.
    assert.is_true(panel.toggle())
    vim.fn.setloclist(0, { { filename = R.state().files[1].right, lnum = 1 } })
    vim.cmd("lopen")
    local loclist_win = vim.api.nvim_get_current_win()
    local loclist_buf = vim.api.nvim_win_get_buf(loclist_win)
    assert.are.equal(1, vim.fn.getwininfo(loclist_win)[1].loclist)

    -- Reopen the panel with the loclist window present.
    assert.is_true(panel.toggle())

    -- (a) The panel is a real quickfix window (loclist == 0) titled as
    -- the manicule review panel, and it carries the panel keymaps.
    local qf_win
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local info = vim.fn.getwininfo(winid)[1]
      if info and info.quickfix == 1 and info.loclist == 0 then
        qf_win = winid
      end
    end
    assert.is_truthy(qf_win, "panel quickfix window not found")
    local title = vim.fn.getqflist({ title = 1 }).title
    assert.are.equal(1, title:find("manicule-review", 1, true), "quickfix list is not the manicule panel: " .. title)
    local qf_buf = vim.api.nvim_win_get_buf(qf_win)
    assert.is_true(panel_keymap_count(qf_buf) > 0, "panel keymaps missing from the panel quickfix buffer")

    -- (b) The loclist buffer did NOT get the panel's buffer-local maps.
    assert.are.equal(0, panel_keymap_count(loclist_buf), "panel keymaps leaked onto the location-list buffer")

    -- (c) Toggling the panel closed closes the panel, not the loclist.
    assert.is_true(panel.toggle())
    assert.is_true(
      vim.api.nvim_win_is_valid(loclist_win),
      "toggle closed the location-list window instead of the panel"
    )
    assert.is_false(vim.api.nvim_win_is_valid(qf_win), "toggle left the panel window open")
  end)
end)
