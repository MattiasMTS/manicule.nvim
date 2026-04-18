if vim.g.loaded_manicule then
  return
end
vim.g.loaded_manicule = 1

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

vim.keymap.set({ "n", "x" }, "<Plug>(manicule-add)", function()
  require("manicule").add()
end, { silent = true })

vim.keymap.set("n", "<Plug>(manicule-list)", function()
  require("manicule").list()
end, { silent = true })
