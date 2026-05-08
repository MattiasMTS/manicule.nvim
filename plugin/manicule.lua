if vim.g.loaded_manicule then
  return
end
vim.g.loaded_manicule = 1

---Resolve a command's opts into the action to run.
---
---- No argument → open the `vim.ui.select` picker for the action.
---- Numeric argument in `[1, #records]` → dispatch to the action with
---  the id at that position in `list()` ordering.
---- Anything else → ERROR notify.
---@param action "edit"|"delete"|"resolve"
---@param opts table
local function dispatch_positional(action, opts)
  local records = require("manicule").list({ _quiet = true })
  if opts.args == nil or opts.args == "" then
    require("manicule.ui.picker").pick(action, records)
    return
  end
  local n = tonumber(opts.args)
  if not n or n ~= math.floor(n) or n < 1 or n > #records then
    vim.notify(("manicule: no comment at position %q"):format(opts.args), vim.log.levels.ERROR)
    return
  end
  require("manicule")[action](records[n].id, {
    scope = records[n].scope,
    project_root = records[n].project_root,
  })
end

---Tab-completion returns stringified positions `"1"`..`"N"`. Command-
---line completion tokens don't support display text — that's what the
---picker is for.
---@return string[]
local function position_completer()
  local records = require("manicule").list({ _quiet = true })
  local out = {}
  for i = 1, #records do
    out[i] = tostring(i)
  end
  return out
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
  nargs = "?",
  complete = function()
    return require("manicule.sinks").list()
  end,
})

vim.api.nvim_create_user_command("ManiculeResolve", function(opts)
  dispatch_positional("resolve", opts)
end, { nargs = "?", complete = position_completer })

vim.api.nvim_create_user_command("ManiculeDelete", function(opts)
  dispatch_positional("delete", opts)
end, { nargs = "?", complete = position_completer })

vim.api.nvim_create_user_command("ManiculeEdit", function(opts)
  dispatch_positional("edit", opts)
end, { nargs = "?", complete = position_completer })

vim.api.nvim_create_user_command("ManiculeToggle", function()
  require("manicule.ui.render").toggle()
end, {})

vim.keymap.set({ "n", "x" }, "<Plug>(manicule-add)", function()
  require("manicule").add()
end, { silent = true })

vim.keymap.set("n", "<Plug>(manicule-list)", function()
  require("manicule").list()
end, { silent = true })

-- Edit the first comment at/covering the cursor.
-- Manicule is buffer-agnostic, so we resolve the target record via the
-- render layer's cursor hit-test helper.
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

-- Flip visuals on/off without touching the store. No default binding —
-- the command is enough for most users; expose the <Plug> for anyone
-- who wants a keymap.
vim.keymap.set("n", "<Plug>(manicule-toggle)", function()
  require("manicule.ui.render").toggle()
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
