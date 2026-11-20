-- The bridge: dyadic's pi extension (pi/dyadic.ts), loaded into each agent with `-e`.
-- dyadic reaches it with `/dyadic <name> [json]` prompts, which pi runs as an extension
-- command and answers once the handler returns.
local M = {}

M.command_name = "dyadic"

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

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

-- Run a bridge command. `callback(err)` runs once pi has finished the handler; handler
-- failures arrive separately as extension_error notices. Returns false when the bridge
-- is missing, after telling the user what needed it.
function M.run(agent, name, args, feature, callback)
  if not M.available(agent) then
    agent:notice(feature .. " needs the bridge, which is not loaded. See :help dyadic-bridge", "error")
    return false
  end
  local message = "/" .. M.command_name .. " " .. name
  if args then
    message = message .. " " .. vim.json.encode(args)
  end
  agent:request("prompt", { message = message }, function(err)
    if callback then
      callback(err)
    end
  end)
  return true
end

return M
