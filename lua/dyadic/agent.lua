local View = require("dyadic.view")
local Commands = require("dyadic.commands")
local Entries = require("dyadic.entries")
local ExtensionUI = require("dyadic.extension_ui")
local QuitGuard = require("dyadic.quit_guard")
local Bridge = require("dyadic.bridge")
local Agent = {}
Agent.__index = Agent

function Agent.new(id, config, on_close)
  local self = setmetatable({
    id = id,
    config = config,
    cwd = vim.fn.getcwd(),
    on_close = on_close,
    state = {},
    stats = {},
    messages = {},
    tools = {},
    commands = {},
    queue = { steering = {}, followUp = {} },
    widgets = {},
    statuses = {},
    compaction_queue = {},
    queue_flush_version = 0,
    phase = "Starting pi",
    active = false,
    closed = false,
    -- Activity group key -> true/false when the user expanded or collapsed it.
    expanded = {},
    history_version = 0,
    refresh_version = 0,
  }, Agent)
  View.new(self)
  local cmd = vim.deepcopy(config.cmd)
  vim.list_extend(cmd, { "--mode", "rpc" })
  vim.list_extend(cmd, Bridge.args(config))
  vim.list_extend(cmd, config.args)
  local rpc, err = require("dyadic.rpc").new({
    cmd = cmd,
    cwd = self.cwd,
    env = Agent.environment(),
    on_record = function(record)
      if not self.closed then
        self:event(record)
      end
    end,
    on_error = function(text)
      self:notice(text, "error")
    end,
    on_stderr = function(text)
      self:log(text)
    end,
    on_exit = function(code, signal)
      if self.closed then
        return
      end
      self.active, self.partial = false, nil
      self.phase = code == 0 and signal == 0 and "Pi exited" or string.format("Pi exited (code %s)", code)
      for _, tool in pairs(self.tools) do
        tool.running = false
      end
      ExtensionUI.dispose_dialogs(self)
      require("dyadic.review").abort(self)
      if code == 0 and signal == 0 then
        self:notice("Pi exited")
      else
        local where = self.log_path and "; stderr log: " .. self.log_path or ""
        self:notice(string.format("Pi exited with code %s, signal %s%s", code, signal, where), "error")
      end
      self:render()
    end,
  })
  self.rpc = rpc
  if not rpc then
    self.phase = "Pi failed to start"
    self:notice(err, "error")
  else
    self:refresh()
  end
  return self
end

