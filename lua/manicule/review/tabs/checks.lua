-- manicule.nvim: builtin "Checks" review-panel tab — CI status for the
-- session under review.
--
-- Registers through panel.register_tab (see review/tabs/init.lua, whose
-- `done` guard keeps the per-open setup() call idempotent; tests
-- re-register after panel._reset_tabs()). PR sessions
-- (session.sink_ctx.pr) list the PR's checks via `gh pr checks`; other
-- sessions fall back to `gh run list --branch <current branch>` when
-- the session root's branch has an upstream. Both shapes normalize to
-- {name, state pass|fail|running|skipped, url, elapsed} and render
-- sorted fail → running → pass → skipped.
--
-- The fetch runs asynchronously (sinks helpers' system_async) on
-- entering the tab and is cached per session with a `fetching` guard;
-- `R` drops the cache and refetches, `<CR>`/`gl` open the row's page in
-- the browser. No polling/timers in v1 — a refresh poll could hang off
-- on_show later if live updates prove worth it.

local M = {}

---Per-session tab state, weak-keyed so it dies with the session table:
---  upstream  boolean|nil  cached `@{upstream}` probe (nil = not probed)
---  fetching  boolean      an async gh call is in flight
---  done      boolean      a fetch completed (checks or error below set)
---  checks    table[]|nil  normalized {name, state, url, elapsed}
---  error     string|nil   fetch failure message (rendered as a dim row)
---@type table<table, table>
local states = setmetatable({}, { __mode = "k" })

---@param session table
---@return table
local function state_for(session)
  local st = states[session]
  if not st then
    st = {}
    states[session] = st
  end
  return st
end

---Executable for GitHub calls: honours `sinks.github.command` — the
---same knob the github sink and review/github.lua read — and falls back
---to plain `gh`.
---@return string
local function gh_cli()
  local sinks = require("manicule.config").get().sinks
  local github = type(sinks) == "table" and sinks.github or nil
  if type(github) == "table" and type(github.command) == "string" and github.command ~= "" then
    return github.command
  end
  return "gh"
end

---The session's PR number, or nil for non-PR sessions.
---@param session table
---@return integer|nil
local function session_pr(session)
  local sink_ctx = type(session.sink_ctx) == "table" and session.sink_ctx or nil
  return sink_ctx and tonumber(sink_ctx.pr) or nil
end

-- ------------------------------------------------------------------
-- Elapsed formatting
-- ------------------------------------------------------------------

---Epoch seconds for an ISO-8601 UTC timestamp ("2024-01-01T12:00:34Z"),
---or nil for missing/unparseable input and Go zero-value timestamps
---(gh emits "0001-01-01T00:00:00Z" for unstarted checks). os.time
---interprets the fields as LOCAL time, so shift by the local-UTC offset
---— differences between two timestamps would cancel it, but the
---running-elapsed path compares against a real epoch.
---@param ts any
---@return integer|nil
local function iso_epoch(ts)
  if type(ts) ~= "string" or ts:sub(1, 5) == "0001-" then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match("^(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local t = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  return t + os.difftime(t, os.time(os.date("!*t", t)))
end

---`18s` / `2m 14s`, clamped at zero.
---@param secs number
---@return string
local function span(secs)
  secs = math.max(0, math.floor(secs))
  if secs < 60 then
    return ("%ds"):format(secs)
  end
  return ("%dm %ds"):format(math.floor(secs / 60), secs % 60)
end

---Elapsed display for one check: `2m 14s` when finished, `running
---34s…` while going, nil when `started` is missing. Pure — `now`
---(epoch seconds, defaulting to os.time()) is injectable for tests.
---@param started any ISO-8601 start timestamp
---@param completed any ISO-8601 end timestamp, nil while running
---@param now? integer
---@return string|nil
function M._elapsed(started, completed, now)
  local from = iso_epoch(started)
  if not from then
    return nil
  end
  local to = iso_epoch(completed)
  if to then
    return span(to - from)
  end
  return ("running %s\u{2026}"):format(span((now or os.time()) - from))
end

-- ------------------------------------------------------------------
-- Fetch + normalize
-- ------------------------------------------------------------------

---`gh pr checks --json state` values -> normalized state. The values gh
---leaves out of this map (IN_PROGRESS, QUEUED, PENDING, WAITING, …) are
---all in-flight, so unknowns default to "running".
local PR_STATES = {
  SUCCESS = "pass",
  NEUTRAL = "pass",
  SKIPPED = "skipped",
  SKIPPING = "skipped",
  FAILURE = "fail",
  ERROR = "fail",
  CANCELLED = "fail",
  TIMED_OUT = "fail",
  ACTION_REQUIRED = "fail",
  STARTUP_FAILURE = "fail",
  STALE = "fail",
}

---One `gh pr checks` item -> {name, state, url, elapsed}.
---@param item table
---@return table
local function pr_check(item)
  local state = PR_STATES[tostring(item.state or ""):upper()] or "running"
  return {
    name = tostring(item.name or "?"),
    state = state,
    url = type(item.link) == "string" and item.link or nil,
    elapsed = M._elapsed(item.startedAt, state ~= "running" and item.completedAt or nil),
  }
end

---`gh run list --json conclusion` values -> normalized state for
---COMPLETED runs (failure/cancelled/timed_out/… all read as "fail").
local RUN_CONCLUSIONS = { success = "pass", neutral = "pass", skipped = "skipped" }

---One `gh run list` item -> {name, state, url, elapsed}.
---@param item table
---@return table
local function run_check(item)
  local state
  if tostring(item.status or "") == "completed" then
    state = RUN_CONCLUSIONS[tostring(item.conclusion or ""):lower()] or "fail"
  else
    state = "running"
  end
  return {
    name = tostring(item.name or "?"),
    state = state,
    url = type(item.url) == "string" and item.url or nil,
    elapsed = M._elapsed(item.startedAt, state ~= "running" and item.updatedAt or nil),
  }
end

---The session root's current branch, or nil (no root, not a repo,
---detached HEAD reads back as "HEAD" and still names something gh can
---filter on — pass it through).
---@param session table
---@return string|nil
local function current_branch(session)
  if type(session.root) ~= "string" then
    return nil
  end
  local ok, result = pcall(require("manicule.sinks.helpers").system, {
    "git",
    "-C",
    session.root,
    "rev-parse",
    "--abbrev-ref",
    "HEAD",
  })
  if not (ok and result.code == 0) then
    return nil
  end
  local branch = vim.trim(result.stdout)
  return branch ~= "" and branch or nil
end

---Fetch the session's checks once: `gh pr checks` for PR sessions, `gh
---run list` on the current branch otherwise. No-ops while a fetch is in
---flight or after one completed (R resets the guard). `gh pr checks`
---exits non-zero when checks are failing or pending, so a parseable
---stdout wins over the exit code.
---@param ctx manicule.PanelTabCtx
local function fetch(ctx)
  local session = ctx.session
  if not session then
    return
  end
  local st = state_for(session)
  if st.fetching or st.done then
    return
  end
  local gh = gh_cli()
  local argv, normalize
  local pr = session_pr(session)
  if pr then
    argv = { gh, "pr", "checks", tostring(pr), "--json", "name,state,link,startedAt,completedAt" }
    normalize = pr_check
  else
    local branch = current_branch(session)
    if not branch then
      st.done = true
      st.error = "could not resolve the session branch"
      return
    end
    argv = {
      gh,
      "run",
      "list",
      "--branch",
      branch,
      "--json",
      "name,status,conclusion,url,startedAt,updatedAt",
      "--limit",
      "30",
    }
    normalize = run_check
  end
  st.fetching = true
  require("manicule.sinks.helpers").system_async(argv, { cwd = session.root }, function(result)
    st.fetching = false
    st.done = true
    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if ok and type(decoded) == "table" and vim.islist(decoded) then
      local checks = {}
      for _, item in ipairs(decoded) do
        if type(item) == "table" then
          checks[#checks + 1] = normalize(item)
        end
      end
      st.checks = checks
      st.error = nil
    else
      st.checks = nil
      local stderr = vim.trim(result.stderr)
      st.error = stderr ~= "" and stderr or ("gh exited with code %d"):format(result.code)
    end
    ctx.refresh()
  end)
end

-- ------------------------------------------------------------------
-- Tab spec: availability, title, build, keymaps
-- ------------------------------------------------------------------

---Available when gh is executable AND the session either came from a PR
---or its root's current branch has an upstream to look up runs for. The
---upstream probe (`git rev-parse --abbrev-ref @{upstream}`) runs ONCE
---per session and is cached; availability is re-evaluated per render.
---@param session table|nil
---@return boolean
local function available(session)
  if not session or vim.fn.executable(gh_cli()) ~= 1 then
    return false
  end
  if session_pr(session) then
    return true
  end
  if type(session.root) ~= "string" then
    return false
  end
  local st = state_for(session)
  if st.upstream == nil then
    local ok, result = pcall(require("manicule.sinks.helpers").system, {
      "git",
      "-C",
      session.root,
      "rev-parse",
      "--abbrev-ref",
      "@{upstream}",
    })
    st.upstream = ok and result.code == 0
  end
  return st.upstream
end

---Winbar label: `Checks` before the first fetch (and on error or an
---empty check list), `Checks ✗` once any check failed, else
---`Checks <passed>/<total>`.
---@param ctx manicule.PanelTabCtx
---@return string
local function title(ctx)
  local st = ctx.session and states[ctx.session] or nil
  local checks = st and st.checks or nil
  if not checks or #checks == 0 then
    return "Checks"
  end
  local passed = 0
  for _, check in ipairs(checks) do
    if check.state == "fail" then
      return "Checks \u{2717}"
    end
    if check.state == "pass" then
      passed = passed + 1
    end
  end
  return ("Checks %d/%d"):format(passed, #checks)
end

---state -> {glyph, highlight} for the row lead.
local GLYPHS = {
  fail = { "\u{2717}", "DiagnosticError" },
  pass = { "\u{2713}", "DiagnosticOk" },
  running = { "\u{25CF}", "DiagnosticInfo" },
  skipped = { "\u{25CB}", "Comment" },
}

---Render order: failures first, then in-flight, passes, skips.
local ORDER = { "fail", "running", "pass", "skipped" }

---`✗ lint-test (ubuntu, nightly)  1m 48s` — colored glyph, dim elapsed.
---@param check table normalized check
---@return manicule.PanelRow
local function check_row(check)
  local glyph = GLYPHS[check.state]
  local text = glyph[1] .. " " .. check.name
  local spans = { { 0, #glyph[1], glyph[2] } }
  if check.elapsed then
    spans[#spans + 1] = { #text + 2, #text + 2 + #check.elapsed, "Comment" }
    text = text .. "  " .. check.elapsed
  end
  return {
    text = text,
    spans = spans,
    data = { name = check.name, state = check.state, url = check.url },
  }
end

---A fully dim row (loading/error/empty states and the footer).
---@param text string
---@return manicule.PanelRow
local function dim_row(text)
  return { text = text, spans = { { 0, #text, "Comment" } } }
end

local FOOTER = "<CR> open in browser \u{00B7} R refresh"

---@param ctx manicule.PanelTabCtx
---@return manicule.PanelRow[]
local function build(ctx)
  local st = ctx.session and state_for(ctx.session) or {}
  local rows = {}
  if st.fetching then
    rows[#rows + 1] = dim_row("fetching checks\u{2026}")
  elseif st.error then
    rows[#rows + 1] = dim_row(st.error)
  elseif st.checks and #st.checks == 0 then
    rows[#rows + 1] = dim_row("no checks found")
  elseif st.checks then
    for _, state in ipairs(ORDER) do
      for _, check in ipairs(st.checks) do
        if check.state == state then
          rows[#rows + 1] = check_row(check)
        end
      end
    end
  end
  rows[#rows + 1] = dim_row(FOOTER)
  return rows
end

---Open the row's check page in the browser via vim.ui.open (0.12 has
---it); when it is unavailable or fails, surface the url in a notify so
---the user can open it themselves. No-op on url-less rows (footer,
---loading/error/empty states).
---@param row table|nil
local function open_url(row)
  local url = type(row) == "table" and row.url or nil
  if type(url) ~= "string" or url == "" then
    return
  end
  if type(vim.ui.open) == "function" then
    local ok, _, err = pcall(vim.ui.open, url)
    if ok and not err then
      return
    end
  end
  vim.notify("manicule: open " .. url, vim.log.levels.INFO)
end

---`R`: drop the fetch cache (keeping the upstream probe) and refetch;
---the immediate refresh shows the loading row until gh answers.
---@param _ table|nil
---@param ctx manicule.PanelTabCtx
local function refetch(_, ctx)
  if not ctx.session then
    return
  end
  local st = states[ctx.session]
  if st then
    st.fetching, st.done, st.checks, st.error = false, false, nil, nil
  end
  fetch(ctx)
  ctx.refresh()
end

---Register the checks tab. Zero work happens at require time; callers
---(the tabs loader, tests after panel._reset_tabs()) invoke this once
---per registry lifetime — a duplicate call errors like any duplicate
---tab registration.
function M.setup()
  require("manicule.review.panel").register_tab({
    name = "checks",
    title = title,
    available = available,
    build = build,
    on_show = fetch,
    keymaps = {
      ["<CR>"] = function(row)
        open_url(row)
      end,
      ["gl"] = function(row)
        open_url(row)
      end,
      ["R"] = refetch,
    },
  })
end

return M
