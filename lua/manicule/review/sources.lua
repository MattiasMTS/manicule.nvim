-- manicule.nvim: review source resolvers.
--
-- Turn `:ManiculeReview` arguments into staged diff pairs. Registry is
-- open: register({name, match, resolve}) prepends, so user resolvers
-- shadow builtins.

local M = {}

local registry = {}
local uv = vim.uv or vim.loop

---Create a staging directory that does NOT match the nvim runtime staged-path
---pattern (nvim.<user>/<run-id>/<N>/...), so adapter.identify won't refuse
---comments on deleted files whose worktree path no longer exists.
---
---Uses $TMPDIR or /tmp directly, avoiding vim.fn.tempname() which nests under
---nvim.<user>/<run-id>/. The pattern matches any path containing that segment.
local function make_stage_dir()
  local tmpdir = os.getenv("TMPDIR") or "/tmp"
  tmpdir = tmpdir:gsub("/$", "") -- strip trailing slash
  local dir = uv.fs_mkdtemp(tmpdir .. "/manicule-review-XXXXXX")
  if not dir or dir == "" or dir == "/" then
    -- fs_mkdtemp failed; fall back to plain tempname and mkdir.
    -- This is a degraded path but won't block the review.
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

---@param resolver {name: string, match: fun(fargs: string[]): boolean, resolve: fun(fargs: string[], opts: table): table|nil, string|nil}
function M.register(resolver)
  table.insert(registry, 1, resolver)
end

local function is_dir(path)
  return path and vim.fn.isdirectory(path) == 1
end

local function read_all(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

---Do `left` and `right` hold identical bytes? Sizes are compared first
---(one fs_stat each): different sizes cannot match, so only same-size
---pairs pay the two full reads.
local function same_file(left, right)
  local lstat, rstat = uv.fs_stat(left), uv.fs_stat(right)
  if lstat and rstat and lstat.size ~= rstat.size then
    return false
  end
  return read_all(left) == read_all(right)
end

local function list_files(dir)
  local out = {}
  local base = dir:gsub("/$", "")
  -- vim.fs.find's name predicate cannot prune descent — the walk visits
  -- every directory and the predicate only filters what is RETURNED, so
  -- a `.git` predicate still walked the whole .git tree and returned its
  -- internals (HEAD, objects, ...) as reviewable files. vim.fs.dir's
  -- `skip` prunes the walk itself; entries named `.git` (worktree gitdir
  -- pointer files) are dropped from the results too, matching the old
  -- predicate's intent.
  for rel, type_ in
    vim.fs.dir(base, {
      depth = math.huge,
      skip = function(dir_rel)
        return dir_rel:match("[^/]+$") ~= ".git"
      end,
    })
  do
    if type_ == "file" and rel:match("[^/]+$") ~= ".git" then
      out[rel] = base .. "/" .. rel
    end
  end
  return out
end

-- Builtin: two existing directories.
M.register({
  name = "dirs",
  match = function(fargs)
    return #fargs == 2 and is_dir(fargs[1]) and is_dir(fargs[2])
  end,
  resolve = function(fargs)
    local left_dir, right_dir = fargs[1], fargs[2]
    local lefts = list_files(left_dir)
    local rights = list_files(right_dir)
    local files = {}
    local paths = {}
    for rel in pairs(lefts) do
      paths[rel] = true
    end
    for rel in pairs(rights) do
      paths[rel] = true
    end
    local sorted = vim.tbl_keys(paths)
    table.sort(sorted)
    -- ONE lazily-created stage dir shared by every right-only file: a
    -- per-file mkdtemp costs a subprocess-free but real syscall per
    -- added file and leaves N dirs for stop() cleanup to track.
    local stage_root
    for _, rel in ipairs(sorted) do
      local left, right = lefts[rel], rights[rel]
      if left and right then
        if not same_file(left, right) then
          table.insert(files, { left = left, right = right, status = "M", path = rel })
        end
      elseif left then
        table.insert(files, { left = left, right = right_dir .. "/" .. rel, status = "D", path = rel })
      else
        -- Right-only: stage an empty left so the diff shows all-added.
        stage_root = stage_root or make_stage_dir()
        local staged = stage_root .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(staged, ":h"), "p")
        vim.fn.writefile({}, staged)
        table.insert(files, { left = staged, right = right, status = "A", path = rel })
      end
    end
    return { files = files, label = "dirs", stage_dirs = stage_root and { stage_root } or nil }
  end,
})

