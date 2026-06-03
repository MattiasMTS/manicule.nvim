-- manicule.nvim: buffer-local keymaps for manicule quickfix lists.
--
-- Wired in from `init.lua` via a `FileType qf` autocmd that inspects
-- the list title (`getqflist({title=1}).title`) and only attaches when
-- it starts with `manicule`. Non-manicule quickfix lists (grep,
-- diagnostics, other plugins) are left alone.
--
-- Keymaps are buffer-local so `dd`/`ce`/`u`/`<C-r>` behave normally
-- everywhere else — we must never shadow the global normal-mode bindings.
--
-- The keymaps trigger mutations through the public `manicule` API. The
-- matching `User Manicule{Deleted,Edited,Restored}` events fire
-- automatically, which `init.lua` listens for and calls
-- `require("manicule.ui.quickfix").refresh()` — so the quickfix list
-- updates in place without needing any extra wiring here. `u` undoes
-- the last comment deletion (multi-level, LIFO); `<C-r>` redoes the
-- last undone deletion (also multi-level — a fresh deletion clears it).

local M = {}

---Set the manicule keymaps on `qf_bufnr`. Idempotent — safe to call
---multiple times (the identical mapping is simply re-registered).
---Honours `vim.g.manicule_no_default_keymaps` the same way the
---top-level `gca`/`gcd` bindings do: when set to 1, bail out entirely
---and leave the qf buffer with its native bindings.
---@param qf_bufnr integer
function M.attach(qf_bufnr)
  if not qf_bufnr or not vim.api.nvim_buf_is_valid(qf_bufnr) then
    return
  end
  if vim.g.manicule_no_default_keymaps == 1 then
    -- Runtime toggle safety: if the user flipped the flag after we
    -- already attached to this qf buffer (e.g. in a prior `:copen`),
    -- strip any mappings we previously installed so native `dd`/`ce`
    -- come back.
    pcall(vim.keymap.del, "n", "dd", { buffer = qf_bufnr })
    pcall(vim.keymap.del, "n", "ce", { buffer = qf_bufnr })
    pcall(vim.keymap.del, "n", "u", { buffer = qf_bufnr })
    pcall(vim.keymap.del, "n", "<C-r>", { buffer = qf_bufnr })
    return
  end

  local map_opts = { buffer = qf_bufnr, nowait = true, silent = true }

  vim.keymap.set("n", "dd", function()
    local locator = require("manicule.ui.quickfix").record_locator_at_cursor()
    if not locator then
      return
    end
    -- The `User ManiculeDeleted` event fires on completion; the
    -- live-refresh autocmd then replaces the qf list in place.
    require("manicule").delete(locator.id, locator)
  end, vim.tbl_extend("keep", { desc = "Manicule: delete comment under cursor" }, map_opts))

  vim.keymap.set("n", "ce", function()
    local locator = require("manicule.ui.quickfix").record_locator_at_cursor()
    if not locator then
      return
    end
    -- Opens the floating editor. Submitting fires `User
    -- ManiculeEdited`, which triggers the live refresh.
    require("manicule").edit(locator.id, locator)
  end, vim.tbl_extend("keep", { desc = "Manicule: edit comment under cursor" }, map_opts))

  vim.keymap.set("n", "u", function()
    -- Multi-level undo of comment deletions. Fires `User
    -- ManiculeRestored`, which triggers the live refresh.
    require("manicule").undo_delete()
  end, vim.tbl_extend("keep", { desc = "Manicule: undo last comment deletion" }, map_opts))

  vim.keymap.set("n", "<C-r>", function()
    -- Multi-level redo of undone deletions. Fires `User
    -- ManiculeDeleted`, which triggers the live refresh.
    require("manicule").redo_delete()
  end, vim.tbl_extend("keep", { desc = "Manicule: redo last undone deletion" }, map_opts))
end

return M
