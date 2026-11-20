-- Bridge requests behind the editor-backed read, edit, and write tools (pi/dyadic.ts).
--   read    { path }                 -> the buffer's text when it has unsaved changes, else null
--   prepare { path, tool }           -> { mode = "disk" } or { mode = "buffer" | "review", text }
--   apply   { path, content, tool }  -> an outcome: { text?, note?, error?, diff? }
local M = {}
local Files = require("dyadic.files")

-- Whether changes to `path` are reviewed. Reviews come in a later step; none for now.
function M.reviewed(_agent, _path)
  return false
end

local function read(_, request, reply)
  local buf = Files.buffer(request.path)
  if buf and vim.bo[buf].modified then
    reply(Files.text(buf))
  else
    reply(vim.NIL)
  end
end

local function prepare(_, request, reply)
  local buf = Files.buffer(request.path)
  if buf then
    reply({ mode = "buffer", text = Files.text(buf) })
  else
    reply({ mode = "disk" })
  end
end

local function apply(_, request, reply)
  local buf = Files.buffer(request.path)
  if not buf then
    -- The buffer went away since the plan; the disk gets the content instead.
    local lines, eol = Files.lines(request.content)
    vim.fn.mkdir(vim.fs.dirname(request.path), "p")
    local ok, err = pcall(vim.fn.writefile, lines, request.path, eol and "" or "b")
    reply(ok and {} or { error = "Could not write " .. request.path .. ": " .. tostring(err) })
    return
  end
  Files.apply(buf, request.content)
  local saved, err = Files.save(buf)
  if not saved then
    reply({ error = "The change is in the editor, but saving " .. request.path .. " failed: " .. err })
    return
  end
  reply({})
end

function M.register(Bridge)
  Bridge.handlers.read = read
  Bridge.handlers.prepare = prepare
  Bridge.handlers.apply = apply
end

return M
