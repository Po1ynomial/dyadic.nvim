-- The bridge: dyadic's pi extension (pi/dyadic.ts), loaded into each agent with `-e`.
--
-- dyadic -> bridge: `/dyadic <name> {json}` prompts, which pi runs as an extension command
-- and answers once the handler returns.
-- bridge -> dyadic: `input` extension UI dialogs titled `dyadic.bridge` with a JSON request
-- in the placeholder. dyadic answers with JSON `{ ok, value }` or `{ ok = false, error }`.
-- A command reports its outcome as a `result` request carrying the command's token, which
-- arrives before the prompt response.
local M = {}

M.command_name = "dyadic"
M.title = "dyadic.bridge"

-- Request kind -> function(agent, request, reply); reply(value) or reply(nil, error).
M.handlers = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local next_token = 0

function M.path()
  return vim.fs.joinpath(root, "pi", "dyadic.ts")
end

-- pi arguments that load the bridge.
function M.args(config)
  return config.bridge and { "-e", M.path() } or {}
end

-- Whether pi reported the bridge's command, i.e. the extension loaded.
function M.available(agent)
  for _, item in ipairs(agent.commands or {}) do
    if type(item) == "table" and item.name == M.command_name and item.source == "extension" then
      return true
    end
  end
  return false
end

-- Warn once per agent when the bridge was requested but pi did not load it.
function M.check(agent)
  if agent.bridge_checked or not agent.config.bridge then
    return
  end
  agent.bridge_checked = true
  if not M.available(agent) then
    local log = agent.log_path and "; pi's stderr log: " .. agent.log_path or ""
    agent:notice(
      "The bridge did not load, so its features are unavailable" .. log .. ". See :help dyadic-bridge",
      "warning"
    )
  end
end

-- Run a bridge command. `callback(err, outcome)` runs once pi has finished the handler;
-- `outcome` is what the command reported, if anything. Returns false when the bridge is
-- missing, after telling the user that `feature` needs it.
function M.run(agent, name, args, feature, callback)
  if not M.available(agent) then
    agent:notice(feature .. " needs the bridge, which is not loaded. See :help dyadic-bridge", "error")
    return false
  end
  next_token = next_token + 1
  local token = tostring(next_token)
  args = vim.tbl_extend("force", args or {}, { token = token })
  local message = "/" .. M.command_name .. " " .. name .. " " .. vim.json.encode(args)
  agent:request("prompt", { message = message }, function(err)
    local results = agent._bridge_results or {}
    local outcome = results[token]
    results[token] = nil
    if callback then
      callback(err, outcome)
    end
  end)
  return true
end

function M.is_request(record)
  return record.method == "input" and record.title == M.title
end

local function respond(agent, id, payload)
  if not agent.rpc then
    return
  end
  local ok, sent, err = pcall(agent.rpc.send, agent.rpc, {
    type = "extension_ui_response",
    id = id,
    value = vim.json.encode(payload),
  })
  if (not ok or not sent) and not agent.closed then
    agent:notice("Bridge response failed: " .. tostring(ok and err or sent), "error")
  end
end

function M.handle(agent, record)
  local answered = false
  local function reply(value, err)
    if answered then
      return
    end
    answered = true
    if err ~= nil then
      respond(agent, record.id, { ok = false, error = tostring(err) })
    else
      respond(agent, record.id, { ok = true, value = value })
    end
  end
  local ok, request = pcall(vim.json.decode, record.placeholder or "")
  if not ok or type(request) ~= "table" then
    reply(nil, "malformed bridge request")
    return
  end
  local handler = M.handlers[request.kind]
  if not handler then
    reply(nil, "unknown bridge request: " .. tostring(request.kind))
    return
  end
  local called, err = pcall(handler, agent, request, reply)
  if not called then
    reply(nil, err)
  end
end

M.handlers.result = function(agent, request, reply)
  if type(request.token) == "string" then
    agent._bridge_results = agent._bridge_results or {}
    agent._bridge_results[request.token] = type(request.outcome) == "table" and request.outcome or {}
  end
  reply(true)
end

return M
