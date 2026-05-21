local H = {}
local uv = vim.uv or vim.loop
local function unique_name(prefix)
  return ("%s-%d-%d"):format(prefix, os.time(), math.random(1000000))
end

local function temp_dir(prefix)
  local parent = (vim.env.TMPDIR or "/tmp"):gsub("\\", "/"):gsub("/$", "")
  local dir = ("%s/%s-%s"):format(parent, unique_name(prefix or "manicule"), tostring(vim.fn.getpid()))
  vim.fn.mkdir(dir, "p")
  return dir
end

function H.project_dir(base, name)
  local dir = vim.fn.fnamemodify(base .. "/" .. unique_name(name or "project"), ":p"):gsub("\\", "/"):gsub("/$", "")
  vim.fn.mkdir(dir, "p")
  vim.fn.mkdir(dir .. "/.git", "p")
  return (uv.fs_realpath(dir) or dir):gsub("\\", "/")
end

function H.setup(opts)
  local artifact_root = temp_dir("manicule-test")
  local ctx = {
    artifact_root = artifact_root,
    state = artifact_root .. "/state",
    root = H.project_dir(artifact_root, "project"),
  }
  vim.fn.mkdir(ctx.state, "p")

  require("manicule.store")._reset()
  require("manicule.sinks")._reset()
  pcall(function()
    require("manicule.ui.render")._reset_for_tests()
  end)
  vim.g.loaded_manicule = nil

  local base = {
    store = {
      dir = ctx.state .. "/",
      format = "json",
      canonicalize_symlinks = false,
      poll_interval_ms = 0,
    },
    sinks = {
      clipboard = false,
      cmux = false,
    },
  }
  require("manicule").setup(vim.tbl_deep_extend("force", base, opts or {}))
  return ctx
end

function H.teardown(ctx)
  pcall(vim.cmd, "silent! only")
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(function()
    require("manicule")._stop_sync_timer_for_tests()
  end)
  require("manicule.store")._reset()
  require("manicule.sinks")._reset()
  pcall(function()
    require("manicule.ui.render")._reset_for_tests()
  end)
  vim.g.loaded_manicule = nil
  if ctx then
    pcall(vim.fn.delete, ctx.artifact_root, "rf")
  end
end

function H.write_project_file(ctx, relpath, lines)
  local path = ctx.root .. "/" .. relpath
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines or { "" }, path)
  return path
end

function H.edit_project_file(ctx, relpath, lines)
  local path = H.write_project_file(ctx, relpath, lines)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return path, vim.api.nvim_get_current_buf()
end

function H.capture_events(patterns)
  local events = {}
  local group = vim.api.nvim_create_augroup("manicule-test-events-" .. tostring(math.random(1000000)), { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = patterns,
    callback = function(ev)
      table.insert(events, {
        pattern = ev.match,
        data = vim.deepcopy(ev.data),
      })
    end,
  })
  return events, function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
end

function H.register_fake_sink(name, opts)
  opts = opts or {}
  local calls = {}
  require("manicule").register_sink({
    name = name,
    label = opts.label,
    description = opts.description,
    clear_on_success = opts.clear_on_success,
    validate = opts.validate,
    send = function(comments, ctx, cb)
      table.insert(calls, {
        comments = vim.deepcopy(comments),
        ctx = vim.deepcopy(ctx or {}),
      })
      cb(opts.ok ~= false, opts.err)
    end,
  })
  return calls
end

function H.fake_cmux(ctx, opts)
  opts = opts or {}
  local bin = ctx.state .. "/fake-cmux"
  local log = ctx.state .. "/fake-cmux.log"
  local surfaces = opts.surfaces
    or {
      { id = "surface-current", ref = "surface:1", title = "vim" },
      { id = "surface-agent", ref = "surface:2", title = "OpenAI Codex" },
    }
  local tree = opts.tree
    or {
      'surface:1 [terminal] "vim" tty=ttys001 here',
      'surface:2 [terminal] "OpenAI Codex" tty=ttys002',
    }
  local screens = opts.screens or {
    ["surface:2"] = "OpenAI Codex\nContext 0 tokens",
  }
  local lines = {
    "#!/usr/bin/env sh",
    "log=" .. vim.fn.shellescape(log),
    'case "$1" in',
    "  rpc)",
    "    printf %s " .. vim.fn.shellescape(vim.json.encode({ surfaces = surfaces })) .. ";",
    "    ;;",
    "  tree)",
    "    {",
  }
  for _, line in ipairs(tree) do
    table.insert(lines, "      printf '%s\\n' " .. vim.fn.shellescape(line) .. ";")
  end
  vim.list_extend(lines, {
    "    };",
    "    ;;",
    "  read-screen)",
    '    surface="";',
    '    while [ "$#" -gt 0 ]; do',
    '      if [ "$1" = "--surface" ]; then shift; surface="$1"; fi;',
    "      shift || break;",
    "    done;",
    '    case "$surface" in',
  })
  for surface, screen in pairs(screens) do
    table.insert(
      lines,
      "      " .. vim.fn.shellescape(surface) .. ") printf %s " .. vim.fn.shellescape(screen) .. " ;;"
    )
  end
  vim.list_extend(lines, {
    "      *) printf %s '' ;;",
    "    esac;",
    "    ;;",
    "  send)",
    '    surface="";',
    '    while [ "$#" -gt 0 ]; do',
    '      if [ "$1" = "--surface" ]; then shift; surface="$1"; shift; break; fi;',
    "      shift;",
    "    done;",
    '    if [ "$1" = "--" ]; then shift; fi;',
    '    printf \'send\t%s\t%s\n\' "$surface" "$*" >> "$log";',
    "    ;;",
    "  set-buffer)",
    '    name="default";',
    '    while [ "$#" -gt 0 ]; do',
    '      if [ "$1" = "--name" ]; then shift; name="$1"; shift; continue; fi;',
    '      if [ "$1" = "--" ]; then shift; break; fi;',
    "      shift;",
    "    done;",
    '    printf %s "$*" > "$log.buffer.$name";',
    '    printf \'set-buffer\t%s\t%s\n\' "$name" "$*" >> "$log";',
    "    ;;",
    "  paste-buffer)",
    '    name="default"; surface="";',
    '    while [ "$#" -gt 0 ]; do',
    '      if [ "$1" = "--name" ]; then shift; name="$1"; shift; continue; fi;',
    '      if [ "$1" = "--surface" ]; then shift; surface="$1"; shift; continue; fi;',
    "      shift;",
    "    done;",
    '    printf \'paste-buffer\t%s\t%s\t%s\n\' "$surface" "$name" "$(cat "$log.buffer.$name" 2>/dev/null)" >> "$log";',
    "    ;;",
    "  send-key)",
    '    printf \'key\t%s\t%s\n\' "$3" "$4" >> "$log";',
    "    ;;",
    "  *) exit 2 ;;",
    "esac",
  })
  vim.fn.writefile(lines, bin)
  vim.fn.setfperm(bin, "rwx------")
  return bin, log
end

return H
