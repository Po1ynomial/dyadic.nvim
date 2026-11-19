local M = {}
local uv = vim.uv
local windows = vim.fn.has("win32") == 1

M.names = {
  "model",
  "thinking",
  "new",
  "resume",
  "name",
  "session",
  "stats",
  "compact",
  "fork",
  "clone",
  "export",
  "copy",
  "settings",
  "quit",
}

local unsupported = {
  tree = true,
  login = true,
  logout = true,
  reload = true,
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

local function alive(s)
  return not s.closed
end

local function consume(s, original)
  if alive(s) and s:get_draft() == original then
    s:set_draft("")
  end
end

local function request(s, kind, fields, original, callback)
  return s:request(kind, fields or {}, function(err, data)
    if err or not alive(s) then
      return
    end
    data = type(data) == "table" and data or {}
    if data.cancelled then
      s:notice(kind .. " cancelled", "info")
      return
    end
    consume(s, original)
    if callback then
      callback(data)
    end
  end)
end

local function change(s, kind, fields, original)
  request(s, kind, fields, original, function()
    s:refresh()
  end)
end

local function pick(s, items, prompt, format, callback)
  if #items == 0 then
    s:notice("No " .. prompt:lower() .. " available", "warning")
    return
  end
  vim.ui.select(items, { prompt = prompt, format_item = format }, function(item)
    if item ~= nil and alive(s) then
      callback(item)
    end
  end)
end

local function resolve(path, cwd)
  if windows and not path:find("\\", 1, true) and path:sub(1, 2) ~= "//" then
    local drive, tail = path:match("^/([a-z])/(.*)$")
    if not drive then
      drive, tail = path:match("^/mnt/([a-z])/(.*)$")
    end
    if not drive then
      drive, tail = path:match("^/cygdrive/([a-z])/(.*)$")
    end
    if not drive then
      drive = path:match("^/([a-z])$") or path:match("^/mnt/([a-z])$") or path:match("^/cygdrive/([a-z])$")
    end
    if drive then
      path = drive:upper() .. ":/" .. (tail or "")
    end
  end
  if path == "~" then
    path = uv.os_homedir()
  elseif path:sub(1, 2) == "~/" or windows and path:sub(1, 2) == "~\\" then
    path = vim.fs.joinpath(uv.os_homedir(), path:sub(3))
  end
  if path:match("^file://") then
    path = vim.uri_to_fname(path)
  end
  local absolute = path:sub(1, 1) == "/" or windows and (path:sub(1, 1) == "\\" or path:match("^%a:[/\\]"))
  if not absolute then
    path = vim.fs.joinpath(cwd, path)
  end
  return vim.fs.normalize(path)
end

local function decode(text)
  local ok, value = pcall(vim.json.decode, text)
  if ok and type(value) == "table" then
    return value
  end
end

local function settings(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return {}
  end
  local stat = uv.fs_fstat(fd)
  local text = stat and stat.size <= 1024 * 1024 and uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not text then
    return {}
  end
  return decode(text:gsub("^\239\187\191", "")) or {}
end

-- Pi resolves all sessionDir values from its process cwd, not the settings file.
-- Its default grouping removes one leading separator and replaces /, \\, and :.
local function storage(s)
  local agent_env = vim.env.PI_CODING_AGENT_DIR
  local agent = resolve(agent_env and agent_env ~= "" and agent_env or "~/.pi/agent", s.cwd)
  local args = s.config.args or {}
  local explicit
  for i, arg in ipairs(args) do
    if arg == "--session-dir" then
      explicit = args[i + 1]
    end
  end
  local configured = explicit or vim.env.PI_CODING_AGENT_SESSION_DIR
  if not configured or configured == "" then
    local project = settings(vim.fs.joinpath(s.cwd, ".pi", "settings.json"))
    local user = settings(vim.fs.joinpath(agent, "settings.json"))
    configured = project.sessionDir or user.sessionDir
  end
  local root = vim.fs.joinpath(agent, "sessions")
  local grouped = "--" .. resolve(s.cwd, s.cwd):gsub("^[/\\]", ""):gsub("[/\\:]", "-") .. "--"
  local directory = configured and configured ~= "" and resolve(configured, s.cwd) or vim.fs.joinpath(root, grouped)
  local current = s.state and s.state.sessionFile
  if type(current) == "string" and current ~= "" then
    directory = vim.fs.dirname(resolve(current, s.cwd))
  end
  return directory, configured and configured ~= "" and directory or root
end

local function content_text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts, "\n")
end

-- Stream metadata without materializing an entire conversation or decoding tool output.
-- Oversized lines are skipped; a malformed header never becomes a selectable session.
local function metadata(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local info, first = { path = path, modified = stat and stat.mtime.sec or 0 }, true
  local pending, offset, skipping = "", 0, false
  local function line(text)
    if first then
      first = false
      local header = decode(text:gsub("^\239\187\191", ""))
      if not header or header.type ~= "session" or type(header.id) ~= "string" or type(header.cwd) ~= "string" then
        return false
      end
      info.id, info.cwd, info.timestamp = header.id, header.cwd, header.timestamp
    elseif text:find('"session_info"', 1, true) or (not info.preview and text:find('"user"', 1, true)) then
      local entry = decode(text)
      if entry and entry.type == "session_info" and type(entry.name) == "string" then
        info.name = entry.name
      elseif entry and entry.type == "message" and type(entry.message) == "table" and entry.message.role == "user" then
        local preview = content_text(entry.message.content):gsub("%s+", " ")
        if preview ~= "" then
          info.preview = preview:sub(1, 120)
        end
      end
    end
    return true
  end
  while true do
    local chunk = uv.fs_read(fd, 65536, offset)
    if not chunk or chunk == "" then
      break
    end
    offset = offset + #chunk
    local start = 1
    while start <= #chunk do
      local stop = chunk:find("\n", start, true)
      local fragment = chunk:sub(start, stop and stop - 1 or #chunk)
      if not skipping then
        if #pending + #fragment > 1024 * 1024 then
          pending, skipping = "", true
        else
          pending = pending .. fragment
        end
      end
      if not stop then
        break
      end
      if skipping and first or not skipping and not line(pending) then
        uv.fs_close(fd)
        return nil
      end
      pending, skipping, start = "", false, stop + 1
    end
  end
  if pending ~= "" and not skipping and not line(pending) then
    uv.fs_close(fd)
    return nil
  end
  uv.fs_close(fd)
  return not first and info.id and info or nil
end

local function discover(s, all)
  local directory, root = storage(s)
  local found = {}
  local function scan(dir, recursive)
    local handle = uv.fs_scandir(dir)
    if not handle then
      return
    end
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local path = vim.fs.joinpath(dir, name)
      if kind == "directory" and recursive then
        scan(path, false)
      elseif kind == "file" and name:match("%.jsonl$") then
        local item = metadata(path)
        if item and (all or resolve(item.cwd, s.cwd) == resolve(s.cwd, s.cwd)) then
          found[#found + 1] = item
        end
      end
    end
  end
  scan(all and root or directory, all)
  table.sort(found, function(a, b)
    if a.modified == b.modified then
      return a.path > b.path
    end
    return a.modified > b.modified
  end)
  return found
end

local function switched(s, kind, fields, original)
  request(s, kind, fields, original, function(data)
    s.partial, s.tools, s.bash = nil, {}, nil
    s.queue = { steering = {}, followUp = {} }
    if kind == "fork" and type(data.text) == "string" and data.text ~= "" then
      local draft = s:get_draft()
      s:set_draft(draft == "" and data.text or draft .. "\n\n" .. data.text)
    end
    s:refresh()
  end)
end

local function model(s, argument, original)
  s:request("get_available_models", {}, function(err, data)
    if err or not alive(s) then
      return
    end
    local models = data and data.models or {}
    local function apply(item)
      change(s, "set_model", { provider = item.provider, modelId = item.id }, original)
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
    pick(s, models, "Models", function(item)
      return item.provider .. "/" .. item.id .. (item.name and "  " .. item.name or "")
    end, apply)
  end)
end

local function thinking(s, argument, original)
  s:request("get_available_thinking_levels", {}, function(err, data)
    if err or not alive(s) then
      return
    end
    local levels = data and data.levels or {}
    s.available_thinking_levels = levels
    local function apply(level)
      change(s, "set_thinking_level", { level = level }, original)
    end
    if argument ~= "" then
      if vim.tbl_contains(levels, argument) then
        apply(argument)
      else
        s:notice("Thinking level unavailable. Choose " .. table.concat(levels, ", "), "error")
      end
      return
    end
    pick(s, levels, "Thinking levels", nil, apply)
  end)
end

local settings_controls = {
  ["auto-compaction"] = { rpc = "set_auto_compaction", field = "enabled", values = { "on", "off" } },
  ["auto-retry"] = { rpc = "set_auto_retry", field = "enabled", values = { "on", "off" } },
  steering = { rpc = "set_steering_mode", field = "mode", values = { "all", "one-at-a-time" } },
  ["follow-up"] = { rpc = "set_follow_up_mode", field = "mode", values = { "all", "one-at-a-time" } },
}
local settings_names = { "auto-compaction", "auto-retry", "steering", "follow-up" }

local function configure(s, argument, original)
  local name, value = argument:match("^(%S+)%s*(.-)$")
  local function choose(key, chosen)
    local control = settings_controls[key]
    if not control then
      s:notice("RPC settings: " .. table.concat(settings_names, ", "), "error")
      return
    end
    local function apply(selected)
      if not vim.tbl_contains(control.values, selected) then
        s:notice("Use " .. table.concat(control.values, " or ") .. " for " .. key, "error")
        return
      end
      local fields = {}
      if control.field == "enabled" then
        fields.enabled = selected == "on"
      else
        fields.mode = selected
      end
      change(s, control.rpc, fields, original)
    end
    if chosen and chosen ~= "" then
      apply(chosen)
    else
      pick(s, control.values, key, nil, apply)
    end
  end
  if name then
    choose(name, value)
  else
    pick(s, settings_names, "RPC settings", function(key)
      local state = s.state or {}
      local values = {
        ["auto-compaction"] = state.autoCompactionEnabled,
        steering = state.steeringMode,
        ["follow-up"] = state.followUpMode,
      }
      local current = values[key]
      if type(current) == "boolean" then
        current = current and "on" or "off"
      end
      return key .. (current ~= nil and "  " .. tostring(current) or "")
    end, choose)
  end
end

local function stats(s, original)
  request(s, "get_session_stats", {}, original, function(data)
    s.stats = data
    local state = s.state or {}
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
    s:notice(table.concat(lines, "\n"), "info")
  end)
end

local function bash(s, text)
  local input = vim.trim(text)
  local excluded = input:sub(1, 2) == "!!"
  local command = vim.trim(input:sub(excluded and 3 or 2))
  if command == "" then
    s:notice("Use !command or !!command", "error")
    return
  end
  if s.bash and s.bash.running then
    s:notice("A shell command is already running. Abort it first.", "warning")
    return
  end
  local execution = { command = command, output = "", running = true, excludeFromContext = excluded }
  s.bash = execution
  execution.id = s:request("bash", { command = command, excludeFromContext = excluded }, function(err, data)
    if not alive(s) then
      return
    end
    execution.running = false
    if err then
      execution.error = err
      s:render()
      return
    end
    data = data or {}
    if not data.truncated or execution.output == "" then
      execution.output = data.output or execution.output
    end
    execution.exitCode, execution.cancelled = data.exitCode, data.cancelled
    execution.truncated, execution.fullOutputPath = data.truncated, data.fullOutputPath
    if not data.cancelled then
      consume(s, text)
    end
    s:refresh()
  end)
  if not execution.id then
    execution.running = false
  end
  s:render()
end

function M.run(s, text)
  local input = vim.trim(text)
  if input:sub(1, 1) == "!" then
    bash(s, text)
    return true
  end
  local name, argument = input:match("^/([^%s]+)%s*(.*)$")
  if not name then
    return false
  end
  argument = vim.trim(argument)
  if name == "hotkeys" then
    -- Mappings are buffer-local with descriptions, so Neovim already lists the active set.
    s:notice("/hotkeys is not available. Use :nmap <buffer> or :help dyadic-mappings", "warning")
  elseif unsupported[name] then
    s:notice("/" .. name .. " is not available through stock pi RPC. Use pi in a terminal.", "error")
  elseif name == "model" then
    model(s, argument, text)
  elseif name == "thinking" then
    thinking(s, argument, text)
  elseif name == "settings" then
    configure(s, argument, text)
  elseif name == "new" or name == "clone" then
    if argument ~= "" then
      s:notice("Usage: /" .. name, "error")
    else
      switched(s, name == "new" and "new_session" or "clone", {}, text)
    end
  elseif name == "resume" then
    if argument ~= "" and argument ~= "all" then
      local path = resolve(argument, s.cwd)
      if not metadata(path) then
        s:notice("Not a readable pi session file: " .. path, "error")
      else
        switched(s, "switch_session", { sessionPath = path }, text)
      end
    else
      pick(s, discover(s, argument == "all"), "Saved sessions", function(item)
        return (item.name or item.preview or item.id) .. "  " .. (item.timestamp or "") .. "  " .. item.cwd
      end, function(item)
        switched(s, "switch_session", { sessionPath = item.path }, text)
      end)
    end
  elseif name == "fork" then
    s:request("get_fork_messages", {}, function(err, data)
      if err or not alive(s) then
        return
      end
      local messages = data and data.messages or {}
      if argument ~= "" then
        for _, item in ipairs(messages) do
          if item.entryId == argument then
            switched(s, "fork", { entryId = item.entryId }, text)
            return
          end
        end
        s:notice("No forkable user message with entry ID " .. argument, "error")
        return
      end
      pick(s, messages, "Fork messages", function(item)
        return item.entryId .. "  " .. (item.text or ""):gsub("%s+", " "):sub(1, 150)
      end, function(item)
        switched(s, "fork", { entryId = item.entryId }, text)
      end)
    end)
  elseif name == "name" then
    if argument == "" then
      request(s, "get_state", {}, text, function(data)
        s:notice("Session name: " .. (data.sessionName or "unnamed"), "info")
      end)
    else
      change(s, "set_session_name", { name = argument }, text)
    end
  elseif name == "session" or name == "stats" then
    stats(s, text)
  elseif name == "compact" then
    change(s, "compact", argument ~= "" and { customInstructions = argument } or {}, text)
  elseif name == "copy" then
    request(s, "get_last_assistant_text", {}, nil, function(data)
      if type(data.text) ~= "string" then
        s:notice("No assistant text to copy", "warning")
        return
      end
      vim.fn.setreg('"', data.text, "v")
      local ok, err = pcall(vim.fn.setreg, "+", data.text, "v")
      consume(s, text)
      s:notice(
        ok and "Copied last assistant response to clipboard and unnamed register"
          or "Copied to unnamed register; clipboard unavailable: " .. tostring(err),
        ok and "info" or "warning"
      )
    end)
  elseif name == "export" then
    if argument:lower():match("%.jsonl$") or argument:lower() == "jsonl" then
      s:notice(
        "JSONL export is not exposed by stock pi RPC. Use /export in pi; HTML export is available here.",
        "error"
      )
    else
      request(s, "export_html", argument ~= "" and { outputPath = resolve(argument, s.cwd) } or {}, text, function(data)
        s:notice("Exported HTML: " .. tostring(data.path), "info")
      end)
    end
  elseif name == "quit" then
    s:close()
  else
    return false
  end
  return true
end

function M.complete(s, prefix)
  prefix = prefix or ""
  if prefix ~= "" and prefix:sub(1, 1) ~= "/" then
    prefix = "/" .. prefix
  end
  local result, seen = {}, {}
  local function add(value)
    if value:sub(1, #prefix) == prefix and not seen[value] then
      seen[value] = true
      result[#result + 1] = value
    end
  end
  local setting, setting_prefix = prefix:match("^/settings%s+(%S+)%s+(.*)$")
  if setting and settings_controls[setting] then
    for _, value in ipairs(settings_controls[setting].values) do
      if value:sub(1, #setting_prefix) == setting_prefix then
        add("/settings " .. setting .. " " .. value)
      end
    end
  elseif prefix:match("^/settings%s+") then
    for _, name in ipairs(settings_names) do
      add("/settings " .. name)
    end
  elseif prefix:match("^/thinking%s+") then
    -- The picker queries model-specific levels; do not suggest unsupported levels.
    for _, level in ipairs(s.available_thinking_levels or {}) do
      add("/thinking " .. level)
    end
  else
    for _, name in ipairs(M.names) do
      add("/" .. name)
    end
    for _, command in ipairs(s.commands or {}) do
      local name = type(command) == "table" and command.name or command
      if type(name) == "string" then
        add(name:sub(1, 1) == "/" and name or "/" .. name)
      end
    end
  end
  table.sort(result)
  return result
end

return M
