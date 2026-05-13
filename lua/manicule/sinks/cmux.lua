-- manicule.nvim: cmux integration.
--
-- Sends the markdown review payload to a running coding-agent surface
-- in the current cmux workspace. Detection is intentionally generic:
-- Claude Code, Codex, Amp, and future agents can all match by state,
-- title, process command, or screen contents.

local helpers = require("manicule.sinks.helpers")

local M = {}

local DEFAULT_PATTERNS = { "Claude Code", "claude-code", "Claude", "OpenAI Codex", "Codex", "sourcegraph/amp", "Amp" }
local DEFAULT_CACHE_TTL_MS = 5000
local agent_surface_cache = {}

local function defaults()
  return {
    command = vim.env.CMUX_BUNDLED_CLI_PATH or "cmux",
    workspace_id = vim.env.CMUX_WORKSPACE_ID,
    current_surface = vim.env.CMUX_SURFACE_ID,
    patterns = DEFAULT_PATTERNS,
    auto_submit = true,
    clear_on_success = true,
    cache = true,
    cache_ttl_ms = DEFAULT_CACHE_TTL_MS,
    process_fallback = true,
    screen_fallback = true,
    read_screen_lines = 120,
    agent_state_dir = vim.env.TMPDIR or "/tmp",
    picker_prompt = "cmux: send review to",
  }
end

local function normalize_opts(opts)
  opts = vim.tbl_deep_extend("force", defaults(), opts or {})
  opts.enabled = nil
  return opts
end

local function cli(opts)
  return opts.command or vim.env.CMUX_BUNDLED_CLI_PATH or "cmux"
end

local function shorten(value, max)
  value = tostring(value or "")
  return #value <= max and value or (value:sub(1, max - 3) .. "...")
end

local function now_ms()
  return math.floor((vim.uv or vim.loop).hrtime() / 1000000)
end

local function patterns_key(patterns)
  local out = {}
  for _, pattern in ipairs(patterns or {}) do
    table.insert(out, tostring(pattern))
  end
  return table.concat(out, "\n")
end

local function cache_key(opts)
  return table.concat({
    cli(opts),
    opts.workspace_id or "",
    opts.current_surface or "",
    patterns_key(opts.patterns),
    tostring(opts.process_fallback ~= false),
    tostring(opts.screen_fallback ~= false),
    tostring(opts.read_screen_lines or ""),
    opts.agent_state_dir or "",
  }, "\t")
end

local function split_lines(text)
  local lines = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines
end

local function split_tabs(text)
  local fields = {}
  for field in (tostring(text or "") .. "\t"):gmatch("([^\t]*)\t") do
    table.insert(fields, field)
  end
  return fields
end

local function title_matches(title, patterns)
  if type(title) ~= "string" then
    return false
  end
  local lower = title:lower()
  for _, pattern in ipairs(patterns or DEFAULT_PATTERNS) do
    if lower:find(tostring(pattern):lower(), 1, true) then
      return true
    end
  end
  return false
end

local function detect_agent_from_command(command)
  local lower = tostring(command or ""):lower()
  if lower:find("codex", 1, true) then
    return "Codex"
  end
  if lower:find("claude", 1, true) then
    return "Claude"
  end
  if lower:find("sourcegraph/amp", 1, true) or lower:find("/amp", 1, true) then
    return "Amp"
  end
  return nil
end

local function detect_agent_from_screen(screen)
  if type(screen) ~= "string" or screen == "" then
    return nil
  end
  local lower = screen:lower()
  if lower:find("openai codex", 1, true) then
    return "Codex"
  end
  if lower:find("gpt-", 1, true) and lower:find("context", 1, true) and lower:find("tokens", 1, true) then
    return "Codex"
  end
  if lower:find("claude code", 1, true) or lower:find("claude-code", 1, true) then
    return "Claude"
  end
  if lower:find("sourcegraph/amp", 1, true) or lower:match("%f[%w]amp%f[%W]") then
    return "Amp"
  end
  return nil
