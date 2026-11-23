-- Change notes: dyadic remembers, per agent, the text it last saw of each file it read or
-- changed through the bridge's tools, and tells the agent when such a file changed since:
-- at the start of a run, and in the result of an edit or write whose file ends up
-- different from what the agent's tool produced. The agent reads the file when it cares.
-- Off unless `change_notes = true`. See docs/adr/0004-change-notes.md.
local M = {}
local Files = require("dyadic.files")

-- Up to this many changed lines a note shows the diff; beyond, only where and how much.
M.MAX_DIFF_LINES = 20
-- Files larger than this, or with NUL bytes, are not remembered.
local MAX_BYTES = 1024 * 1024

function M.enabled(agent)
  return agent.config.change_notes == true
end

local function seen(agent)
  agent._seen = agent._seen or {}
  return agent._seen
end

-- A path as the agent knows it: relative to its working directory when inside it.
local function display(agent, path)
  local cwd = vim.fs.normalize(agent.cwd or "")
  if cwd ~= "" and path:sub(1, #cwd + 1) == cwd .. "/" then
    return path:sub(#cwd + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

-- A file's content as the read tool would return it: the buffer's text when it is loaded,
-- else the disk's; nil when the file does not exist.
function M.current(path)
  local buf = Files.buffer(path)
  if buf then
    return Files.text(buf)
  end
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

-- Remember that the agent saw `text` of `path`; nil forgets the file.
function M.saw(agent, path, text)
  if not M.enabled(agent) then
    return
  end
  if text and (#text > MAX_BYTES or text:find("%z")) then
    text = nil
  end
  seen(agent)[Files.real_file(path)] = text and { path = path, text = text } or nil
end

-- What the agent saw of the session's files belongs to the session branch; after a switch
-- or a move in the tree, it is unknown.
function M.forget(agent)
  agent._seen = nil
end

local function changed_lines(diff)
  local count = 0
  for line in diff:gmatch("[^\n]+") do
    local first = line:sub(1, 1)
    if (first == "+" or first == "-") and not line:match("^%+%+%+") and not line:match("^%-%-%-") then
      count = count + 1
    end
  end
  return count
end

-- How `path` changed from `before` to `after`, for the model: a small diff, or where and
-- how much changed.
local function describe(agent, path, before, after)
  local name = display(agent, path)
  if after == nil then
    return name .. ": deleted."
  end
  local diff = Files.diff(before, after, { result_type = "unified", ctxlen = 1 })
  ---@cast diff string
  local count = changed_lines(diff)
  if count <= M.MAX_DIFF_LINES then
    return name .. ":\n" .. diff:gsub("\n$", "")
  end
  local blocks = Files.diff(before, after, { result_type = "indices" })
  ---@cast blocks integer[][]
  local first, last = blocks[1][3], blocks[#blocks][3] + math.max(blocks[#blocks][4], 1) - 1
  return string.format(
    "%s: %d lines changed, around lines %d–%d; read it before relying on it.",
    name,
    count,
    math.max(first, 1),
    math.max(last, 1)
  )
end

-- The note for an edit or write call: what the agent believes the file now holds is
-- `believed`; when the file differs, say how and remember the current text. Nil when it
-- matches or notes are off.
function M.after_change(agent, path, believed)
  if not M.enabled(agent) then
    return nil
  end
  local now = M.current(path)
  M.saw(agent, path, now)
  if (now or "") == (believed or "") then
    return nil
  end
  return "The file now differs from your version; the current version stands.\n"
    .. describe(agent, path, believed or "", now)
end

-- The note for the start of a run: every remembered file that changed since the agent saw
-- it. Returns { text, files } or nil.
function M.collect(agent)
  if not M.enabled(agent) then
    return nil
  end
  local parts, files = {}, {}
  local keys = vim.tbl_keys(seen(agent))
  table.sort(keys)
  for _, key in ipairs(keys) do
    local entry = seen(agent)[key]
    local now = M.current(entry.path)
    if now ~= entry.text then
      parts[#parts + 1] = describe(agent, entry.path, entry.text, now)
      files[#files + 1] = display(agent, entry.path)
      M.saw(agent, entry.path, now)
    end
  end
  if #parts == 0 then
    return nil
  end
  return {
    text = "These files changed since you last saw them; the current version stands.\n\n"
      .. table.concat(parts, "\n\n"),
    files = files,
  }
end

function M.register(Bridge)
  -- { kind = "changes" } -> { text, files } or null, before each run the user starts.
  Bridge.handlers.changes = function(agent, _, reply)
    reply(M.collect(agent) or vim.NIL)
  end
end

return M
