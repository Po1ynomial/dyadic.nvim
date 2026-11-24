-- Scriptable stand-in for `pi --mode rpc`. Run as: nvim --clean -l tests/fakepi.lua [scenario.lua]
-- A scenario file returns a table with optional `state`, `entries`, `commands`, `models`, `prompts`, `log`,
-- `fail` (request type -> error message),
-- `leaf`, `bridge` (bridge command name -> { events = {...},
-- outcome = {...} }), and `no_bridge`.
-- Like pi, the fake reports the bridge's `dyadic` command when dyadic loads it with `-e`,
-- and its `tree` and `label` commands move the leaf and set labels.
-- Tests can also drive the fake at runtime through two extra commands:
--   test_emit { events = {...} }        writes each record to stdout
--   test_set  { state, entries, queue } replaces fake state
local scenario = {}
-- dyadic appends `--mode rpc`; the scenario path, when given, comes first.
if _G.arg[1] and _G.arg[1] ~= "" and _G.arg[1]:sub(1, 2) ~= "--" then
  scenario = dofile(_G.arg[1])
end

local function out(record, encode)
  io.stdout:write((encode or vim.json.encode)(record) .. "\n")
  io.stdout:flush()
end
local function ok(req, data, encode)
  out({ type = "response", id = req.id, command = req.type, success = true, data = data }, encode)
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
local leaf = scenario.leaf or (entries[#entries] and entries[#entries].id)
local queue = { steering = {}, followUp = {} }
local next_id = 1000

local function append(entry)
  next_id = next_id + 1
  entry.id = entry.id or ("e" .. next_id)
  entry.parentId = entry.parentId or leaf or vim.NIL
  entries[#entries + 1] = entry
  leaf = entry.id
end

local function find(id)
  for _, entry in ipairs(entries) do
    if entry.id == id then
      return entry
    end
  end
end

local function tree()
  local nodes, roots = {}, {}
  for _, entry in ipairs(entries) do
    nodes[entry.id] = { entry = entry, children = {} }
  end
  for _, entry in ipairs(entries) do
    local parent = entry.parentId ~= entry.id and nodes[entry.parentId] or nil
    table.insert(parent and parent.children or roots, nodes[entry.id])
    if entry.type == "label" and nodes[entry.targetId] then
      nodes[entry.targetId].label = entry.label
    end
  end
  return roots
end

-- A bridge request, as the extension's call() sends it; dyadic's answer is not awaited.
local bridge_requests = 0
local function bridge_request(payload)
  bridge_requests = bridge_requests + 1
  out({
    type = "extension_ui_request",
    id = "bridge" .. bridge_requests,
    method = "input",
    title = "dyadic.bridge",
    placeholder = vim.json.encode(payload),
  })
end

local log = scenario.log and io.open(scenario.log, "a")

local commands = vim.deepcopy(scenario.commands or {})
local bridge = false
for index, value in ipairs(_G.arg) do
  if value == "-e" and (_G.arg[index + 1] or ""):match("pi/dyadic%.ts$") and not scenario.no_bridge then
    bridge = true
    commands[#commands + 1] = { name = "dyadic", source = "extension", description = "bridge" }
  end
end

for line in io.stdin:lines() do
  local req = vim.json.decode(line)
  if log then
    log:write(line, "\n")
    log:flush()
  end
  local t = req.type
  if (scenario.fail or {})[t] then
    fail(req, scenario.fail[t])
  elseif t == "get_state" then
    local data = vim.deepcopy(state)
    data._env_nvim = os.getenv("NVIM") or vim.NIL
    ok(req, data)
  elseif t == "get_entries" then
    ok(req, { entries = entries, leafId = leaf or vim.NIL })
  elseif t == "get_tree" then
    -- Like pi, emit deep trees even when the client's vim.json.decode would reject them.
    ok(req, { tree = tree(), leafId = leaf or vim.NIL }, vim.fn.json_encode)
  elseif t == "get_session_stats" then
    ok(req, { tokens = { total = 0 }, cost = 0 })
  elseif t == "get_commands" then
    ok(req, { commands = commands })
  elseif t == "get_available_models" then
    ok(req, {
      models = scenario.models or {
        {
          provider = "fake",
          id = "fake-model",
          name = "Fake",
          contextWindow = 200000,
          maxTokens = 8192,
          reasoning = true,
          input = { "text", "image" },
        },
        {
          provider = "other",
          id = "small",
          name = "Small",
          contextWindow = 32000,
          maxTokens = 4096,
          reasoning = false,
          input = { "text" },
        },
      },
    })
  elseif t == "get_available_thinking_levels" then
    ok(req, { levels = { "off", "low", "high" } })
  elseif t == "clear_queue" then
    ok(req, queue)
    queue = { steering = {}, followUp = {} }
  elseif t == "prompt" and bridge and req.message:match("^/dyadic%s") then
    -- pi answers an extension command only after its handler returns.
    local name, json = req.message:match("^/dyadic%s+(%S+)%s*(.*)$")
    local args = json ~= "" and vim.json.decode(json) or {}
    local script = (scenario.bridge or {})[name] or {}
    for _, event in ipairs(script.events or {}) do
      out(event)
    end
    local outcome = script.outcome
    if name == "tree" and not outcome then
      -- Like pi: a user message's parent becomes the leaf; any other entry becomes it.
      local target = find(args.id)
      if target and target.type == "message" and target.message.role == "user" then
        leaf = target.parentId ~= vim.NIL and target.parentId or nil
      else
        leaf = args.id
      end
      outcome = { cancelled = false }
    elseif name == "label" and not outcome then
      append({
        type = "label",
        targetId = args.id,
        label = args.label ~= "" and args.label or nil,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
      })
      outcome = {}
    end
    if outcome and args.token then
      bridge_request({ kind = "result", token = args.token, outcome = outcome })
    end
    ok(req, { disposition = "handled" })
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
      leaf = req.leaf or (entries[#entries] and entries[#entries].id)
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