end

local function agent_matches(agent, patterns)
  return title_matches(agent, patterns)
end

---@param surface string|table
---@return string?
function M.surface_ref(surface)
  if type(surface) == "string" then
    return surface
  end
  if type(surface) ~= "table" then
    return nil
  end
  return surface.ref or surface.id
end

local function surface_ref(surface)
  return M.surface_ref(surface)
end

---@param surface table|string
---@return string
function M.surface_label(surface)
  if type(surface) ~= "table" then
    return tostring(surface)
  end
  local title = surface.tab_title or surface.title or surface.name or "cmux surface"
  local ref = surface_ref(surface) or "?"
  local agent = surface.agent or surface.type
  local status = surface.status
  if type(surface.detail) == "string" and surface.detail ~= "" then
    status = type(status) == "string" and status ~= "" and (status .. " - " .. surface.detail) or surface.detail
  end
  local bits = { shorten(title, 54), "[" .. shorten(ref, 18) .. "]" }
  if type(agent) == "string" and agent ~= "" then
    table.insert(bits, agent)
  end
  if type(surface.tty) == "string" and surface.tty ~= "" then
    table.insert(bits, surface.tty)
  end
  if type(status) == "string" and status ~= "" then
    table.insert(bits, status)
  end
  return table.concat(bits, "  ")
end

local function clean_tmpdir(dir)
  return tostring(dir or "/tmp"):gsub("/+$", "")
end

local function read_first_line(path)
  local ok, lines = pcall(vim.fn.readfile, path, "", 1)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return lines[1]
end

local function state_surface_key(value)
  return (tostring(value or ""):gsub("[^%w%-]", ""))
end

local function read_agent_states(opts)
  local states = {}
  local labels = {}
  local files = vim.fn.glob(clean_tmpdir(opts.agent_state_dir) .. "/cmux-agent-state-*/*.state", false, true)
  for _, file in ipairs(files) do
    local line = read_first_line(file)
    if line and line ~= "" then
      local fields = split_tabs(line)
      local surface_key = fields[6]
      if surface_key and surface_key ~= "" then
        local state = {
          agent_key = fields[1],
          agent_title = fields[2],
          start_ts = tonumber(fields[3]),
          status = fields[4],
          detail = fields[5],
          surface_key = surface_key,
          tab_title = fields[7],
          status_color = fields[8],
          active = fields[9] == "1",
        }
        states[state_surface_key(surface_key)] = state
        table.insert(labels, (state.agent_title or state.agent_key or "agent") .. ":" .. surface_key)
      end
    end
  end
  return states, labels
end

local function state_for_surface(states, surface)
  return states[state_surface_key(surface.id)]
    or states[state_surface_key(surface.ref)]
    or states[state_surface_key(surface.surface_key)]
end

local function state_matches(state, patterns)
  if type(state) ~= "table" then
    return false
  end
  return title_matches(state.agent_title, patterns) or title_matches(state.agent_key, patterns)
end

local function parse_tree_surface(line)
  local ref = line:match("(surface:%d+)")
  if not ref then
    return nil
  end
  return {
    ref = ref,
    title = line:match('%[terminal%]%s+"(.-)"') or line:match('%[browser%]%s+"(.-)"') or "cmux surface",
    type = line:match("%[(terminal)%]") or line:match("%[(browser)%]") or "surface",
    tty = line:match("tty=([^%s]+)"),
    is_current = line:find(" here", 1, true) ~= nil,
  }
end

local function list_tree_surfaces(opts)
  if not opts.workspace_id or opts.workspace_id == "" then
    return nil, "CMUX_WORKSPACE_ID not set in env"
  end
  local result = helpers.system({ cli(opts), "tree", "--workspace", opts.workspace_id })
  if result.code ~= 0 then
    return nil, "cmux tree exited " .. tostring(result.code) .. ": " .. result.stderr:gsub("%s+$", "")
  end

  local surfaces = {}
  for _, line in ipairs(split_lines(result.stdout)) do
    local surface = parse_tree_surface(line)
    if surface then
      table.insert(surfaces, surface)
    end
  end
  if #surfaces == 0 then
    return nil, "cmux tree returned no surfaces"
  end
  return surfaces, nil
