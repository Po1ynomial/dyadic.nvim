-- Bridge requests behind the editor-backed read, edit, and write tools (pi/dyadic.ts).
--   read    { path }                 -> the buffer's text when it has unsaved changes, else null
--   prepare { path, tool }           -> { mode = "disk" } or { mode = "buffer" | "review", text }
--   apply   { path, content, tool }  -> an outcome: { text?, note?, error?, diff? }
local M = {}
local Files = require("dyadic.files")
local Review = require("dyadic.review")

local function read(_, request, reply)
  local buf = Files.buffer(request.path)
  if buf and vim.bo[buf].modified then
    reply(Files.text(buf))
  else
    reply(vim.NIL)
  end
end

-- The plan for a path, kept per agent until the matching apply. Tool calls of one agent
-- run one at a time, so one plan per path is enough.
local function plans(agent)
  agent._file_plans = agent._file_plans or {}
  return agent._file_plans
end

local function prepare(agent, request, reply)
  local path = request.path
  local existing = Files.buffer(path)
  -- Editing a file that does not exist fails on the disk path, as in stock pi.
  local missing = not existing and vim.fn.filereadable(path) == 0
  if Review.enabled(agent, path) and not (missing and request.tool == "edit") then
    local buf = existing or Files.load(path)
    local text = Files.text(buf)
    plans(agent)[path] = { mode = "review", text = text, created = missing }
    reply({ mode = "review", text = text })
    return
  end
  local buf = Files.buffer(path)
  if buf then
    plans(agent)[path] = { mode = "buffer" }
    reply({ mode = "buffer", text = Files.text(buf) })
  else
    plans(agent)[path] = { mode = "disk" }
    reply({ mode = "disk" })
  end
end

local function write_disk(path, content)
  local lines, eol = Files.lines(content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  return pcall(vim.fn.writefile, lines, path, eol and "" or "b")
end

local function apply(agent, request, reply)
  local path = request.path
  local plan = plans(agent)[path] or {}
  plans(agent)[path] = nil
  if plan.mode == "review" then
    local buf = Files.buffer(path)
    if not buf then
      reply({ error = "The file's buffer closed before the review started." })
      return
    end
    Review.request(agent, buf, path, request.content, plan.text, reply, plan.created)
    return
  end
  local buf = Files.buffer(path)
  if not buf then
    -- The buffer went away since the plan; the disk gets the content instead.
    local ok, err = write_disk(path, request.content)
    reply(ok and {} or { error = "Could not write " .. path .. ": " .. tostring(err) })
    return
  end
  Files.apply(buf, request.content)
  local saved, err = Files.save(buf)
  if not saved then
    reply({ error = "The change is in the editor, but saving " .. path .. " failed: " .. err })
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