-- Builtin: git ref (or bare = HEAD).
M.register({
  name = "git",
  match = function(fargs)
    return #fargs <= 1
  end,
  resolve = function(fargs, opts)
    local G = require("manicule.review.git")
    local cwd = opts.cwd or (vim.uv or vim.loop).cwd()
    local root = G.root(cwd)
    if not root then
      return nil, "manicule: not a git repository and arguments are not directories"
    end
    local ref = fargs[1] or "HEAD"
    local base, err
    if ref == "HEAD" then
      base, err = G.rev_parse(root, "HEAD")
    else
      base, err = G.merge_base(root, "HEAD", ref)
    end
    if not base then
      return nil, err
    end
    local changed, cerr = G.changed_files(root, base)
    if not changed then
      return nil, cerr
    end
    if #changed == 0 then
      return nil, ("manicule: no changes vs %s"):format(ref)
    end
    -- Only a dir THIS resolver created is reported for stop() cleanup;
    -- a caller-provided stage_dir stays the caller's to manage.
    local stage_dir = opts.stage_dir
    local stage_dirs
    if not stage_dir then
      stage_dir = make_stage_dir()
      stage_dirs = { stage_dir }
    end
    return {
      files = G.stage_baseline(root, base, changed, stage_dir),
      label = ref,
      stage_dirs = stage_dirs,
    }
  end,
})

