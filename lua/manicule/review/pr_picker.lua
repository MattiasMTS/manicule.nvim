-- manicule.nvim: open-PR picker for bare `:ManiculeReview pr`.
--
-- Lists open PRs via the gh CLI and offers them through `vim.ui.select`
-- so users don't need to know a PR number up front. The chosen number
-- feeds straight back into the synchronous `pr` resolver; cancelling the
-- picker is a no-op.

local M = {}

---Open PRs via `gh pr list`. nil when gh is missing, fails, or the
---repository has no open PRs — the caller treats all three the same.
---@return {number: integer, title: string, author: table}[]|nil
local function open_prs()
  if vim.fn.executable("gh") ~= 1 then
    return nil
  end
  local ok, job = pcall(vim.system, { "gh", "pr", "list", "--json", "number,title,author", "--limit", "50" }, {
    text = true,
  })
  if not ok then
    return nil
  end
  local result = job:wait()
  if result.code ~= 0 then
    return nil
  end
  local decoded, prs = pcall(vim.json.decode, result.stdout or "")
  if not decoded or type(prs) ~= "table" or #prs == 0 then
    return nil
  end
  return prs
end

---Pick an open PR and hand its number (as a string) to `on_choice`.
---`on_choice` is not called when the user cancels.
---@param on_choice fun(number: string)
function M.pick(on_choice)
  local prs = open_prs()
  if not prs then
    vim.notify("manicule: no open PRs found (or gh unavailable)", vim.log.levels.ERROR)
    return
  end
  vim.ui.select(prs, {
    prompt = "Review PR",
    format_item = function(pr)
      local author = type(pr.author) == "table" and pr.author.login or "?"
      return ("#%s %s — %s"):format(pr.number, pr.title or "", author)
    end,
  }, function(choice)
    if not choice then
      return
    end
    on_choice(tostring(choice.number))
  end)
end

return M
