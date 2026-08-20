-- manicule.nvim: import existing GitHub PR review comments as records.
--
-- Best-effort by design: any gh failure notifies WARN and returns — the
-- review session must still open. Imported records carry
-- `meta.github = { id, url, imported = true }`, which (a) dedupes
-- re-imports on `meta.github.id` and (b) excludes them from
-- `review.finish()` and the github sink so GitHub's own comments are
-- never echoed back as a new review.

local M = {}

---True when `record` was imported from GitHub
---(`meta.github.imported == true`).
---@param record table
---@return boolean
function M.is_import(record)
  local meta = type(record) == "table" and type(record.meta) == "table" and record.meta or nil
  local gh = meta and type(meta.github) == "table" and meta.github or nil
  return gh ~= nil and gh.imported == true
end

---`vim.json.decode` turns JSON null into `vim.NIL`; only accept real
---numbers so outdated comments (line=null) are filtered out.
---@param value any
---@return number|nil
local function num(value)
  return type(value) == "number" and value or nil
end

---@param value any
---@return string|nil
local function str(value)
  return type(value) == "string" and value or nil
end

---Fetch review comments for PR `number` and materialize them as
---project records anchored to worktree files under `root` (the PR head
---must be checked out so `comment.path` names real files). Dedupes on
---`meta.github.id`, so re-running `:ManiculeReview pr N` never
---duplicates.
---@param root string git worktree root with the PR head checked out
---@param number string|integer PR number
function M.github_pr(root, number)
  local G = require("manicule.review.git")
  local function warn(msg)
    vim.notify(("manicule: skipping PR comment import: %s"):format(msg), vim.log.levels.WARN)
  end

  local repo_result = G.run({ "gh", "repo", "view", "--json", "nameWithOwner" }, { cwd = root })
  if repo_result.code ~= 0 then
    return warn(vim.trim(repo_result.stderr))
  end
  local repo_ok, repo = pcall(vim.json.decode, repo_result.stdout)
  if not repo_ok or type(repo) ~= "table" or type(repo.nameWithOwner) ~= "string" then
    return warn("unexpected gh repo view output")
  end

  local result = G.run({
    "gh",
    "api",
    ("repos/%s/pulls/%s/comments"):format(repo.nameWithOwner, number),
    "--paginate",
  }, { cwd = root })
  if result.code ~= 0 then
    return warn(vim.trim(result.stderr))
  end
  -- `--paginate` concatenates one JSON array per page (`[...][...]`);
  -- join the page boundaries so multi-page output still decodes.
  local ok, comments = pcall(vim.json.decode, (result.stdout:gsub("%]%s*%[", ",")))
  if not ok or type(comments) ~= "table" then
    return warn("unexpected gh api output")
  end

  local store = require("manicule.store")
  local uri_mod = require("manicule.uri")
  local id_mod = require("manicule.id")

  -- Dedupe against every record already carrying a GitHub comment id.
  local existing = {}
  for _, record in ipairs(store.all(root)) do
    local meta = type(record.meta) == "table" and record.meta or nil
    local gh = meta and type(meta.github) == "table" and meta.github or nil
    if gh and gh.id ~= nil then
      existing[tostring(gh.id)] = true
    end
  end

  local imported = 0
  local now = os.time()
  for _, comment in ipairs(comments) do
    if type(comment) == "table" and type(comment.path) == "string" and not existing[tostring(comment.id)] then
      -- Comments without a line (outdated/resolved positions) are
      -- skipped: there is nothing to anchor them to in the worktree.
      local line = num(comment.line) or num(comment.original_line)
      if line then
        local start_line = num(comment.start_line) or num(comment.original_start_line) or line
        local user = type(comment.user) == "table" and comment.user or {}
        store.put_record({
          id = id_mod.new(),
          uri = uri_mod.for_path(root .. "/" .. comment.path),
          scope = "project",
          project_root = root,
          range = { start = { start_line - 1, 0 }, end_ = { line - 1, 0 } },
          body = str(comment.body) or "",
          author = str(user.login),
          created_at = now,
          updated_at = now,
          resolved = false,
          meta = { github = { id = comment.id, url = str(comment.html_url), imported = true } },
        })
        imported = imported + 1
      end
    end
  end
  if imported == 0 then
    return
  end
  local save_ok, err = store.save(root)
  if not save_ok then
    return warn("failed to persist imported comments: " .. tostring(err))
  end
  vim.notify(("manicule: imported %d PR comment%s"):format(imported, imported == 1 and "" or "s"), vim.log.levels.INFO)
end

return M
