-- Bridge requests behind the editor-backed read, edit, and write tools (pi/dyadic.ts).
--   read    { path }                 -> the buffer's text when it has unsaved changes, else null
--   prepare { path, tool }           -> { mode = "disk" } or { mode = "buffer" | "review", text }
--   apply   { path, content, tool }  -> an outcome: { text?, note?, error?, diff? }
-- With change notes on, each request also records what the agent saw of the file.
local M = {}
local Files = require("dyadic.files")
local Review = require("dyadic.review")
local ChangeNotes = require("dyadic.change_notes")

local function read(agent, request, reply)
  ChangeNotes.saw(agent, request.path, ChangeNotes.current(request.path))
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
    ChangeNotes.saw(agent, path, text)
    reply({ mode = "review", text = text })
    return
  end
  local buf = Files.buffer(path)
  if buf then
    plans(agent)[path] = { mode = "buffer" }
    ChangeNotes.saw(agent, path, Files.text(buf))
    reply({ mode = "buffer", text = Files.text(buf) })
  else
    plans(agent)[path] = { mode = "disk" }
    ChangeNotes.saw(agent, path, ChangeNotes.current(path))
    reply({ mode = "disk" })
  end
end

-- Add a change note to an outcome, after whatever it already says.
local function with_note(outcome, note)
  if not note then
    return outcome
  end
  if outcome.error then
    outcome.error = outcome.error .. "\n\n" .. note
  elseif outcome.text then
    outcome.text = outcome.text .. "\n\n" .. note
  else
    outcome.note = outcome.note and (outcome.note .. " " .. note) or note
  end
  return outcome
end

local function write_disk(path, content)
  local lines, eol = Files.lines(content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  return pcall(vim.fn.writefile, lines, path, eol and "" or "b")
end

local function apply(agent, request, answer)
  local path = request.path
  -- `believed` is what the agent's tool takes the file to hold now; nil when the call
  -- failed before changing anything.
  local function reply(outcome, believed)
    if believed ~= nil then
      outcome = with_note(outcome, ChangeNotes.after_change(agent, path, believed))
    end
    answer(outcome)
  end
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
    if ok then
      reply({}, request.content)
    else
      reply({ error = "Could not write " .. path .. ": " .. tostring(err) })
    end
    return
  end
  Files.apply(buf, request.content)
  local saved, err = Files.save(buf)
  if not saved then
    reply({ error = "The change is in the editor, but saving " .. path .. " failed: " .. err }, request.content)
    return
  end
  -- Saving may have run formatters.
  reply({}, request.content)
end

function M.register(Bridge)
  Bridge.handlers.read = read
  Bridge.handlers.prepare = prepare
  Bridge.handlers.apply = apply
end

return M
