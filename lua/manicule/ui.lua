-- manicule.nvim: thin wrappers over `vim.ui.input` / `vim.ui.select`
-- so the rest of the plugin stays picker-agnostic. Any UI that
-- implements the vim.ui contract (dressing.nvim, snacks.nvim, fzf-lua,
-- telescope-ui-select, …) works transparently.

local M = {}

---Prompt the user for a free-form comment body.
---@param opts {prompt?: string, default?: string}|nil
---@param on_confirm fun(body: string|nil)
function M.prompt_body(opts, on_confirm)
  -- TODO(manicule): call vim.ui.input with a sensible default prompt
  -- ("Comment: "). Support multiline via a scratch buffer when the
  -- body should span more than one line.
  local _, _ = opts, on_confirm
  error("TODO(manicule): ui.prompt_body not implemented")
end

---Let the user pick a comment from a list.
---@param comments table[]
---@param on_choice fun(comment: table|nil)
function M.pick_comment(comments, on_choice)
  -- TODO(manicule): call vim.ui.select with a compact formatter
  -- (path:line: body[:40]) so pickers can render nicely.
  local _, _ = comments, on_choice
  error("TODO(manicule): ui.pick_comment not implemented")
end

---Let the user pick a registered sink by name.
---@param sink_names string[]
---@param on_choice fun(name: string|nil)
function M.pick_sink(sink_names, on_choice)
  -- TODO(manicule): call vim.ui.select over the provided names.
  local _, _ = sink_names, on_choice
  error("TODO(manicule): ui.pick_sink not implemented")
end

return M
