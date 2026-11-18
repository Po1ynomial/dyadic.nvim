local View = require("dyadic.view")
local Commands = require("dyadic.commands")
local History = require("dyadic.history")
local Session = {}
Session.__index = Session

function Session.new(id, config, on_close)
  local self = setmetatable({
    id = id,
    config = config,
    cwd = vim.fn.getcwd(),
    on_close = on_close,
    state = {},
    stats = {},
    messages = {},
    tools = {},
    notices = {},
    commands = {},
    queue = { steering = {}, followUp = {} },
    widgets = {},
    statuses = {},
    compaction_queue = {},
    queue_flush_version = 0,
    status = "Starting pi",
    active = false,
    closed = false,
    show_thinking = true,
    expand_tools = false,
    history_version = 0,
    refresh_version = 0,
  }, Session)
  View.new(self)
  local cmd = vim.deepcopy(config.cmd)
  vim.list_extend(cmd, { "--mode", "rpc" })
  vim.list_extend(cmd, config.args)
  local rpc, err = require("dyadic.rpc").new({
    cmd = cmd,
    cwd = self.cwd,
    on_record = function(record)
      if not self.closed then
        self:event(record)
      end
    end,
    on_error = function(text)
      self:notice(text, "error")
    end,
    on_stderr = function(text)
      self:notice(text, "diagnostic")
    end,
    on_exit = function(code, signal)
      if self.closed then
        return
      end
      self.active, self.partial = false, nil
      self.status = "Pi exited"
      for _, tool in pairs(self.tools) do
        tool.running = false
      end
      View.dispose_dialogs(self)
      self:notice(string.format("Pi exited with code %s, signal %s", code, signal), code == 0 and "info" or "error")
    end,
  })
  self.rpc = rpc
  if not rpc then
    self.status = "Pi failed to start"
    self:notice(err, "error")
  else
    self:refresh()
  end
  return self
end

function Session:request(kind, fields, callback)
  if self.closed or not self.rpc then
    local err = self.closed and "Conversation is closed" or "Pi is not running"
    self:notice(err, "error")
    if callback then
      callback(err)
    end
    return nil, err
  end
  local id, request_err = self.rpc:request(kind, fields or {}, function(err, data, response)
    if self.closed then
      return
    end
    if err then
      self:notice(err, "error")
    end
    if callback then
      callback(err, data, response)
    end
  end)
  if not id then
    self:notice(request_err, "error")
    if callback then
      callback(request_err)
    end
  end
  return id, request_err
end

function Session:render()
  if self.closed or self.render_pending then
    return
  end
  self.render_pending = true
  vim.defer_fn(function()
    self.render_pending = false
    if not self.closed and vim.api.nvim_buf_is_valid(self.buf) then
      View.render(self)
    end
  end, 25)
end

function Session:notice(text, level)
  if self.closed or not text or text == "" then
    return
  end
  self.notices[#self.notices + 1] = { text = tostring(text), level = level or "info" }
  self:render()
end

function Session:get_draft()
  return View.get_draft(self)
end
function Session:set_draft(text)
  View.set_draft(self, text or "")
end

function Session:sync_history(callback)
  local version = self.history_version
  self:request("get_entries", {}, function(err, data)
    if not err and version == self.history_version then
      self.messages = History.messages(data.entries or {}, data.leafId)
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

function Session:refresh(callback)
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
      -- Extension UI records may precede the switch response. Keep their latest values.
      self.notices = {}
      View.dispose_dialogs(self)
    end
    self.state = state
    self.active = state.isStreaming == true or state.isCompacting == true
    self.status = state.isCompacting and "Compacting" or (self.active and "Working" or "Idle")
    self:sync_history(function(history_err)
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

function Session:submit(mode)
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
    if data and data.disposition == "queued" then
      self:notice("Input queued as " .. (mode or "steer"))
    end
    if data and data.disposition == "handled" then
      self:refresh()
    end
  end)
end

function Session:restore_queue(data)
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

function Session:dequeue()
  self.queue_flush_version = self.queue_flush_version + 1
  self:request("clear_queue", {}, function(err, data)
    if not err then
      self:restore_queue(data)
    end
  end)
end

function Session:abort()
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

function Session:flush_compaction_queue(will_retry)
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

function Session:action(name)
  if name == "toggle_thinking" then
    self.show_thinking = not self.show_thinking
    self:render()
  elseif name == "toggle_tools" then
    self.expand_tools = not self.expand_tools
    self:render()
  elseif name == "focus_draft" or name == "focus_transcript" then
    View.focus(self, name == "focus_draft")
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

function Session:event(record)
  local kind = record.type
  if kind == "extension_ui_request" then
    View.extension(self, record)
    return
  end
  if kind == "agent_start" then
    self.active, self.status = true, "Working"
  elseif kind == "agent_settled" then
    self.active, self.status = false, record.aborted and "Aborted" or "Idle"
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
    end
  elseif kind == "queue_update" then
    self.queue = { steering = record.steering or {}, followUp = record.followUp or {} }
  elseif kind == "session_info_changed" then
    self.state.sessionName = record.name
  elseif kind == "thinking_level_changed" then
    self.state.thinkingLevel = record.level
  elseif kind == "compaction_start" then
    self.state.isCompacting, self.active, self.status = true, true, "Compacting"
  elseif kind == "compaction_end" then
    self.state.isCompacting = false
    self.history_version = self.history_version + 1
    self:sync_history()
    if record.errorMessage then
      self:notice(record.errorMessage, "error")
    end
    if record.aborted then
      self:notice("Compaction cancelled")
    end
    self.status = record.willRetry and "Recovering" or (self.active and "Working" or "Idle")
    self:flush_compaction_queue(record.willRetry)
  elseif kind == "auto_retry_start" or kind == "summarization_retry_scheduled" then
    self.active, self.status = true, "Retrying"
    self:notice(
      string.format("Retry %s in %sms: %s", record.attempt or "?", record.delayMs or 0, record.errorMessage or ""),
      "warning"
    )
  elseif kind == "summarization_retry_attempt_start" then
    self.status = "Retrying " .. (record.source or "summary")
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
    self:sync_history()
  end
  self:render()
end

function Session:close(keep_buffer)
  if self.closed then
    return
  end
  View.dispose(self)
  self.closed, self.active = true, false
  if self.rpc then
    self.rpc:close()
  end
  if self.on_close then
    self.on_close(self)
  end
  if not keep_buffer and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
end

return Session
