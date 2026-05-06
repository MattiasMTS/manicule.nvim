-- manicule.nvim: shared sink helpers.
--
-- Integration authors can use these helpers to keep formatting and
-- command execution consistent with bundled sinks.

local M = {}

local function split_lines(text)
  text = tostring(text or "")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return lines
end

local function normalize_path(path)
  return tostring(path or ""):gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
end

local function relpath(root, path)
  root = normalize_path(root)
  path = normalize_path(path)
  if root == "" or path == "" then
    return nil
  end
  if path == root then
    return "."
  end
  local prefix = root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return nil
end

local function file_uri_to_path(uri)
  if type(uri) ~= "string" or uri:sub(1, 7) ~= "file://" then
    return nil
  end
  local path = uri:sub(8)
  if path:sub(1, 1) ~= "/" then
    local slash = path:find("/", 1, true)
    if not slash then
      return nil
    end
    path = path:sub(slash)
  end
  return (path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---Return an absolute or project-relative path for a comment.
---@param comment table
---@return string
function M.display_path(comment)
  local abs = file_uri_to_path(comment.uri)
  if abs and comment.project_root then
    local rel = relpath(comment.project_root, abs)
    if rel then
      return rel
    end
  end
  return abs or comment.uri or "?"
end

---Return a 1-indexed display range for a comment.
---@param comment table
---@return string
function M.display_range(comment)
  local range = comment.range or {}
  local start = range.start or { 0, 0 }
  local finish = range["end_"] or start
  local s = (start[1] or 0) + 1
  local e = (finish[1] or start[1] or 0) + 1
  return e ~= s and (s .. "-" .. e) or tostring(s)
end

---Return `path:range` for a comment.
---@param comment table
---@return string
function M.location(comment)
  return ("%s:%s"):format(M.display_path(comment), M.display_range(comment))
end

---Format comments as a markdown review payload suitable for agents.
---@param comments table[]
---@param opts? {title?: string}
---@return string
function M.format_markdown_review(comments, opts)
  opts = opts or {}
  local title = opts.title or "Manicule review"
  local parts = {
    ("%s (%d comment%s):"):format(title, #comments, #comments == 1 and "" or "s"),
    "",
  }
  for _, comment in ipairs(comments) do
    table.insert(parts, ("## %s"):format(M.location(comment)))
    for _, line in ipairs(split_lines(comment.body)) do
      table.insert(parts, line)
    end
    table.insert(parts, "")
  end
  return table.concat(parts, "\n")
end

---Format one comment as a compact single line.
---@param comment table
---@return string
function M.format_line(comment)
  return ("%s: %s"):format(M.location(comment), comment.body or "")
end

---Return true when an executable exists.
---@param command string
---@return boolean
function M.executable(command)
  return type(command) == "string" and command ~= "" and vim.fn.executable(command) == 1
end

---Run a command and return a normalized result table.
---@param argv string[]
---@param opts? table
---@return {code: integer, stdout: string, stderr: string}
function M.system(argv, opts)
  opts = vim.tbl_extend("force", { text = true }, opts or {})
  local result = vim.system(argv, opts):wait()
  return {
    code = result.code or 0,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

return M
