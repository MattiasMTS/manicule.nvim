local H = {}

local function unique_name(prefix)
  return ("%s-%d-%d"):format(prefix, os.time(), math.random(1000000))
end

function H.project_dir(name)
  local dir =
    vim.fs.normalize(vim.fn.fnamemodify(vim.uv.cwd() .. "/" .. unique_name(name or ".manicule-test-root"), ":p"))
  vim.fn.mkdir(dir, "p")
  vim.fn.mkdir(dir .. "/.git", "p")
  return dir
end

function H.setup(opts)
  local ctx = {
    state = vim.fn.tempname(),
    root = H.project_dir(".manicule-test-root"),
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
  require("manicule.store")._reset()
  require("manicule.sinks")._reset()
  pcall(function()
    require("manicule.ui.render")._reset_for_tests()
  end)
  vim.g.loaded_manicule = nil
  if ctx then
    pcall(vim.fn.delete, ctx.state, "rf")
    pcall(vim.fn.delete, ctx.root, "rf")
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
