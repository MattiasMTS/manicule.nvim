-- manicule.nvim: GitHub PR review sink.
--
-- Posts the comment batch as a pull-request review through the gh CLI
-- (REST: POST /repos/{owner}/{repo}/pulls/{n}/reviews). The target PR
-- comes from ctx.pr when given, otherwise `gh pr view` resolves the PR
-- for the current branch. gh is always invoked with argv only — the
-- JSON review body travels via a temp file passed to `gh api --input`,
-- never through a shell string.

local helpers = require("manicule.sinks.helpers")

local M = {}

local uv = vim.uv or vim.loop

local VALID_EVENTS = { COMMENT = true, REQUEST_CHANGES = true, APPROVE = true }

local function defaults()
  return {
    command = "gh",
    event = "COMMENT",
    -- Posting a review to GitHub is a copy, not a hand-off: keep the
    -- local records unless the user explicitly opts in to clearing.
    clear_on_success = false,
    pre_text = nil,
  }
end

local function normalize_opts(opts)
  opts = vim.tbl_deep_extend("force", defaults(), opts or {})
  opts.enabled = nil
  if not VALID_EVENTS[opts.event] then
    error(
      ('manicule: github sink event must be "COMMENT", "REQUEST_CHANGES", or "APPROVE", got %q'):format(
        tostring(opts.event)
      )
    )
  end
  return opts
end

local function cli(opts)
  return opts.command or "gh"
end

---Pick the working directory for gh calls: explicit ctx.cwd, then the
---first record's project root, then the process cwd.
local function resolve_cwd(ctx, comments)
  if type(ctx.cwd) == "string" and ctx.cwd ~= "" then
    return ctx.cwd
  end
  for _, comment in ipairs(comments or {}) do
    if type(comment.project_root) == "string" and comment.project_root ~= "" then
      return comment.project_root
    end
  end
  return uv.cwd()
end

local function gh_json(opts, argv, cwd)
  local full = { cli(opts) }
  vim.list_extend(full, argv)
  local result = helpers.system(full, { cwd = cwd })
  if result.code ~= 0 then
    return nil, result.stderr:gsub("%s+$", "")
  end
  local ok, decoded = pcall(vim.json.decode, result.stdout)
  if not ok or type(decoded) ~= "table" then
    return nil, "gh returned invalid JSON: " .. result.stdout:sub(1, 200)
  end
  return decoded, nil
end

local function resolve_pr(opts, ctx, cwd)
  local explicit = tonumber(ctx.pr)
  if explicit then
    return explicit, nil
  end
  local decoded, err = gh_json(opts, { "pr", "view", "--json", "number" }, cwd)
  if not decoded or type(decoded.number) ~= "number" then
    local detail = err and err ~= "" and (" (" .. err .. ")") or ""
    return nil, "manicule: no open PR for this branch; pass ctx.pr or check out the PR branch" .. detail
  end
  return decoded.number, nil
end

local function resolve_repo(opts, cwd)
  local decoded, err = gh_json(opts, { "repo", "view", "--json", "nameWithOwner" }, cwd)
  if not decoded or type(decoded.nameWithOwner) ~= "string" then
    return nil, "manicule: could not resolve GitHub repository via gh repo view" .. (err and (": " .. err) or "")
  end
  return decoded.nameWithOwner, nil
end

