-- manicule.nvim: import existing GitHub PR review comments as records.
--
-- Best-effort by design: any gh failure notifies WARN and returns — the
-- review session must still open. Imported records carry
-- `meta.github = { id, url, imported = true }`, which (a) dedupes
-- re-imports on `meta.github.id` and (b) excludes them from
-- `review.finish()` and the github sink so GitHub's own comments are
-- never echoed back as a new review. A dedupe hit still BACKFILLS
-- thread data (thread_id/thread_node/resolved) onto the existing
-- record, so re-running `:ManiculeReview pr N` refreshes resolve
-- support on records imported before the thread query existed (or
-- when it previously failed).

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
---duplicates — but a dedupe hit backfills missing/changed thread data
---onto the existing record so resolve support can be refreshed.
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

  -- Best-effort resolve support: the REST comments payload carries no
  -- review-thread ids, and resolving needs the THREAD node id. A
  -- GraphQL query maps each thread's first comment databaseId to the
  -- thread node + isResolved, following `pageInfo`/`after:` cursors so
  -- PRs with more than 100 threads still backfill every thread; failure
  -- degrades to import-without-resolve.
  ---@return table<number, {thread_node: string, resolved: boolean}>|nil, string|nil err
  local function fetch_threads()
    local owner, name = repo.nameWithOwner:match("^([^/]+)/(.+)$")
    if not owner then
      return nil, "unexpected repository name " .. repo.nameWithOwner
    end
    local query = "query($owner:String!,$name:String!,$number:Int!,$cursor:String){"
      .. "repository(owner:$owner,name:$name){pullRequest(number:$number){"
      .. "reviewThreads(first:100,after:$cursor){"
      .. "pageInfo{hasNextPage endCursor}"
      .. "nodes{id isResolved comments(first:1){nodes{databaseId}}}}}}}"
    local map = {}
    local cursor = nil
    while true do
      local args = {
        "gh",
        "api",
        "graphql",
        "-f",
        "query=" .. query,
        "-f",
        "owner=" .. owner,
        "-f",
        "name=" .. name,
        "-F",
        "number=" .. tostring(number),
      }
      if cursor then
        args[#args + 1] = "-f"
        args[#args + 1] = "cursor=" .. cursor
      end
      local result = G.run(args, { cwd = root })
      if result.code ~= 0 then
        return nil, vim.trim(result.stderr)
      end
      local ok, decoded = pcall(vim.json.decode, result.stdout)
      local review_threads = ok
        and type(decoded) == "table"
        and vim.tbl_get(decoded, "data", "repository", "pullRequest", "reviewThreads")
      local nodes = type(review_threads) == "table" and review_threads.nodes
      if type(nodes) ~= "table" then
        return nil, "unexpected gh graphql output"
      end
      for _, node in ipairs(nodes) do
        local db = type(node) == "table" and vim.tbl_get(node, "comments", "nodes", 1, "databaseId")
        if type(node.id) == "string" and type(db) == "number" then
          map[db] = { thread_node = node.id, resolved = node.isResolved == true }
        end
      end
      local page_info = type(review_threads.pageInfo) == "table" and review_threads.pageInfo or {}
      cursor = page_info.hasNextPage == true and str(page_info.endCursor) or nil
      if not cursor then
        return map, nil
      end
    end
  end

  local threads = {}
  if #comments > 0 then
    local thread_map, thread_err = fetch_threads()
    if thread_map then
      threads = thread_map
    else
      vim.notify(("manicule: PR thread resolve support unavailable: %s"):format(thread_err), vim.log.levels.WARN)
    end
  end

  local store = require("manicule.store")
  local uri_mod = require("manicule.uri")
  local id_mod = require("manicule.id")

  -- Dedupe against every record already carrying a GitHub comment id.
  -- Map id -> record (not a boolean) so a dedupe hit can backfill.
  local existing = {}
  for _, record in ipairs(store.all(root)) do
    local meta = type(record.meta) == "table" and record.meta or nil
    local gh = meta and type(meta.github) == "table" and meta.github or nil
    if gh and gh.id ~= nil then
      existing[tostring(gh.id)] = record
    end
  end

  ---Backfill thread data onto a deduped record. Returns true when a
  ---`meta.github` field actually changed (caller persists).
  ---@param record table existing record for this comment id
  ---@param comment table incoming REST comment payload
  ---@return boolean changed
  local function backfill(record, comment)
    local gh = record.meta.github
    local thread_id = num(comment.in_reply_to_id) or comment.id
    local thread = threads[thread_id]
    local changed = false
    if gh.thread_id ~= thread_id then
      gh.thread_id = thread_id
      changed = true
    end
    if thread then
      if gh.thread_node ~= thread.thread_node then
        gh.thread_node = thread.thread_node
        changed = true
      end
      if gh.resolved ~= thread.resolved then
        gh.resolved = thread.resolved
        changed = true
      end
    end
    return changed
  end

  local imported = 0
  local updated = 0
  local skipped = 0
  local now = os.time()
  for _, comment in ipairs(comments) do
    local prior = type(comment) == "table" and existing[tostring(comment.id)] or nil
    if prior then
      if backfill(prior, comment) then
        prior.updated_at = now
        store.put_record(prior)
        updated = updated + 1
      end
    elseif type(comment) == "table" and type(comment.path) == "string" then
      -- `line`/`start_line` are coordinates in the file named by
      -- `side`/`start_side`: RIGHT is the checked-out head worktree,
      -- LEFT is the base. Comments on the base side and comments
      -- without a current line (outdated positions, where only
      -- `original_line` — a superseded head commit's coordinate —
      -- remains) are skipped: neither anchors to the worktree.
      local line = comment.side ~= "LEFT" and num(comment.line) or nil
      if line then
        local start_line = comment.start_side ~= "LEFT" and num(comment.start_line) or nil
        start_line = start_line or line
        local user = type(comment.user) == "table" and comment.user or {}
        -- Replies chain to the thread ROOT (GitHub's replies endpoint
        -- rejects reply-to-a-reply ids), so record the root id up front:
        -- the comment's own id for top-level comments, its
        -- in_reply_to_id otherwise.
        local thread_id = num(comment.in_reply_to_id) or comment.id
        local thread = threads[thread_id]
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
          meta = {
            github = {
              id = comment.id,
              url = str(comment.html_url),
              imported = true,
              thread_id = thread_id,
              pr = tonumber(number),
              thread_node = thread and thread.thread_node or nil,
              resolved = thread and thread.resolved or nil,
            },
          },
        })
        imported = imported + 1
      else
        skipped = skipped + 1
      end
    end
  end
  local skip_note = skipped > 0
      and (" (%d skipped: outdated or base-side position%s)"):format(skipped, skipped == 1 and "" or "s")
    or ""
  if imported == 0 and updated == 0 then
    if skipped > 0 then
      vim.notify("manicule: imported 0 PR comments" .. skip_note, vim.log.levels.INFO)
    end
    return
  end
  local save_ok, err = store.save(root)
  if not save_ok then
    return warn("failed to persist imported comments: " .. tostring(err))
  end
  if imported > 0 then
    vim.notify(
      ("manicule: imported %d PR comment%s"):format(imported, imported == 1 and "" or "s") .. skip_note,
      vim.log.levels.INFO
    )
  end
end

return M
