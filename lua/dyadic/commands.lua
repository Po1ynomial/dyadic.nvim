local M = {}
local Bridge = require("dyadic.bridge")
local Sessions = require("dyadic.sessions")
local resolve = Sessions.resolve

-- The commands dyadic handles itself, in the order of :h dyadic-pi-commands, which uses
-- the same hints and descriptions.
M.builtins = {
  { name = "model", hint = "[provider/model or search]", description = "Select a model" },
  { name = "thinking", hint = "[level]", description = "Select a supported thinking level" },
  { name = "new", description = "Start a fresh session in this agent" },
  { name = "resume", description = "Switch to a saved session with the session picker" },
  { name = "name", hint = "[name]", description = "Set or show the session name" },
  { name = "session", description = "Show identity, file, usage, context" },
  { name = "compact", hint = "[instructions]", description = "Compact through pi" },
  { name = "tree", description = "Move within the session tree with the tree picker" },
  {
    name = "fork",
    hint = "[entry-id]",
    description = "Fork from a user message and restore its text to the draft",
  },
  { name = "clone", description = "Clone the active branch" },
  { name = "export", hint = "[HTML path]", description = "Export HTML through pi" },
  { name = "copy", description = "Copy the last assistant response" },
  {
    name = "settings",
    hint = "[name] [value]",
    description = "Auto-compaction, auto-retry, steering mode, or follow-up mode",
  },
  { name = "reload", description = "Reload pi's extensions, skills, prompts, and context files" },
  { name = "quit", description = "Close this agent" },
}
M.names = vim.tbl_map(function(command)
  return command.name
end, M.builtins)

local unsupported = {
  login = true,
  logout = true,
  ["scoped-models"] = true,
  share = true,
  bug = true,
  trust = true,
  llama = true,
  import = true,
  changelog = true,
  debug = true,
  privacy = true,
  arminsayshi = true,
  dementedelves = true,
}

local function alive(agent)
  return not agent.closed
end

-- Whether pi lists `name` among its extension, prompt, and skill commands.
function M.listed(agent, name)
  for _, command in ipairs(agent.commands or {}) do
    local listed = type(command) == "table" and command.name or command
    if listed == name or listed == "/" .. name then
      return true
    end
  end
  return false
end

-- A built-in command clears its draft as soon as it runs, as in pi. When it then fails
-- and the composer is still empty, its text comes back for another try.
local function consume(agent, original)
  if alive(agent) and agent:get_draft() == original then
    agent:set_draft("")
  end
end

local function restore(agent, original)
  if original and alive(agent) and agent:get_draft() == "" then
    agent:set_draft(original)
  end
end

local function request(agent, kind, fields, original, callback)
  return agent:request(kind, fields or {}, function(err, data)
    if not alive(agent) then
      return
    end
    if err then
      restore(agent, original)
      return
    end
    data = type(data) == "table" and data or {}
    if data.cancelled then
      agent:notice(kind .. " cancelled", "info")
      return
    end
    if callback then
      callback(data)
    end
  end)
end

local function change(agent, kind, fields, original)
  request(agent, kind, fields, original, function()
    agent:refresh()
  end)
end

local function pick(agent, items, prompt, format, callback, original)
  if #items == 0 then
    agent:notice("No " .. prompt:lower() .. " available", "warning")
    restore(agent, original)
    return
  end
  vim.ui.select(items, { prompt = prompt, format_item = format }, function(item)
    if item ~= nil and alive(agent) then
      callback(item)
    end
  end)
end

local function switched(agent, kind, fields, original)
  request(agent, kind, fields, original, function(data)
    agent.partial, agent.tools, agent.bash = nil, {}, nil
    agent.queue = { steering = {}, followUp = {} }
    if kind == "fork" and type(data.text) == "string" and data.text ~= "" then
      local draft = agent:get_draft()
      agent:set_draft(draft == "" and data.text or draft .. "\n\n" .. data.text)
    end
    agent:refresh()
  end)
end