---`meta.github_reply` payload for a record authored as a thread reply
---(via the review panel's `r` action), or nil.
---@param comment table
---@return {to: number|string, pr?: number}|nil
local function reply_meta(comment)
  local meta = type(comment.meta) == "table" and comment.meta or nil
  local reply = meta and type(meta.github_reply) == "table" and meta.github_reply or nil
  return (reply and reply.to ~= nil) and reply or nil
end

---Build the REST review payload. Records whose URI cannot be resolved to
---a project-relative path (session-scope temp buffers, files outside the
---root) are skipped; the skip count is noted in the review body. Records
---carrying `meta.github_reply` are returned separately — they post to
---the thread-replies endpoint, never inside the review. Records already
---posted by an earlier send (`meta.github_sent`) are excluded so a
---re-send — after full success or a partial failure — never duplicates.
---@param event string the review verdict for this send
local function build_review(comments, opts, event)
  local review_comments = {}
  local review_records = {}
  local replies = {}
  local skipped = 0
  local skipped_imported = 0
  local already_sent = 0
  local is_import = require("manicule.review.import").is_import
  for _, comment in ipairs(comments) do
    local path = helpers.relative_path(comment)
    local reply = reply_meta(comment)
    local meta = type(comment.meta) == "table" and comment.meta or nil
    if meta and meta.github_sent ~= nil then
      -- Posted by a previous send (full or partial): never repost.
      already_sent = already_sent + 1
    elseif is_import(comment) then
      -- Never echo comments imported FROM GitHub back as a new review.
      skipped_imported = skipped_imported + 1
    elseif reply then
      table.insert(replies, { to = reply.to, pr = tonumber(reply.pr), body = comment.body or "", record = comment })
    elseif not path or path == "." then
      skipped = skipped + 1
    else
      local start_lnum, end_lnum = helpers.line_span(comment)
      local entry = {
        path = path,
        line = end_lnum,
        side = "RIGHT",
        body = comment.body or "",
      }
      if end_lnum > start_lnum then
        entry.start_line = start_lnum
        entry.start_side = "RIGHT"
      end
      table.insert(review_comments, entry)
      table.insert(review_records, comment)
    end
  end

  local summary = ("Manicule review: %d comment%s"):format(#review_comments, #review_comments == 1 and "" or "s")
  if skipped > 0 then
    summary = summary .. (" (%d skipped: no repository-relative path)"):format(skipped)
  end
  if skipped_imported > 0 then
    summary = summary .. (" (%d skipped: imported from GitHub)"):format(skipped_imported)
  end
  if already_sent > 0 then
    summary = summary .. (" (%d already sent)"):format(already_sent)
  end
  if #replies > 0 then
    summary = summary .. (" (%d thread repl%s posted separately)"):format(#replies, #replies == 1 and "y" or "ies")
  end
  local body = summary
  if type(opts.pre_text) == "string" and vim.trim(opts.pre_text) ~= "" then
    body = vim.trim(opts.pre_text) .. "\n\n" .. summary
  end

  local payload = {
    event = event,
    body = body,
    comments = review_comments,
  }
  return payload, skipped + skipped_imported, replies, review_records, already_sent
end

---Mark each record as posted (`meta.github_sent = os.time()`) and
---persist through the owning store — the same put+save path record
---mutations like review resolve use. Ad-hoc tables without a store home
---(no id / no root) still get the in-memory marker. Marking happens
---per posted unit, so a partial failure retries only the remainder.
local function mark_sent(records)
  local store = require("manicule.store")
  local roots = {}
  local session = false
  local now = os.time()
  for _, record in ipairs(records) do
    if type(record) == "table" then
      if type(record.meta) ~= "table" then
        record.meta = {}
      end
      record.meta.github_sent = now
      if record.id ~= nil then
        if record.scope == "session" then
          store.session_put(record)
          session = true
        elseif type(record.project_root) == "string" and record.project_root ~= "" then
          store.put(record.project_root, record)
          roots[record.project_root] = true
        end
      end
    end
  end
  if session then
    store.session_save()
  end
  for root in pairs(roots) do
    store.save(root)
  end
end

local function post_review(opts, repo, pr, review, cwd)
  local tmp = vim.fn.tempname() .. ".json"
  -- `writefile` can also signal failure by returning -1 without throwing.
  local write_ok, wrote = pcall(vim.fn.writefile, { vim.json.encode(review) }, tmp)
  if not write_ok or wrote ~= 0 then
    return false, "manicule: github sink could not write review payload to " .. tmp
  end
  local result = helpers.system({
    cli(opts),
    "api",
    ("repos/%s/pulls/%d/reviews"):format(repo, pr),
    "--method",
    "POST",
    "--input",
    tmp,
  }, { cwd = cwd })
  vim.fn.delete(tmp)
  if result.code ~= 0 then
    return false, "manicule: gh api failed: " .. result.stderr:gsub("%s+$", "")
  end
  return true, nil
end

---Post one thread reply: POST /repos/{owner}/{repo}/pulls/{n}/comments/{id}/replies.
---The reply's own PR number (recorded at import time) wins over the
---review's resolved PR so replies land on the thread they came from.
local function post_reply(opts, repo, pr, reply, cwd)
  local target_pr = reply.pr or pr
  local result = helpers.system({
    cli(opts),
    "api",
    ("repos/%s/pulls/%d/comments/%s/replies"):format(repo, target_pr, tostring(reply.to)),
    "--method",
    "POST",
    "-f",
    "body=" .. reply.body,
  }, { cwd = cwd })
  if result.code ~= 0 then
    return false, "manicule: gh api reply failed: " .. result.stderr:gsub("%s+$", "")
  end
  return true, nil
end

---Whether the github integration can be used in the current environment.
---@param opts? table
---@return boolean
function M.is_available(opts)
  opts = normalize_opts(opts)
  return helpers.executable(cli(opts))
end

---Build a github sink spec.
---@param opts? {command?: string, event?: string, clear_on_success?: boolean, pre_text?: string}
---@return table
function M.setup(opts)
  opts = normalize_opts(opts)
  return {
    name = "github",
    type = "integration",
    label = "GitHub PR review",
    description = "post comments as a pull-request review via gh",
    clear_on_success = opts.clear_on_success == true,
    pre_text = opts.pre_text,
    validate = function(ctx)
      if not helpers.executable(cli(opts)) then
        return false, "manicule: github sink requires the gh executable"
      end
      local cwd = resolve_cwd(ctx or {}, nil)
      local result = helpers.system({ "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" })
      if result.code ~= 0 then
        return false, "manicule: github sink requires a git repository (cwd: " .. cwd .. ")"
      end
      return true
    end,
    health = function()
      return {
        available = M.is_available(opts),
        gh = vim.fn.exepath(cli(opts)),
      }
    end,
    send = function(comments, ctx, cb)
      -- Per-send verdict: ctx.event (from `:ManiculeSend github <verdict>`)
      -- overrides the configured opts.event.
      local event = opts.event
      if ctx.event ~= nil then
        if not VALID_EVENTS[ctx.event] then
          cb(
            false,
            ('manicule: github sink ctx.event must be "COMMENT", "REQUEST_CHANGES", or "APPROVE", got %q'):format(
              tostring(ctx.event)
            )
          )
          return
        end
        event = ctx.event
      end
      local cwd = resolve_cwd(ctx, comments)
      local review, skipped, replies, review_records, already_sent = build_review(comments, opts, event)
      if #review.comments == 0 and #replies == 0 then
        if already_sent > 0 then
          vim.notify(
            ("manicule: github sink: %d already sent; nothing new to post"):format(already_sent),
            vim.log.levels.INFO
          )
          cb(true, nil)
          return
        end
        cb(
          false,
          ("manicule: github sink found no comments with a resolvable repository path (%d skipped)"):format(skipped)
        )
        return
      end
      local repo, repo_err = resolve_repo(opts, cwd)
      if not repo then
        cb(false, repo_err)
        return
      end
      local pr, pr_err = resolve_pr(opts, ctx, cwd)
      if not pr then
        cb(false, pr_err)
        return
      end
      if #review.comments > 0 then
        local ok, err = post_review(opts, repo, pr, review, cwd)
        if not ok then
          cb(false, err)
          return
        end
        mark_sent(review_records)
      end
      -- Replies post independently: mark each success immediately and
      -- collect failures, so a retry re-attempts ONLY what failed.
      local errors = {}
      for _, reply in ipairs(replies) do
        local ok, err = post_reply(opts, repo, pr, reply, cwd)
        if ok then
          mark_sent({ reply.record })
        else
          table.insert(errors, err)
        end
      end
      if #errors > 0 then
        cb(
          false,
          table.concat(errors, "; ")
            .. " (already-posted items were marked sent and will not repost; retry sends only the remainder)"
        )
        return
      end
      cb(true, nil)
    end,
  }
end

return M
