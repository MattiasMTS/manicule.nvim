if vim.g.loaded_manicule then
  return
end
vim.g.loaded_manicule = 1

local function id_completer()
  local records = require("manicule").list({ _quiet = true })
  local ids = {}
  for _, r in ipairs(records) do
    table.insert(ids, r.id)
  end
  return ids
end

vim.api.nvim_create_user_command("ManiculeAdd", function(opts)
  require("manicule").add({ range = opts.range > 0 and { opts.line1, opts.line2 } or nil })
end, { range = true })

vim.api.nvim_create_user_command("ManiculeList", function()
  require("manicule").list()
end, {})

vim.api.nvim_create_user_command("ManiculeSend", function(opts)
  require("manicule").send(opts.args)
end, {
  nargs = 1,
  complete = function()
    return require("manicule.sinks").list()
  end,
})

vim.api.nvim_create_user_command("ManiculeResolve", function(opts)
  require("manicule").resolve(opts.args)
end, { nargs = 1, complete = id_completer })

vim.api.nvim_create_user_command("ManiculeDelete", function(opts)
  require("manicule").delete(opts.args)
end, { nargs = 1, complete = id_completer })

vim.api.nvim_create_user_command("ManiculeEdit", function(opts)
  require("manicule").edit(opts.args)
end, { nargs = 1, complete = id_completer })

vim.keymap.set({ "n", "x" }, "<Plug>(manicule-add)", function()
  require("manicule").add()
end, { silent = true })

vim.keymap.set("n", "<Plug>(manicule-list)", function()
  require("manicule").list()
end, { silent = true })

-- Edit the first comment at/covering the cursor.
-- Mirrors codediff.nvim's <Plug>(codediff-comment-edit). Manicule is
-- buffer-agnostic so we resolve the target record via the render
-- layer's cursor hit-test helper.
vim.keymap.set("n", "<Plug>(manicule-edit)", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = require("manicule.ui.render").record_at_cursor(bufnr)
  if not id then
    vim.notify("manicule: no comment at cursor", vim.log.levels.WARN)
    return
  end
  require("manicule").edit(id)
end, { silent = true })

-- Delete the first comment at/covering the cursor.
vim.keymap.set("n", "<Plug>(manicule-delete)", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = require("manicule.ui.render").record_at_cursor(bufnr)
  if not id then
    vim.notify("manicule: no comment at cursor", vim.log.levels.WARN)
    return
  end
  require("manicule").delete(id)
end, { silent = true })

-- Default keymaps. The popup footer advertises `gca` / `gcd` so users
-- expect them to work out of the box. Set `vim.g.manicule_no_default_keymaps = 1`
-- before the plugin loads to opt out.
if vim.g.manicule_no_default_keymaps ~= 1 then
  vim.keymap.set("n", "gca", "<Plug>(manicule-edit)", {
    desc = "Manicule: edit comment at cursor",
  })
  vim.keymap.set("n", "gcd", "<Plug>(manicule-delete)", {
    desc = "Manicule: delete comment at cursor",
  })
end
