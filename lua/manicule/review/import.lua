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

  local endpoint = ("repos/%s/pulls/%s/comments"):format(repo.nameWithOwner, number)

  -- Prefer `--paginate --slurp`: gh wraps one JSON array per page in an
  -- outer array, so page boundaries never require rewriting the payload
  -- (a gsub on `][` would corrupt comment bodies containing brackets).
  ---@return table|nil comments, string|nil err
  local function fetch_comments()
    local result = G.run({ "gh", "api", endpoint, "--paginate", "--slurp" }, { cwd = root })
    if result.code == 0 then
      local ok, pages = pcall(vim.json.decode, result.stdout)
      if not ok or type(pages) ~= "table" then
        return nil, "unexpected gh api output"
      end
      local comments = {}
      for _, page in ipairs(pages) do
        if type(page) ~= "table" then
          return nil, "unexpected gh api output"
        end
        for _, comment in ipairs(page) do
          comments[#comments + 1] = comment
        end
      end
      return comments, nil
    end
    local stderr = result.stderr:lower()
    if not (stderr:find("slurp", 1, true) or stderr:find("unknown flag", 1, true)) then
      return nil, vim.trim(result.stderr)
    end
    -- gh too old for `--slurp`: fetch pages manually until a short page.
    local per_page = 100
    local comments = {}
    local page = 1
    while true do
      local r = G.run({ "gh", "api", ("%s?page=%d&per_page=%d"):format(endpoint, page, per_page) }, { cwd = root })
      if r.code ~= 0 then
        return nil, vim.trim(r.stderr)
      end
      local ok, list = pcall(vim.json.decode, r.stdout)
      if not ok or type(list) ~= "table" then
        return nil, "unexpected gh api output"
      end
      for _, comment in ipairs(list) do
        comments[#comments + 1] = comment
      end
      if #list < per_page then
        return comments, nil
      end
      page = page + 1
    end
  end

  local comments, fetch_err = fetch_comments()
  if not comments then
    return warn(fetch_err)
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