local function model(agent, argument, original)
  agent:request("get_available_models", {}, function(err, data)
    if err then
      restore(agent, original)
    end
    if err or not alive(agent) then
      return
    end
    local models = data and data.models or {}
    local function apply(item)
      change(agent, "set_model", { provider = item.provider, modelId = item.id }, original)
    end
    if argument ~= "" then
      local exact, matching = {}, {}
      for _, item in ipairs(models) do
        local key = item.provider .. "/" .. item.id
        if key == argument or item.id == argument then
          exact[#exact + 1] = item
        elseif
          key:lower():find(argument:lower(), 1, true)
          or (item.name or ""):lower():find(argument:lower(), 1, true)
        then
          matching[#matching + 1] = item
        end
      end
      models = #exact > 0 and exact or matching
      if #models == 1 then
        apply(models[1])
        return
      end
    end
    pick(agent, models, "Models", function(item)
      return item.provider .. "/" .. item.id .. (item.name and "  " .. item.name or "")
    end, apply, original)
  end)
end

local function thinking(agent, argument, original)
  agent:request("get_available_thinking_levels", {}, function(err, data)
    if err then
      restore(agent, original)
    end
    if err or not alive(agent) then
      return
    end
    local levels = data and data.levels or {}
    agent.available_thinking_levels = levels
    local function apply(level)
      change(agent, "set_thinking_level", { level = level }, original)
    end
    if argument ~= "" then
      if vim.tbl_contains(levels, argument) then
        apply(argument)
      else
        agent:notice("Thinking level unavailable. Choose " .. table.concat(levels, ", "), "error")
        restore(agent, original)
      end
      return
    end
    pick(agent, levels, "Thinking levels", nil, apply, original)
  end)
end

local settings_controls = {
  ["auto-compaction"] = { rpc = "set_auto_compaction", field = "enabled", values = { "on", "off" } },
  ["auto-retry"] = { rpc = "set_auto_retry", field = "enabled", values = { "on", "off" } },
  steering = { rpc = "set_steering_mode", field = "mode", values = { "all", "one-at-a-time" } },
  ["follow-up"] = { rpc = "set_follow_up_mode", field = "mode", values = { "all", "one-at-a-time" } },
}
local settings_names = { "auto-compaction", "auto-retry", "steering", "follow-up" }
local settings_descriptions = {
  ["auto-compaction"] = "Compact the context automatically when it nears the model's limit",
  ["auto-retry"] = "Retry automatically after transient provider errors",
  steering = "Deliver queued steering messages all at once or one at a time",
  ["follow-up"] = "Deliver queued follow-up messages all at once or one at a time",
}

-- The current value of a setting, when pi's state reports it.
local function setting_value(agent, key)
  local state = agent.state or {}
  local current = ({
    ["auto-compaction"] = state.autoCompactionEnabled,
    steering = state.steeringMode,
    ["follow-up"] = state.followUpMode,
  })[key]
  if type(current) == "boolean" then
    current = current and "on" or "off"
  end
  return current
end

M.settings = {
  names = settings_names,
  descriptions = settings_descriptions,
  values = function(key)
    return settings_controls[key] and settings_controls[key].values
  end,
  current = setting_value,
}

local function configure(agent, argument, original)
  local name, value = argument:match("^(%S+)%s*(.-)$")
  local function choose(key, chosen)
    local control = settings_controls[key]
    if not control then
      agent:notice("RPC settings: " .. table.concat(settings_names, ", "), "error")
      restore(agent, original)
      return
    end
    local function apply(selected)
      if not vim.tbl_contains(control.values, selected) then
        agent:notice("Use " .. table.concat(control.values, " or ") .. " for " .. key, "error")
        restore(agent, original)
        return
      end
      local fields = {}
      if control.field == "enabled" then
        fields.enabled = selected == "on"
      else
        fields.mode = selected
      end
      change(agent, control.rpc, fields, original)
    end
    if chosen and chosen ~= "" then
      apply(chosen)
    else
      pick(agent, control.values, key, nil, apply)
    end
  end
  if name then
    choose(name, value)
  else
    pick(agent, settings_names, "RPC settings", function(key)
      local current = setting_value(agent, key)
      return key .. (current ~= nil and "  " .. tostring(current) or "")
    end, choose)
  end
end

local function session(agent, original)
  request(agent, "get_session_stats", {}, original, function(data)
    agent.stats = data
    local state = agent.state or {}
    local tokens = data.tokens or {}
    local lines = {
      "Session: " .. (state.sessionName or data.sessionId or state.sessionId or "unnamed"),
      "File: " .. (data.sessionFile or state.sessionFile or "ephemeral"),
      string.format(
        "Messages: %s users, %s assistants, %s tool calls",
        data.userMessages or 0,
        data.assistantMessages or 0,
        data.toolCalls or 0
      ),
      string.format(
        "Tokens: %s input, %s output, %s cache read, %s cache write, %s total",
        tokens.input or 0,
        tokens.output or 0,
        tokens.cacheRead or 0,
        tokens.cacheWrite or 0,
        tokens.total or 0
      ),
      string.format("Cost: $%.6f", data.cost or 0),
    }
    local context = data.contextUsage
    if context and context ~= vim.NIL then
      local used = context.tokens ~= vim.NIL and context.tokens or "unknown"
      local percent = type(context.percent) == "number" and string.format("%.1f%%", context.percent) or "unknown"
      lines[#lines + 1] =
        string.format("Context: %s / %s tokens (%s)", used or "unknown", context.contextWindow or "?", percent)
    end
    agent:notice(table.concat(lines, "\n"), "info")
  end)
end

local function bash(agent, text)
  local input = vim.trim(text)
  local excluded = input:sub(1, 2) == "!!"
  local command = vim.trim(input:sub(excluded and 3 or 2))
  if command == "" then
    agent:notice("Use !command or !!command", "error")
    return
  end
  if agent.bash and agent.bash.running then
    agent:notice("A shell command is already running. Abort it first.", "warning")
    return
  end
  local execution = { command = command, output = "", running = true, excludeFromContext = excluded }
  agent.bash = execution
  execution.id = agent:request("bash", { command = command, excludeFromContext = excluded }, function(err, data)
    if not alive(agent) then
      return
    end
    execution.running = false
    if err then
      execution.error = err
      agent:render()
      return
    end
    data = data or {}
    if not data.truncated or execution.output == "" then
      execution.output = data.output or execution.output
    end
    execution.exitCode, execution.cancelled = data.exitCode, data.cancelled
    execution.truncated, execution.fullOutputPath = data.truncated, data.fullOutputPath
    if not data.cancelled then
      consume(agent, text)
    end
    agent:refresh()
  end)
  if not execution.id then
    execution.running = false
  end
  agent:render()
end

function M.run(agent, text)
  local input = vim.trim(text)
  if input:sub(1, 1) == "!" then
    bash(agent, text)
    return true
  end
  local name, argument = input:match("^/([^%s]+)%s*(.*)$")
  if not name then
    return false
  end
  argument = vim.trim(argument)
  -- Pi may provide a command that was TUI-only before, such as /llama, as an extension.
  if unsupported[name] and M.listed(agent, name) then
    return false
  end
  if name == "hotkeys" then
    -- Mappings are buffer-local with descriptions, so Neovim already lists the active set.
    agent:notice("/hotkeys is not available. Use :nmap <buffer> or :help dyadic-mappings", "warning")
  elseif unsupported[name] then
    agent:notice("/" .. name .. " is not available through stock pi RPC. Use pi in a terminal.", "error")
  elseif name == "model" then
    consume(agent, text)
    model(agent, argument, text)
  elseif name == "thinking" then
    consume(agent, text)
    thinking(agent, argument, text)
  elseif name == "settings" then
    consume(agent, text)
    configure(agent, argument, text)
  elseif name == "new" or name == "clone" then
    if argument ~= "" then
      agent:notice("Usage: /" .. name, "error")
    else
      consume(agent, text)
      switched(agent, name == "new" and "new_session" or "clone", {}, text)
    end
  elseif name == "resume" then
    if argument ~= "" then
      agent:notice("Usage: /resume. To open a session file, use :Dyadic --session {path}", "error")
    else
      consume(agent, text)
      local current = agent.state.sessionFile
      require("dyadic.session_picker").open({
        where = { cwd = agent.cwd, args = agent.args, session_file = current },
        config = agent.config,
        on_choose = function(path)
          if alive(agent) and resolve(path, agent.cwd) ~= resolve(current or "", agent.cwd) then
            switched(agent, "switch_session", { sessionPath = path }, text)
          end
        end,
      })
    end
  elseif name == "fork" then
    consume(agent, text)
    agent:request("get_fork_messages", {}, function(err, data)
      if err then
        restore(agent, text)
      end
      if err or not alive(agent) then
        return
      end
      local messages = data and data.messages or {}
      if argument ~= "" then
        for _, item in ipairs(messages) do
          if item.entryId == argument then
            switched(agent, "fork", { entryId = item.entryId }, text)
            return
          end
        end
        agent:notice("No forkable user message with entry ID " .. argument, "error")
        restore(agent, text)
        return
      end
      pick(agent, messages, "Fork messages", function(item)
        return item.entryId .. "  " .. (item.text or ""):gsub("%s+", " "):sub(1, 150)
      end, function(item)
        switched(agent, "fork", { entryId = item.entryId }, text)
      end, text)
    end)
  elseif name == "name" then
    consume(agent, text)
    if argument == "" then
      request(agent, "get_state", {}, text, function(data)
        agent:notice("Session name: " .. (data.sessionName or "unnamed"), "info")
      end)
    else
      change(agent, "set_session_name", { name = argument }, text)
    end
  elseif name == "session" then
    consume(agent, text)
    session(agent, text)
  elseif name == "compact" then
    consume(agent, text)
    change(agent, "compact", argument ~= "" and { customInstructions = argument } or {}, text)
  elseif name == "copy" then
    consume(agent, text)
    request(agent, "get_last_assistant_text", {}, text, function(data)
      if type(data.text) ~= "string" then
        agent:notice("No assistant text to copy", "warning")
        restore(agent, text)
        return
      end
      vim.fn.setreg('"', data.text, "v")
      local ok, err = pcall(vim.fn.setreg, "+", data.text, "v")
      agent:notice(
        ok and "Copied last assistant response to clipboard and unnamed register"
          or "Copied to unnamed register; clipboard unavailable: " .. tostring(err),
        ok and "info" or "warning"
      )
    end)
  elseif name == "export" then
    if argument:lower():match("%.jsonl$") or argument:lower() == "jsonl" then
      agent:notice(
        "JSONL export is not exposed by stock pi RPC. Use /export in pi; HTML export is available here.",
        "error"
      )
    else
      consume(agent, text)
      request(
        agent,
        "export_html",
        argument ~= "" and { outputPath = resolve(argument, agent.cwd) } or {},
        text,
        function(data)
          agent:notice("Exported HTML: " .. tostring(data.path), "info")
        end
      )
    end
  elseif name == "tree" then
    if argument ~= "" then
      agent:notice("Usage: /tree", "error")
    else
      -- From the history, the picker starts at the entry under the cursor.
      local initial = require("dyadic.view").entry_at_cursor(agent)
      consume(agent, text)
      if not require("dyadic.tree_picker").open(agent, { initial = initial }) then
        restore(agent, text)
      end
    end
  elseif name == "reload" then
    if agent.active then
      agent:notice("Wait for the agent to finish before /reload", "warning")
    else
      consume(agent, text)
      local started = Bridge.run(agent, "reload", nil, "/reload", function(err)
        if not alive(agent) then
          return
        elseif err then
          restore(agent, text)
        else
          agent:notice("Reloaded extensions, skills, prompts, and context files")
          agent:refresh()
        end
      end)
      if not started then
        restore(agent, text)
      end
    end
  elseif name == "quit" then
    agent:close()
  else
    return false
  end
  return true
end

return M
