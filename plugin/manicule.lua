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
-- buffer-agnostic so we resolve the target record by scanning extmarks
-- in the current buffer for one that covers the cursor line.
vim.keymap.set("n", "<Plug>(manicule-edit)", function()
  local m = require("manicule")
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = m._buffer_marks()[bufnr]
  if not marks or vim.tbl_isempty(marks) then
    vim.notify("manicule: no comments in this buffer", vim.log.levels.INFO)
    return
  end
  local anchor = require("manicule.anchor")
  local cur_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  for id, mark_id in pairs(marks) do
    local resolved = anchor.resolve(bufnr, mark_id)
    if resolved and not resolved.invalid then
      local sr = resolved.range.start[1]
      local er = resolved.range.end_[1]
      if cur_line >= sr and cur_line <= er then
        m.edit(id)
        return
      end
    end
  end
  vim.notify("manicule: no comment at cursor", vim.log.levels.INFO)
end, { silent = true })

-- Delete the first comment at/covering the cursor.
vim.keymap.set("n", "<Plug>(manicule-delete)", function()
  local m = require("manicule")
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = m._buffer_marks()[bufnr]
  if not marks or vim.tbl_isempty(marks) then
    vim.notify("manicule: no comments in this buffer", vim.log.levels.INFO)
    return
  end
  local anchor = require("manicule.anchor")
  local cur_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  for id, mark_id in pairs(marks) do
    local resolved = anchor.resolve(bufnr, mark_id)
    if resolved and not resolved.invalid then
      local sr = resolved.range.start[1]
      local er = resolved.range.end_[1]
      if cur_line >= sr and cur_line <= er then
        m.delete(id)
        return
      end
    end
  end
  vim.notify("manicule: no comment at cursor", vim.log.levels.INFO)
end, { silent = true })
