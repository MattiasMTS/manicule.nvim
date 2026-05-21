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

local function text_block(value)
  if type(value) ~= "string" then
    return nil
  end
  local text = vim.trim(value)
  return text ~= "" and text or nil
end

local function append_block(parts, text)
  text = text_block(text)
  if not text then
    return
  end
  for _, line in ipairs(split_lines(text)) do
    table.insert(parts, line)
  end
  table.insert(parts, "")
end

local function join_blocks(parts)
  while #parts > 0 and parts[#parts] == "" do
    table.remove(parts)
  end
  return table.concat(parts, "\n")
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

local function uri_to_path(uri)
  local ok, uri_mod = pcall(require, "manicule.uri")
  if not ok then
    return nil
  end
  return uri_mod.to_path(uri)
end

local function inferred_root(comment)
  if comment.project_root then
    return comment.project_root
  end
  local ok, uri_mod = pcall(require, "manicule.uri")
  if not ok then
    return nil
  end
  local parts = uri_mod.codediff_parts(comment.uri)
  return parts and parts.git_root or nil
end

---Return an absolute or project-relative path for a comment.
---@param comment table
---@return string
function M.display_path(comment)
  local abs = uri_to_path(comment.uri)
  local root = inferred_root(comment)
  if abs and root then
    local rel = relpath(root, abs)
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
---@param opts? {title?: string, pre_text?: string, post_text?: string}
---@return string
function M.format_markdown_review(comments, opts)
  opts = opts or {}
  local title = opts.title or "Manicule review"
  local parts = {
    ("%s (%d comment%s):"):format(title, #comments, #comments == 1 and "" or "s"),
    "",
  }
  append_block(parts, opts.pre_text)
  for index, comment in ipairs(comments) do
    table.insert(parts, ("## M%d %s"):format(index, M.location(comment)))
    for _, line in ipairs(split_lines(comment.body)) do
      table.insert(parts, line)
    end
    table.insert(parts, "")
  end
  append_block(parts, opts.post_text)
  return join_blocks(parts)
end

---Wrap an already formatted text payload with optional sink pre/post text.
---@param text string
---@param opts? {pre_text?: string, post_text?: string}
---@return string
function M.wrap_text(text, opts)
  opts = opts or {}
  local parts = {}
  append_block(parts, opts.pre_text)
  append_block(parts, text)
  append_block(parts, opts.post_text)
  return join_blocks(parts)
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
