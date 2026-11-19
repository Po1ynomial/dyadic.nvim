-- Scriptable stand-in for `pi --mode rpc`. Run as: nvim --clean -l tests/fakepi.lua [scenario.lua]
-- A scenario file returns a table with optional `state`, `entries`, `commands`, `prompts`, and `log`.
-- Tests can also drive the fake at runtime through two extra commands:
--   test_emit { events = {...} }        writes each record to stdout
--   test_set  { state, entries, queue } replaces fake state
local scenario = {}
if _G.arg[1] and _G.arg[1] ~= "" then
  scenario = dofile(_G.arg[1])
end

local function out(record)
  io.stdout:write(vim.json.encode(record) .. "\n")
  io.stdout:flush()
end
local function ok(req, data)
  out({ type = "response", id = req.id, command = req.type, success = true, data = data })
end
local function fail(req, err)
  out({ type = "response", id = req.id, command = req.type, success = false, error = err })
end

local state = vim.tbl_extend("force", {
  sessionId = "s1",
  sessionFile = "/tmp/dyadic-fake/s1.jsonl",
  isStreaming = false,
  isCompacting = false,
  model = { id = "fake-model", provider = "fake" },
  thinkingLevel = "off",
}, scenario.state or {})
local entries = vim.deepcopy(scenario.entries or {})
local queue = { steering = {}, followUp = {} }
local next_id = 1000

local function append(entry)
  next_id = next_id + 1
  entry.id = entry.id or ("e" .. next_id)
  entry.parentId = entry.parentId or (entries[#entries] and entries[#entries].id or vim.NIL)
  entries[#entries + 1] = entry
end

local log = scenario.log and io.open(scenario.log, "a")

for line in io.stdin:lines() do
  local req = vim.json.decode(line)
  if log then
    log:write(line, "\n")
    log:flush()
  end
  local t = req.type
  if t == "get_state" then
    local data = vim.deepcopy(state)
    data._env_nvim = os.getenv("NVIM") or vim.NIL
    ok(req, data)
  elseif t == "get_entries" then
    ok(req, { entries = entries, leafId = entries[#entries] and entries[#entries].id or vim.NIL })
  elseif t == "get_session_stats" then
    ok(req, { tokens = { total = 0 }, cost = 0 })
  elseif t == "get_commands" then
    ok(req, { commands = scenario.commands or {} })
  elseif t == "get_available_thinking_levels" then
    ok(req, { levels = { "off", "low", "high" } })
  elseif t == "clear_queue" then
    ok(req, queue)
    queue = { steering = {}, followUp = {} }
  elseif t == "prompt" then
    local script = (scenario.prompts or {})[req.message]
    ok(req, { disposition = "started" })
    if script then
      for _, event in ipairs(script.events or {}) do
        out(event)
      end
      for _, entry in ipairs(script.entries or {}) do
        append(vim.deepcopy(entry))
      end
    else
      local user = { role = "user", content = req.message, timestamp = next_id }
      local reply = {
        role = "assistant",
        content = { { type = "text", text = "echo: " .. req.message } },
        model = "fake-model",
        stopReason = "stop",
        timestamp = next_id + 1,
      }
      out({ type = "agent_start" })
      out({ type = "message_start", message = user })
      out({ type = "message_end", message = user })
      out({ type = "message_start", message = { role = "assistant", content = {}, timestamp = reply.timestamp } })
      out({ type = "message_end", message = reply })
      append({ type = "message", message = user })
      append({ type = "message", message = reply })
    end
    out({ type = "agent_settled", aborted = false })
  elseif t == "bash" then
    out({ type = "bash_execution_update", id = req.id, delta = "partial\n" })
    if req.command == "fail" then
      fail(req, "bash boom")
    else
      ok(req, { output = "partial\n", exitCode = 0, cancelled = false, truncated = false })
    end
  elseif t == "compact" then
    out({ type = "compaction_start", reason = "manual" })
    out({ type = "compaction_end", reason = "manual", aborted = false, willRetry = false, result = {} })
    ok(req, {})
  elseif t == "test_emit" then
    for _, event in ipairs(req.events or {}) do
      out(event)
    end
    ok(req, {})
  elseif t == "test_set" then
    if req.state then
      state = vim.tbl_extend("force", state, req.state)
    end
    if req.entries then
      entries = req.entries
    end
    if req.queue then
      queue = req.queue
    end
    ok(req, {})
  elseif t == "test_crash" then
    io.stderr:write("fake stack trace\n")
    io.stderr:flush()
    os.exit(3)
  elseif t == "extension_ui_response" then
    -- Dialog responses have no command response.
  else
    ok(req, {})
  end
end