-- Neovim sets $NVIM only for jobstart()/terminal children, so an inherited value names an
-- outer instance. Remove it so pi's tools cannot attach to the wrong Neovim.
function Agent.environment()
  local env = {}
  for name, value in pairs(vim.fn.environ()) do
    if name ~= "NVIM" and name ~= "NVIM_LISTEN_ADDRESS" then
      env[#env + 1] = name .. "=" .. value
    end
  end
  return env
end

function Agent:request(kind, fields, callback)
  if self.closed or not self.rpc then
    local err = self.closed and "Agent is closed" or "Pi is not running"
    self:notice(err, "error")
    if callback then
      callback(err)
    end
    return nil, err
  end
  -- After pi exits, on_exit reports once. Don't repeat it for pending requests or for
  -- follow-up requests that callbacks send to the dead process.
  local function exited()
    return self.rpc._exit ~= nil or self.rpc._exited == true
  end
  local id, request_err = self.rpc:request(kind, fields or {}, function(err, data, response)
    if self.closed then
      return
    end
    if err and not exited() then
      self:notice(err, "error")
    end
    if callback then
      callback(err, data, response)
    end
  end)
  if not id then
    if not exited() then
      self:notice(request_err, "error")
    end
    if callback then
      callback(request_err)
    end
  end
  return id, request_err
end

function Agent:render()
  QuitGuard.update()
  if self.closed or self.render_pending then
    return
  end
  self.render_pending = true
  vim.defer_fn(function()
    self.render_pending = false
    if not self.closed and vim.api.nvim_buf_is_valid(self.history_buf) then
      View.render(self)
    end
  end, 25)
end

local levels = {
  error = vim.log.levels.ERROR,
  warning = vim.log.levels.WARN,
  warn = vim.log.levels.WARN,
}

function Agent:notice(text, level)
  if self.closed or not text or text == "" then
    return
  end
  vim.notify("Dyadic: " .. tostring(text), levels[level] or vim.log.levels.INFO)
end

-- Pi diagnostics are rarely needed; keep them in a temporary file instead of notifications.
function Agent:log(text)
  if not self.log_path then
    self.log_path = vim.fn.tempname() .. "-dyadic-" .. self.id .. ".log"
  end
  local fd = vim.uv.fs_open(self.log_path, "a", 420)
  if fd then
    vim.uv.fs_write(fd, text)
    vim.uv.fs_close(fd)
  end
end

-- Agent status as data, for the history statusline and user statuslines.
function Agent:status()
  local state, stats = self.state or {}, self.stats or {}
  local model = type(state.model) == "table" and state.model or {}
  local usage = type(stats.contextUsage) == "table" and stats.contextUsage or nil
  local extensions = {}
  local keys = vim.tbl_keys(self.statuses or {})
  table.sort(keys)
  for _, key in ipairs(keys) do
    extensions[#extensions + 1] = self.statuses[key]
  end
  local function number(value)
    return type(value) == "number" and value or nil
  end
  return {
    title = self.title or state.sessionName or "Dyadic",
    phase = self.phase or "Idle",
    active = self.active,
    session_id = state.sessionId,
    session_file = state.sessionFile,
    model = model.id and ((model.provider and model.provider .. "/" or "") .. model.id) or nil,
    thinking = state.thinkingLevel,
    context = usage and {
      tokens = number(usage.tokens),
      window = number(usage.contextWindow),
      percent = number(usage.percent),
    } or nil,
    tokens = type(stats.tokens) == "table" and number(stats.tokens.total) or nil,
    cost = number(stats.cost),
    extensions = extensions,
  }
end

function Agent:get_draft()
  return View.get_draft(self)
end
function Agent:set_draft(text)
  View.set_draft(self, text or "")
end

function Agent:sync_messages(callback)
  local version = self.history_version
  self:request("get_entries", {}, function(err, data)
    if not err and version == self.history_version then
      self.messages = Entries.messages(data.entries or {}, data.leafId)
      if not self.active then
        self.partial = nil
        self.tools = {}
      end
      self:render()
    end
    if callback then
      callback(err)
    end
  end)
end

function Agent:refresh(callback)
  self.refresh_version = self.refresh_version + 1
  local version = self.refresh_version
  self:request("get_state", {}, function(err, state)
    if version ~= self.refresh_version then
      return
    end
    if err then
      if callback then
        callback(err)
      end
      return
    end
    local previous_model, current_model = self.state.model or {}, state.model or {}
    if previous_model.id ~= current_model.id or previous_model.provider ~= current_model.provider then
      self.available_thinking_levels = nil
    end
    if self.state.sessionId and self.state.sessionId ~= state.sessionId then
      self.history_version = self.history_version + 1
      self.messages, self.tools, self.partial, self.bash = {}, {}, nil, nil
      self.queue = { steering = {}, followUp = {} }
      self.compaction_queue = {}
      self.queue_flush_version = self.queue_flush_version + 1
      self.expanded, self.run_failed, self._render_cache = {}, nil, nil
      ExtensionUI.dispose_dialogs(self)
    end
    self.state = state
    self.active = state.isStreaming == true or state.isCompacting == true
    self.phase = state.isCompacting and "Compacting" or (self.active and "Working" or "Idle")
    self:sync_messages(function(history_err)
      if version ~= self.refresh_version then
        return
      end
      self:request("get_session_stats", {}, function(stats_err, stats)
        if version ~= self.refresh_version then
          return
        end
        if not stats_err then
          self.stats = stats
        end
        self:request("get_commands", {}, function(commands_err, data)
          if version ~= self.refresh_version then
            return
          end
          if not commands_err then
            self.commands = data.commands or {}
            Bridge.check(self)
          end
          self:render()
          if callback then
            callback(history_err or stats_err or commands_err)
          end
        end)
      end)
    end)
  end)
end

function Agent:submit(mode)
  local text = self:get_draft()
  if text:match("^%s*$") then
    return
  end
  if self.submitting then
    self:notice("Waiting for pi to accept the previous input")
    return
  end
  if self.aborting then
    self:notice("Waiting for pi to stop")
    return
  end
  if Commands.run(self, text) then
    return
  end
  local command = text:match("^/([^%s]+)")
  local extension_command = false
  for _, item in ipairs(self.commands) do
    if item.name == command and item.source == "extension" then
      extension_command = true
      break
    end
  end
  if self.state.isCompacting and not extension_command then
    self.compaction_queue[#self.compaction_queue + 1] = { text = text, mode = mode or "steer" }
    self:set_draft("")
    self:render()
    return
  end
  self.submitting = true
  local fields = { message = text }
  if self.active or mode == "followUp" then
    fields.streamingBehavior = mode or "steer"
  end
  self:request("prompt", fields, function(err, data)
    self.submitting = false
    if err then
      return
    end
    -- A user may continue editing while pi accepts input. Never erase those edits.
    if self:get_draft() == text then
      self:set_draft("")
    end
    if data and data.disposition == "handled" then
      self:refresh()
    end
  end)
end

function Agent:restore_queue(data)
  local texts = {}
  local draft = self:get_draft()
  if draft ~= "" then
    texts[#texts + 1] = draft
  end
  vim.list_extend(texts, data.steering or {})
  vim.list_extend(texts, data.followUp or {})
  for _, item in ipairs(self.compaction_queue) do
    texts[#texts + 1] = item.text
  end
  self.compaction_queue = {}
  self:set_draft(table.concat(texts, "\n\n"))
  self.queue = { steering = {}, followUp = {} }
  self:render()
end

function Agent:dequeue()
  self.queue_flush_version = self.queue_flush_version + 1
  self:request("clear_queue", {}, function(err, data)
    if not err then
      self:restore_queue(data)
    end
  end)
end

function Agent:abort()
  if self.aborting then
    return
  end
  self.aborting = true
  self.queue_flush_version = self.queue_flush_version + 1
  self:request("clear_queue", {}, function(err, data)
    if err then
      self.aborting = false
      return
    end
    self:restore_queue(data)
    local kind = self.bash and self.bash.running and "abort_bash" or "abort"
    self:request(kind, {}, function()
      self.aborting = false
      self:refresh()
    end)
  end)
end

function Agent:flush_compaction_queue(will_retry)
  if self.aborting or #self.compaction_queue == 0 then
    return
  end
  self.queue_flush_version = self.queue_flush_version + 1
  local version, first = self.queue_flush_version, not will_retry
  local function send_next()
    if self.closed or self.aborting or version ~= self.queue_flush_version then
      return
    end
    local item = table.remove(self.compaction_queue, 1)
    if not item then
      return
    end
    local kind = first and "prompt" or (item.mode == "followUp" and "follow_up" or "steer")
    first = false
    local fields = { message = item.text }
    if kind == "prompt" then
      fields.streamingBehavior = item.mode
    end
    self:request(kind, fields, function(err)
      if err then
        if version == self.queue_flush_version then
          table.insert(self.compaction_queue, 1, item)
        end
      else
        send_next()
      end
      self:render()
    end)
  end
  send_next()
end

function Agent:action(name)
  if View.actions[name] and View.actions[name][3] == "history" then
    View.action(self, name)
  elseif name == "focus_composer" or name == "focus_history" then
    View.focus(self, name == "focus_composer")
  elseif name == "cycle_thinking" or name == "cycle_model" then
    self:request(name == "cycle_model" and "cycle_model" or "cycle_thinking_level", {}, function(err)
      if not err then
        self:refresh()
      end
    end)
  else
    Commands.run(self, "/" .. name)
  end
end

-- Tools that cannot change files. Anything else, including bash and custom tools, may.
local read_only_tools = { read = true, grep = true, find = true, ls = true }

-- Reload buffers whose files the agent may have changed. Buffers with unsaved changes are
-- skipped so no prompt interrupts typing; 'autoread' still decides whether reloading asks.
function Agent:check_files()
  if self.checking_files then
    return
  end
  self.checking_files = true
  vim.defer_fn(function()
    self.checking_files = false
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buftype == ""
        and not vim.bo[buf].modified
        and vim.api.nvim_buf_get_name(buf) ~= ""
      then
        pcall(vim.api.nvim_command, "silent! checktime " .. buf)
      end
    end
  end, 25)
end

function Agent:event(record)
  local kind = record.type
  if kind == "extension_ui_request" then
    ExtensionUI.handle(self, record)
    return
  end
  if kind == "agent_start" then
    self.active, self.phase, self.run_failed = true, "Working", nil
  elseif kind == "agent_settled" then
    self.active, self.phase = false, record.aborted and "Aborted" or "Idle"
    -- A tool waiting for a review cannot finish a run, so open reviews were aborted.
    require("dyadic.review").abort(self)
    -- A failed run keeps its trailing activity expanded, showing where it stopped.
    local last = self.messages[#self.messages]
    self.run_failed = record.aborted == true
      or (last and last.role == "assistant" and (last.stopReason == "error" or last.stopReason == "aborted"))
      or nil
    self:refresh()
  elseif kind == "message_start" then
    self.history_version = self.history_version + 1
    if record.message.role == "assistant" then
      self.partial = vim.deepcopy(record.message)
    end
  elseif kind == "message_update" then
    local update = record.assistantMessageEvent or {}
    local index = (update.contentIndex or 0) + 1
    if self.partial and update.contentIndex ~= nil then
      self.partial.content = self.partial.content or {}
      local block = self.partial.content[index]
      if update.type == "text_start" then
        block = { type = "text", text = "" }
      elseif update.type == "thinking_start" then
        block = { type = "thinking", thinking = "" }
      elseif update.type == "toolcall_start" then
        block = { type = "toolCall", id = update.id, name = update.toolName, arguments = {}, raw = "" }
      elseif update.type == "text_delta" then
        block = block or { type = "text", text = "" }
        block.text = (block.text or "") .. update.delta
      elseif update.type == "thinking_delta" then
        block = block or { type = "thinking", thinking = "" }
        block.thinking = (block.thinking or "") .. update.delta
      elseif update.type == "toolcall_delta" then
        block = block or { type = "toolCall", arguments = {}, raw = "" }
        block.raw = (block.raw or "") .. update.delta
      elseif update.type == "text_end" then
        block = { type = "text", text = update.content }
      elseif update.type == "thinking_end" then
        block = { type = "thinking", thinking = update.content }
      elseif update.type == "toolcall_end" then
        block = update.toolCall
      end
      self.partial.content[index] = block
      if record.usage then
        self.partial.usage = record.usage
      end
    end
  elseif kind == "message_end" then
    self.history_version = self.history_version + 1
    self.messages[#self.messages + 1] = record.message
    if record.message.role == "assistant" then
      self.partial = nil
    end
    if record.message.role == "toolResult" then
      self.tools[record.message.toolCallId] = nil
    end
  elseif kind == "tool_execution_start" then
    self.tools[record.toolCallId] = { toolName = record.toolName, args = record.args, running = true }
  elseif kind == "tool_execution_update" or kind == "tool_execution_end" then
    local tool = self.tools[record.toolCallId] or { toolName = record.toolName, args = record.args }
    self.tools[record.toolCallId] = tool
    if kind == "tool_execution_update" then
      tool.partialResult = record.partialResult
    else
      tool.running, tool.result, tool.isError, tool.durationMs = false, record.result, record.isError, record.durationMs
      if not read_only_tools[record.toolName] then
        self:check_files()
      end
    end
  elseif kind == "queue_update" then
    self.queue = { steering = record.steering or {}, followUp = record.followUp or {} }
  elseif kind == "session_info_changed" then
    self.state.sessionName = record.name
  elseif kind == "thinking_level_changed" then
    self.state.thinkingLevel = record.level
  elseif kind == "compaction_start" then
    self.state.isCompacting, self.active, self.phase = true, true, "Compacting"
  elseif kind == "compaction_end" then
    self.state.isCompacting = false
    self.history_version = self.history_version + 1
    -- compaction_start forced active; only pi knows whether a run continues.
    self:refresh()
    if record.errorMessage then
      self:notice(record.errorMessage, "error")
    end
    if record.aborted then
      self:notice("Compaction cancelled")
    end
    self.phase = record.willRetry and "Recovering" or (self.active and "Working" or "Idle")
    self:flush_compaction_queue(record.willRetry)
  elseif kind == "auto_retry_start" or kind == "summarization_retry_scheduled" then
    self.active, self.phase = true, "Retrying"
    self:notice(
      string.format("Retry %s in %sms: %s", record.attempt or "?", record.delayMs or 0, record.errorMessage or ""),
      "warning"
    )
  elseif kind == "summarization_retry_attempt_start" then
    self.phase = "Retrying " .. (record.source or "summary")
  elseif kind == "auto_retry_end" then
    if record.finalError then
      self:notice(record.finalError, "error")
    end
  elseif kind == "bash_execution_update" then
    if self.bash then
      self.bash.output = (self.bash.output or "") .. record.delta
    end
  elseif kind == "extension_error" then
    self:notice(record.errorMessage or record.error or "Extension failed", "error")
  elseif kind == "entry_appended" and not self.active then
    self.history_version = self.history_version + 1
    self:sync_messages()
  end
  self:render()
end

function Agent:close(keep_buffer)
  if self.closed then
    return
  end
  require("dyadic.review").abort(self)
  View.dispose(self)
  self.closed, self.active = true, false
  if self.rpc then
    self.rpc:close()
  end
  if self.on_close then
    self.on_close(self)
  end
  QuitGuard.update()
  if not keep_buffer and vim.api.nvim_buf_is_valid(self.history_buf) then
    pcall(vim.api.nvim_buf_delete, self.history_buf, { force = true })
  end
end

return Agent
