#!/usr/bin/env -S nvim -l

local uv = vim.uv or vim.loop
local cwd = uv.cwd()

local args = {}
local offline = vim.env.LAZY_OFFLINE == "1" or vim.env.LAZY_OFFLINE == "true"
local filter_pattern = vim.env.MANICULE_TEST_FILTER
for _, arg in ipairs(_G.arg or {}) do
  if arg == "--minitest" then
    -- Compatibility with the previous lazy.minit-based command.
  elseif arg == "--offline" then
    offline = true
  elseif arg:sub(1, 9) == "--filter=" then
    filter_pattern = arg:sub(10)
  else
    table.insert(args, arg)
  end
end

vim.env.LAZY_STDPATH = vim.env.LAZY_STDPATH or ".tests"

local root = vim.fn.fnamemodify(vim.env.LAZY_STDPATH, ":p"):gsub("[\\/]$", "")
for _, name in ipairs({ "config", "data", "state", "cache" }) do
  vim.env[("XDG_%s_HOME"):format(name:upper())] = root .. "/" .. name
end

local mini_test_path = vim.fn.stdpath("data") .. "/lazy/mini.test"
local mini_test_commit = "4b187876dc134c820677f9e67f0b28910be739ea"
if vim.fn.isdirectory(mini_test_path) ~= 1 then
  if offline then
    error("mini.test is not installed in " .. mini_test_path .. "; rerun without --offline once to install test deps")
  end
  vim.fn.mkdir(vim.fn.fnamemodify(mini_test_path, ":h"), "p")
  local output = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/echasnovski/mini.test.git",
    mini_test_path,
  })
  if vim.v.shell_error ~= 0 then
    error("failed to install mini.test:\n" .. output)
  end
end
if vim.fn.isdirectory(mini_test_path) == 1 then
  local head = vim.fn.systemlist({ "git", "-C", mini_test_path, "rev-parse", "HEAD" })[1]
  if head ~= mini_test_commit then
    if offline then
      error(("mini.test is at %s, expected %s; rerun without --offline once"):format(tostring(head), mini_test_commit))
    end
    local fetch = vim.fn.system({
      "git",
      "-C",
      mini_test_path,
      "fetch",
      "--depth=1",
      "origin",
      mini_test_commit,
    })
    if vim.v.shell_error ~= 0 then
      error("failed to fetch pinned mini.test commit:\n" .. fetch)
    end
    local checkout = vim.fn.system({ "git", "-C", mini_test_path, "checkout", "--detach", mini_test_commit })
    if vim.v.shell_error ~= 0 then
      error("failed to checkout pinned mini.test commit:\n" .. checkout)
    end
  end
  vim.opt.rtp:prepend(mini_test_path)
else
  error("mini.test was not installed in " .. mini_test_path)
end

vim.opt.rtp:prepend(cwd)
package.path = table.concat({
  cwd .. "/tests/?.lua",
  cwd .. "/?.lua",
  package.path,
}, ";")

-- Neovim 0.11 can hang in `vim.fs.normalize()` when called from a
-- mini.test scheduled case on this runner. The production plugin still
-- uses the native function; tests only need deterministic slash
-- normalization and `~` expansion.
local native_normalize = vim.fs.normalize
vim.fs.normalize = function(path, opts)
  if type(path) ~= "string" then
    return native_normalize(path, opts)
  end
  if path:sub(1, 1) == "~" then
    path = (vim.env.HOME or "") .. path:sub(2)
  end
  path = path:gsub("\\", "/"):gsub("/+", "/")
  if #path > 1 then
    path = path:gsub("/$", "")
  end
  return path
end

local function path_is_dir(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory"
end

local function dirname(path)
  if path == "/" then
    return "/"
  end
  path = path:gsub("/+$", "")
  if path == "" then
    return "/"
  end
  local parent = path:match("^(.*)/[^/]+$")
  if not parent or parent == "" then
    return path:sub(1, 1) == "/" and "/" or "."
  end
  return parent
end

local native_root = vim.fs.root
vim.fs.root = function(source, markers)
  if type(source) ~= "number" and type(source) ~= "string" then
    return native_root(source, markers)
  end

  local path = source
  if type(source) == "number" then
    if not vim.api.nvim_buf_is_valid(source) then
      return nil
    end
    path = vim.api.nvim_buf_get_name(source)
  end
  if type(path) ~= "string" or path == "" then
    return nil
  end

  if not path:match("^/") then
    path = cwd .. "/" .. path
  end
  path = vim.fs.normalize(path)

  local dir = path_is_dir(path) and path or dirname(path)
  if type(markers) == "string" then
    markers = { markers }
  end
  markers = markers or {}

  while dir and dir ~= "" do
    for _, marker in ipairs(markers) do
      if uv.fs_stat(dir .. "/" .. marker) then
        return dir
      end
    end
    local parent = dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

local native_system = vim.system
vim.system = function(cmd, opts, on_exit)
  if type(on_exit) == "function" then
    return native_system(cmd, opts, on_exit)
  end
  opts = opts or {}
  return {
    wait = function()
      local stdout = vim.fn.system(cmd, opts.stdin)
      return {
        code = vim.v.shell_error,
        signal = 0,
        stdout = opts.text == false and stdout or tostring(stdout or ""),
        stderr = "",
      }
    end,
  }
end

local function collect_files()
  if #args == 0 then
    return vim.fn.globpath("tests", "**/*_spec.lua", true, true)
  end

  local files = {}
  for _, arg in ipairs(args) do
    if vim.fn.isdirectory(arg) == 1 then
      vim.list_extend(files, vim.fn.globpath(arg, "**/*_spec.lua", true, true))
    else
      table.insert(files, arg)
    end
  end
  return files
end

local MiniTest = require("mini.test")
local reporter = MiniTest.gen_reporter.stdout({ group_depth = 1, quit_on_finish = false })
local reporter_finish = reporter.finish
reporter.finish = function(...)
  reporter_finish(...)
  local failed = false
  for _, case in ipairs(MiniTest.current.all_cases or {}) do
    if type(case.exec) == "table" and type(case.exec.fails) == "table" and #case.exec.fails > 0 then
      failed = true
      break
    end
  end
  os.exit(failed and 1 or 0)
end

MiniTest.setup({
  collect = {
    emulate_busted = true,
    find_files = collect_files,
    filter_cases = function(case)
      if not filter_pattern or filter_pattern == "" then
        return true
      end
      return table.concat(case.desc or {}, " "):find(filter_pattern) ~= nil
    end,
  },
  execute = {
    reporter = reporter,
  },
})

_G.assert = require("luassert")

MiniTest.run()