end

local function list_rpc_surfaces(opts)
  if not opts.workspace_id or opts.workspace_id == "" then
    return nil, "CMUX_WORKSPACE_ID not set in env"
  end
  local result = helpers.system({
    cli(opts),
    "rpc",
    "surface.list",
    vim.json.encode({ workspace_id = opts.workspace_id }),
  })
  if result.code ~= 0 then
    return nil, "cmux rpc exited " .. tostring(result.code) .. ": " .. result.stderr:gsub("%s+$", "")
  end
  local ok, decoded = pcall(vim.json.decode, result.stdout)
  if not ok or type(decoded) ~= "table" then
    return nil, "cmux rpc returned invalid JSON: " .. result.stdout:sub(1, 200)
  end
  if type(decoded.surfaces) ~= "table" then
    return nil, "cmux rpc response missing surfaces key"
  end
  return decoded.surfaces, nil
end

local function merge_tree_rpc_surfaces(tree_surfaces, rpc_surfaces)
  local rpc_by_ref = {}
  for _, surface in ipairs(rpc_surfaces or {}) do
    if type(surface) == "table" and surface.ref then
      rpc_by_ref[surface.ref] = surface
    end
  end

  local merged = {}
  for _, surface in ipairs(tree_surfaces) do
    local metadata = rpc_by_ref[surface.ref] or {}
    table.insert(merged, vim.tbl_extend("force", {}, metadata, surface))
  end
  return merged
end

---@return table[]? surfaces, string? err
function M.list_surfaces(opts)
  opts = normalize_opts(opts)
  local tree_surfaces, tree_err = list_tree_surfaces(opts)
  if tree_surfaces then
    local rpc_surfaces = list_rpc_surfaces(opts)
    if rpc_surfaces then
      return merge_tree_rpc_surfaces(tree_surfaces, rpc_surfaces), nil
    end
    return tree_surfaces, nil
  end

  local rpc_surfaces, rpc_err = list_rpc_surfaces(opts)
  if rpc_surfaces then
    return rpc_surfaces, nil
  end
  return nil, tree_err or rpc_err
end

local function tree_ttys_by_surface_ref(opts)
  local surfaces = list_tree_surfaces(opts)
  local ttys = {}
  if not surfaces then
    return ttys
  end
  for _, surface in ipairs(surfaces) do
    if surface.ref and surface.tty then
      ttys[surface.ref] = surface.tty
    end
  end
  return ttys
end

local function ps_commands_for_tty(tty, cache)
  if not tty or tty == "" then
    return {}
  end
  if cache[tty] then
    return cache[tty]
  end
  if vim.fn.executable("ps") ~= 1 then
    cache[tty] = {}
    return {}
  end

  local result = helpers.system({ "ps", "-t", tty, "-o", "command=" })
  if result.code ~= 0 then
    cache[tty] = {}
    return {}
  end

  local commands = {}
  for _, line in ipairs(split_lines(result.stdout)) do
    local command = line:gsub("^%s+", "")
    if command ~= "" then
      table.insert(commands, command)
    end
  end
  cache[tty] = commands
  return commands
end

local function read_surface_screens(opts, surfaces)
  local jobs = {}
  for _, surface in ipairs(surfaces) do
    local ref = surface_ref(surface)
    if ref then
      table.insert(jobs, {
        surface = surface,
        job = vim.system({
          cli(opts),
          "read-screen",
          "--surface",
          ref,
          "--scrollback",
          "--lines",
          tostring(opts.read_screen_lines or 120),
        }, { text = true }),
      })
    end
  end

  local screens = {}
  for _, item in ipairs(jobs) do
    local result = item.job:wait()
    if result.code == 0 then
      screens[item.surface] = result.stdout or ""
    end
  end
  return screens