-- Builtin: GitHub PR via gh CLI (auth owned by gh, octo.nvim pattern).
M.register({
  name = "pr",
  match = function(fargs)
    return fargs[1] == "pr" and tonumber(fargs[2]) ~= nil
  end,
  resolve = function(fargs, opts)
    local G = require("manicule.review.git")
    if vim.fn.executable("gh") ~= 1 then
      return nil, "manicule: pr resolver requires the gh CLI (https://cli.github.com)"
    end
    local cwd = opts.cwd or (vim.uv or vim.loop).cwd()
    local root = G.root(cwd)
    if not root then
      return nil, "manicule: not a git repository"
    end
    local number = fargs[2]
    local result = G.run({ "gh", "pr", "view", number, "--json", "baseRefOid,headRefOid,title" }, { cwd = root })
    if result.code ~= 0 then
      return nil, ("manicule: gh pr view failed: %s"):format(vim.trim(result.stderr))
    end
    local ok, meta = pcall(vim.json.decode, result.stdout)
    if not ok or type(meta) ~= "table" or not meta.headRefOid then
      return nil, "manicule: unexpected gh pr view output"
    end
    -- Ensure both oids exist locally before diffing.
    for _, oid in ipairs({ meta.baseRefOid, meta.headRefOid }) do
      if not G.rev_parse(root, oid) then
        local fetch = G.run({ "git", "-C", root, "fetch", "-q", "origin", oid })
        if fetch.code ~= 0 then
          return nil, ("manicule: cannot fetch %s: %s"):format(oid, vim.trim(fetch.stderr))
        end
      end
    end
    local base, err = G.merge_base(root, meta.baseRefOid, meta.headRefOid)
    if not base then
      return nil, err
    end
    -- Same ownership rule as the git resolver: report only a
    -- self-created stage dir for stop() cleanup.
    local stage_dir = opts.stage_dir
    local stage_dirs
    if not stage_dir then
      stage_dir = make_stage_dir()
      stage_dirs = { stage_dir }
    end
    local head = G.rev_parse(root, "HEAD")
    local label = ("pr %s"):format(number)
    if type(meta.title) == "string" and meta.title ~= "" then
      label = ("%s: %s"):format(label, meta.title)
    end
    -- Carry the PR number into the session's sink context: without it,
    -- `:ManiculeReviewFinish github` falls back to `gh pr view` on the
    -- CURRENT branch and posts a non-checked-out PR's review to the
    -- wrong PR (or fails confusingly).
    local sink_ctx = { pr = tonumber(number) }

    if head == meta.headRefOid then
      -- PR head is checked out: right side = worktree, normal pairs.
      local changed, cerr = G.changed_files(root, base)
      if not changed then
        return nil, cerr
      end
      -- changed_files compares vs worktree; for a clean checkout this
      -- equals base..head. Filter out entries with no content diff is
      -- unnecessary — git already did it.
      if #changed == 0 then
        return nil, ("manicule: no changes in %s"):format(label)
      end
      -- Right side = real worktree files, so existing PR review comments
      -- can anchor to them. Best-effort: failures notify and continue.
      require("manicule.review.import").github_pr(root, number)
      return {
        files = G.stage_baseline(root, base, changed, stage_dir),
        label = label,
        sink_ctx = sink_ctx,
        stage_dirs = stage_dirs,
      }
    end

    -- Head not checked out: stage BOTH sides (comments land on staged
    -- right files as session-scope records; documented limitation).
    -- Existing PR comments are NOT imported here: both sides are temp
    -- paths with session-scope identity, not worth anchoring to.
    vim.notify(
      ("manicule: %s head is not checked out; skipping GitHub comment import"):format(label),
      vim.log.levels.INFO
    )
    -- `-z` keeps paths literal: without it core.quotePath=true C-quotes
    -- non-ASCII names and the quoted string would become entry.path.
    local diff = G.run({ "git", "-C", root, "diff", "--name-status", "--no-renames", "-z", base, meta.headRefOid })
    if diff.code ~= 0 then
      return nil, ("manicule: git diff failed: %s"):format(vim.trim(diff.stderr))
    end
    local entries = G.parse_name_status(diff.stdout)
    if #entries == 0 then
      return nil, ("manicule: no changes in %s"):format(label)
    end
    -- Stage each side with one batched materialize pass (chunked
    -- `git archive` + `tar`, see docs/performance.md) instead of two
    -- `git show` forks per file. The side a file does not exist on
    -- (base for "A", head for "D") gets an empty staged file so the
    -- diff shows all-added/all-removed.
    local base_dir = stage_dir .. "/base"
    local head_dir = stage_dir .. "/head"
    local base_paths, head_paths = {}, {}
    for _, entry in ipairs(entries) do
      if entry.status ~= "A" then
        table.insert(base_paths, entry.path)
      end
      if entry.status ~= "D" then
        table.insert(head_paths, entry.path)
      end
    end
    G.materialize(root, base, base_paths, base_dir)
    G.materialize(root, meta.headRefOid, head_paths, head_dir)
    local files = {}
    for _, entry in ipairs(entries) do
      local left = base_dir .. "/" .. entry.path
      local right = head_dir .. "/" .. entry.path
      local empty = (entry.status == "A" and left) or (entry.status == "D" and right)
      if empty then
        vim.fn.mkdir(vim.fn.fnamemodify(empty, ":h"), "p")
        vim.fn.writefile({}, empty)
      end
      table.insert(files, { left = left, right = right, status = entry.status, path = entry.path })
    end
    return { files = files, label = label, sink_ctx = sink_ctx, stage_dirs = stage_dirs }
  end,
})

---@param fargs string[]
---@param opts? {cwd?: string, stage_dir?: string}
---@return {files: table[], label: string, sink_ctx?: table, stage_dirs?: string[]}|nil, string|nil err
function M.resolve(fargs, opts)
  opts = opts or {}
  for _, resolver in ipairs(registry) do
    if resolver.match(fargs) then
      return resolver.resolve(fargs, opts)
    end
  end
  return nil, ("manicule: cannot resolve review arguments: %s"):format(table.concat(fargs, " "))
end

return M