end

local function is_current_surface(opts, surface)
  local current = opts.current_surface
  return surface.is_current == true or (current and current ~= "" and (surface.id == current or surface.ref == current))
end

local function copy_surface(surface)
  return vim.tbl_extend("force", {}, surface)
end

local function apply_agent_metadata(surface, metadata)
  local out = copy_surface(surface)
  out.agent = metadata.agent or out.agent
  out.agent_key = metadata.agent_key or out.agent_key
  out.status = metadata.status or out.status
  out.detail = metadata.detail or out.detail
  out.tab_title = metadata.tab_title or out.tab_title
  out.active = metadata.active
  out.agent_state = metadata.agent_state
  out.detected_by = metadata.detected_by
  out.tty = metadata.tty or out.tty
  return out
end

---Return agent-like surfaces in the current cmux workspace.
---@param opts? table
---@return table[]? surfaces, string? err
function M.list_agent_surfaces(opts)
  opts = normalize_opts(opts)
  local key = cache_key(opts)
  if opts.cache ~= false then
    local cached = agent_surface_cache[key]
    if cached and now_ms() - cached.at <= (opts.cache_ttl_ms or DEFAULT_CACHE_TTL_MS) then
      return cached.surfaces, cached.err
    end
  end

  local function finish(surfaces, err)
    if opts.cache ~= false then
      agent_surface_cache[key] = {
        at = now_ms(),
        surfaces = surfaces,
        err = err,
      }
    end
    return surfaces, err
  end

  local surfaces, err = M.list_surfaces(opts)
  if not surfaces then
    return finish(nil, err)
  end

  local states, state_labels = read_agent_states(opts)
  local ttys = nil
  local ps = {}
  local matches = {}
  local seen = {}
  local titles = {}
  local screen_candidates = {}

  local function add_match(surface, metadata)
    if not metadata then
      return
    end
    local ref = surface_ref(surface)
    local key_for_surface = ref or surface.id or tostring(surface.index or surface)
    if not metadata.tty and ref then
      metadata.tty = surface.tty
      if not metadata.tty then
        ttys = ttys or tree_ttys_by_surface_ref(opts)
        metadata.tty = ttys[ref]
      end
    end
    if not seen[key_for_surface] then
      seen[key_for_surface] = true
      table.insert(matches, apply_agent_metadata(surface, metadata))
    end
  end

  for _, surface in ipairs(surfaces) do
    if type(surface.title) == "string" then
      table.insert(titles, shorten(surface.title, 40))
    end
    if not is_current_surface(opts, surface) then
      local state = state_for_surface(states, surface)
      local agent = state and (state.agent_title or state.agent_key) or nil
      local metadata = nil

      if state and state_matches(state, opts.patterns) then
        metadata = {
          agent = agent,
          agent_key = state.agent_key,
          status = state.status,
          detail = state.detail,
          tab_title = state.tab_title,
          active = state.active,
          agent_state = state,
          detected_by = "state",
        }
      elseif title_matches(surface.title, opts.patterns) or title_matches(surface.name, opts.patterns) then
        metadata = {
          agent = surface.agent or surface.type,
          detected_by = "title",
        }
      elseif title_matches(surface.agent, opts.patterns) or title_matches(surface.agent_key, opts.patterns) then
        metadata = {
          agent = surface.agent or surface.agent_key,
          detected_by = "metadata",
        }
      elseif opts.process_fallback ~= false then
        local tty = surface.tty
        if not tty then
          ttys = ttys or tree_ttys_by_surface_ref(opts)
          tty = ttys[surface_ref(surface)]
        end
        for _, command in ipairs(ps_commands_for_tty(tty, ps)) do
          local command_agent = detect_agent_from_command(command)
          if agent_matches(command_agent, opts.patterns) then
            metadata = {
              agent = command_agent,
              detected_by = "tty",
              tty = tty,
            }
            break
          end
        end
      end

      if metadata then
        add_match(surface, metadata)
      else
        table.insert(screen_candidates, surface)
      end
    end
  end

  if #screen_candidates > 0 and opts.screen_fallback ~= false then
    local screens = read_surface_screens(opts, screen_candidates)
    for _, surface in ipairs(screen_candidates) do
      local screen_agent = detect_agent_from_screen(screens[surface])
      if agent_matches(screen_agent, opts.patterns) then
        add_match(surface, {
          agent = screen_agent,
          detected_by = "screen",
        })
      end
    end
  end

  if #matches == 0 then
    return finish(
      matches,
      "no cmux agent surfaces among "
        .. tostring(#surfaces)
        .. " surfaces (titles: "
        .. table.concat(titles, ", ")
        .. "; agent states: "
        .. (#state_labels > 0 and table.concat(state_labels, ", ") or "none")
        .. ")"
    )
  end
  return finish(matches, nil)
end

---Whether cmux integration can be used in the current environment.
---@param opts? table
---@return boolean
function M.is_available(opts)
  opts = normalize_opts(opts)
  return opts.workspace_id ~= nil and opts.workspace_id ~= "" and helpers.executable(cli(opts))
end

local function send_text(opts, surface, text)
  local ref = surface_ref(surface)
  if not ref or ref == "" then
    return false, "cmux target has no surface ref"
  end
  local result = helpers.system({ cli(opts), "send", "--surface", ref, "--", text })
  if result.code ~= 0 then
    return false, result.stderr:gsub("%s+$", "")
  end
  if opts.auto_submit ~= false then
    local key_result = helpers.system({ cli(opts), "send-key", "--surface", ref, "enter" })
    if key_result.code ~= 0 then
      return false, "text landed but submit failed; press Enter in the cmux pane manually"
    end
  end
  return true, nil
end

local function pick_surface(opts, cb)
  local surfaces, err = M.list_agent_surfaces(opts)
  if not surfaces or #surfaces == 0 then
    cb(nil, err or "no cmux agent surfaces found")
    return
  end
  if #surfaces == 1 then
    cb(surfaces[1])
    return
  end
  vim.ui.select(surfaces, {
    prompt = opts.picker_prompt,
    format_item = M.surface_label,
  }, function(surface)
    cb(surface, surface and nil or "cancelled")
  end)
end

local function ctx_surface(ctx)
  ctx = ctx or {}
  return ctx.surface or ctx.surface_ref or ctx.agent_id
end

---Build a cmux sink spec.
---@param opts? table
---@return table
function M.setup(opts)
  opts = normalize_opts(opts)
  return {
    name = "cmux",
    type = "integration",
    label = "cmux agent",
    description = "send review to a running cmux coding agent",
    clear_on_success = opts.clear_on_success ~= false,
    format = helpers.format_line,
    validate = function(ctx)
      if ctx_surface(ctx) then
        return true
      end
      if not helpers.executable(cli(opts)) then
        return false, "cmux executable not found: " .. tostring(cli(opts))
      end
      local surfaces, err = M.list_agent_surfaces(opts)
      if not surfaces or #surfaces == 0 then
        return false, err or "no cmux agent surfaces found"
      end
      return true
    end,
    health = function()
      return {
        command = cli(opts),
        available = M.is_available(opts),
        workspace_id = opts.workspace_id,
      }
    end,
    send = function(comments, ctx, cb)
      local target = ctx_surface(ctx)
      local text = helpers.format_markdown_review(comments)
      if target then
        local ok, err = send_text(opts, target, text)
        cb(ok, err)
        return
      end
      pick_surface(opts, function(surface, err)
        if not surface then
          cb(false, err or "cancelled")
          return
        end
        local ok, send_err = send_text(opts, surface, text)
        if ok then
          vim.notify("Review sent to " .. M.surface_label(surface), vim.log.levels.INFO)
        end
        cb(ok, send_err)
      end)
    end,
  }
end

function M._clear_cache()
  agent_surface_cache = {}
end

return M
