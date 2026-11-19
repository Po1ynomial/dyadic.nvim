local M = {}
local uv = vim.uv
local Client = {}
Client.__index = Client

local CLOSE_GRACE_MS = 1500
local TERMINATE_GRACE_MS = 500
local EXIT_DRAIN_MS = 500
local next_client = 0

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function stop_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Client:_invoke(callback, ...)
  if not callback then
    return
  end
  local ok, err = pcall(callback, ...)
  if not ok then
    local message = "RPC callback failed: " .. tostring(err)
    if callback ~= self._opts.on_error and self._opts.on_error then
      pcall(self._opts.on_error, message)
    else
      vim.notify(message, vim.log.levels.ERROR)
    end
  end
end

-- Raw libuv callbacks only enqueue. One scheduled drain preserves wire order.
function Client:_enqueue(item)
  self._events[#self._events + 1] = item
  if self._scheduled then
    return
  end
  self._scheduled = true
  vim.schedule(function()
    local index = 1
    while index <= #self._events do
      local event = self._events[index]
      self._events[index] = false
      index = index + 1
      local ok, err = pcall(self._dispatch, self, event)
      if not ok then
        self:_fail("RPC transport failed: " .. tostring(err))
      end
    end
    self._events = {}
    self._scheduled = false
  end)
end

function Client:_fail_pending(message)
  local pending = self._pending
  self._pending = {}
  self._ids = {}
  local sequences = {}
  for sequence in pairs(pending) do
    sequences[#sequences + 1] = sequence
  end
  table.sort(sequences)
  for _, sequence in ipairs(sequences) do
    self:_invoke(pending[sequence].callback, message, nil, nil)
  end
end

function Client:_fail(message)
  if self._failure or self._finished then
    return
  end
  self._failure = message
  self:_invoke(self._opts.on_error, message)
  self:_fail_pending(message)
  self:_begin_close(true)
end

function Client:_response(record)
  if
    type(record.command) ~= "string"
    or type(record.success) ~= "boolean"
    or (record.id ~= nil and type(record.id) ~= "string")
  then
    self:_fail("Malformed pi RPC response: expected command, success, and a string id")
    return
  end
  local sequence = record.id and self._ids[record.id]
  local pending = sequence and self._pending[sequence]
  if not pending then
    if self._closing then
      return
    end
    -- Uncorrelated parse errors cannot identify which pending command failed.
    if record.command == "parse" and record.success == false then
      self:_fail("Pi rejected RPC input: " .. tostring(record.error or "parse error"))
    elseif next(self._pending) then
      self:_fail(
        "Uncorrelated pi RPC response while requests are pending for "
          .. record.command
          .. " (id "
          .. tostring(record.id)
          .. ")"
      )
    else
      self:_invoke(
        self._opts.on_error,
        "Uncorrelated pi RPC response for " .. record.command .. " (id " .. tostring(record.id) .. ")"
      )
    end
    return
  end
  if record.command ~= pending.command then
    self:_fail(
      "Mismatched pi RPC response for "
        .. record.id
        .. ": expected "
        .. pending.command
        .. ", received "
        .. record.command
    )
    return
  end
  if not record.success and type(record.error) ~= "string" then
    self:_fail("Malformed pi RPC failure response for " .. record.id .. ": missing error")
    return
  end
  self._pending[sequence] = nil
  self._ids[record.id] = nil
  local data = record.data
  if data == vim.NIL then
    data = nil
  end
  local response_error
  if not record.success then
    response_error = record.error
  end
  self:_invoke(pending.callback, response_error, data, record)
end

function Client:_line(line)
  if self._failure or self._finished then
    return
  end
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  local ok, record = pcall(vim.json.decode, line)
  if not ok then
    self:_fail("Malformed pi RPC stdout JSON: " .. tostring(record))
    return
  end
  if type(record) ~= "table" or type(record.type) ~= "string" or line:match("^%s*{") == nil then
    self:_fail("Malformed pi RPC stdout record: expected a JSON object with a string type")
    return
  end
  if record.type == "response" then
    self:_response(record)
  else
    self:_invoke(self._opts.on_record, record)
  end
end

function Client:_stdout(chunk)
  if self._failure or self._finished then
    return
  end
  local start = 1
  while true do
    local boundary = chunk:find("\n", start, true)
    if not boundary then
      if start <= #chunk then
        self._fragments[#self._fragments + 1] = chunk:sub(start)
      end
      return
    end
    local line = chunk:sub(start, boundary - 1)
    if #self._fragments > 0 then
      self._fragments[#self._fragments + 1] = line
      line = table.concat(self._fragments)
      self._fragments = {}
    end
    self:_line(line)
    if self._failure then
      self._fragments = {}
      return
    end
    start = boundary + 1
  end
end

function Client:_finish()
  if self._finished or not self._exit or not self._stdout_eof or not self._stderr_eof then
    return
  end
  self._finished = true
  stop_timer(self._close_timer)
  stop_timer(self._drain_timer)
  close_handle(self._stdin)
  close_handle(self._stdout_pipe)
  close_handle(self._stderr_pipe)
  self._writes = {}
  -- An unexpected exit is reported once, through on_exit; pending requests still fail.
  local message = self._failure
    or (self._closing and "Pi RPC client closed")
    or ("Pi RPC process exited unexpectedly (code " .. self._exit.code .. ", signal " .. self._exit.signal .. ")")
  self:_fail_pending(message)
  self._ids = {}
  self:_invoke(self._opts.on_exit, self._exit.code, self._exit.signal)
end

function Client:_dispatch(event)
  if self._finished then
    return
  end
  if event.kind == "stdout" then
    self:_stdout(event.data)
  elseif event.kind == "stderr" then
    self:_invoke(self._opts.on_stderr, event.data)
  elseif event.kind == "stdout_eof" then
    self._stdout_eof = true
    if #self._fragments > 0 and not self._failure then
      self._fragments = {}
      self:_fail("Truncated pi RPC stdout record: stream ended before LF")
    end
    self:_finish()
  elseif event.kind == "stderr_eof" then
    self._stderr_eof = true
    self:_finish()
  elseif event.kind == "error" then
    self:_fail(event.message)
  elseif event.kind == "closed" then
    self:_fail_pending("Pi RPC client closed")
    self._ids = {}
  elseif event.kind == "exit" then
    self._exit = { code = event.code, signal = event.signal }
    stop_timer(self._close_timer)
    self:_finish()
    if not self._finished then
      -- Descendants can inherit these pipes; don't wait on their EOF forever.
      self._drain_timer = uv.new_timer()
      self._drain_timer:start(EXIT_DRAIN_MS, 0, function()
        self:_enqueue({ kind = "drain_timeout" })
      end)
    end
  elseif event.kind == "drain_timeout" then
    close_handle(self._stdout_pipe)
    close_handle(self._stderr_pipe)
    if not self._stdout_eof then
      self:_dispatch({ kind = "stdout_eof" })
    end
    self._stderr_eof = true
    self:_finish()
  end
end

function Client:_shutdown_stdin()
  if self._stdin_shutdown or self._stdin:is_closing() then
    return
  end
  self._stdin_shutdown = true
  local ok, request, err = pcall(self._stdin.shutdown, self._stdin, function(shutdown_error)
    close_handle(self._stdin)
    if shutdown_error and not self._exited and not self._failure then
      self:_enqueue({ kind = "error", message = "Pi RPC stdin shutdown failed: " .. tostring(shutdown_error) })
    end
  end)
  if not ok or not request then
    close_handle(self._stdin)
    if not self._exited then
      self:_enqueue({ kind = "error", message = "Pi RPC stdin shutdown failed: " .. tostring(ok and err or request) })
    end
  end
end

function Client:_pump()
  if self._writing or self._exited or self._stdin:is_closing() then
    return
  end
  local payload = self._writes[self._write_head]
  if not payload then
    if self._closing then
      self:_shutdown_stdin()
    end
    return
  end
  self._writing = true
  local ok, request, err = pcall(self._stdin.write, self._stdin, payload, function(write_error)
    self._writing = false
    if write_error then
      self:_enqueue({ kind = "error", message = "Pi RPC stdin write failed: " .. tostring(write_error) })
      return
    end
    self._writes[self._write_head] = false
    self._write_head = self._write_head + 1
    if self._write_head > #self._writes then
      self._writes = {}
      self._write_head = 1
    end
    self:_pump()
  end)
  if not ok or not request then
    self._writing = false
    local message = "Pi RPC stdin write failed: " .. tostring(ok and err or request)
    self:_enqueue({ kind = "error", message = message })
    return nil, message
  end
  return true
end

function Client:_begin_close(discard)
  if self._finished then
    return
  end
  self._closing = true
  if discard then
    self._writes = {}
    close_handle(self._stdin)
  else
    self:_pump()
  end
  if self._exited or self._close_timer then
    return
  end
  self._close_timer = uv.new_timer()
  self._close_timer:start(CLOSE_GRACE_MS, 0, function()
    if self._exited then
      return
    end
    close_handle(self._stdin)
    self._process:kill("sigterm")
    self._close_timer:start(TERMINATE_GRACE_MS, 0, function()
      if not self._exited then
        self._process:kill("sigkill")
      end
    end)
  end)
end

function Client:send(record)
  if self._failure or self._closing or self._exited then
    return false, self._failure or "Pi RPC client is closed"
  end
  if type(record) ~= "table" or type(record.type) ~= "string" then
    return false, "RPC record must be a table with a string type"
  end
  local ok, encoded = pcall(vim.json.encode, record)
  if not ok then
    return false, "Cannot encode pi RPC record: " .. tostring(encoded)
  end
  self._writes[#self._writes + 1] = encoded .. "\n"
  local _, err = self:_pump()
  if err then
    return false, err
  end
  return true
end

function Client:request(command, fields, callback)
  if type(command) ~= "string" or command == "" then
    return nil, "RPC command must be a nonempty string"
  end
  if fields ~= nil and type(fields) ~= "table" then
    return nil, "RPC command fields must be a table"
  end
  if callback ~= nil and type(callback) ~= "function" then
    return nil, "RPC request callback must be a function"
  end
  if self._failure or self._closing or self._exited then
    return nil, self._failure or "Pi RPC client is closed"
  end
  local record = {}
  for key, value in pairs(fields or {}) do
    record[key] = value
  end
  self._sequence = self._sequence + 1
  local sequence = self._sequence
  local id = "dyadic-" .. self._number .. "-" .. sequence
  record.id, record.type = id, command
  self._pending[sequence] = { callback = callback, command = command }
  self._ids[id] = sequence
  local sent, err = self:send(record)
  if not sent then
    self._pending[sequence] = nil
    self._ids[id] = nil
    return nil, err
  end
  return id
end

function Client:close()
  if self._closing or self._finished then
    return
  end
  self:_enqueue({ kind = "closed" })
  self:_begin_close(false)
end

function M.new(opts)
  if type(opts) ~= "table" or type(opts.cmd) ~= "table" or #opts.cmd == 0 then
    return nil, "Pi RPC cmd must be a nonempty argv array"
  end
  for _, argument in ipairs(opts.cmd) do
    if type(argument) ~= "string" or argument:find("\0", 1, true) then
      return nil, "Pi RPC argv entries must be strings without NUL bytes"
    end
  end
  if opts.cmd[1] == "" or type(opts.cwd) ~= "string" or opts.cwd == "" then
    return nil, "Pi RPC requires an executable and a working directory"
  end
  for _, name in ipairs({ "on_record", "on_exit", "on_stderr", "on_error" }) do
    if opts[name] ~= nil and type(opts[name]) ~= "function" then
      return nil, "Pi RPC " .. name .. " must be a function"
    end
  end
  next_client = next_client + 1
  local self = setmetatable({
    _opts = opts,
    _number = next_client,
    _sequence = 0,
    _pending = {},
    _ids = {},
    _events = {},
    _fragments = {},
    _writes = {},
    _write_head = 1,
    _stdin = uv.new_pipe(false),
    _stdout_pipe = uv.new_pipe(false),
    _stderr_pipe = uv.new_pipe(false),
  }, Client)
  local args = {}
  for index = 2, #opts.cmd do
    args[#args + 1] = opts.cmd[index]
  end
  local ok, process, pid = pcall(uv.spawn, opts.cmd[1], {
    args = args,
    cwd = opts.cwd,
    env = opts.env,
    stdio = { self._stdin, self._stdout_pipe, self._stderr_pipe },
  }, function(code, signal)
    self._exited = true
    close_handle(self._process)
    self:_enqueue({ kind = "exit", code = code, signal = signal })
  end)
  if not ok or not process then
    close_handle(self._stdin)
    close_handle(self._stdout_pipe)
    close_handle(self._stderr_pipe)
    return nil, "Cannot start pi RPC: " .. tostring(ok and pid or process)
  end
  self._process, self.pid = process, pid
  local function start_reader(pipe, kind)
    local read_ok, result, err = pcall(pipe.read_start, pipe, function(read_error, data)
      if read_error then
        self:_enqueue({ kind = "error", message = "Pi RPC " .. kind .. " read failed: " .. tostring(read_error) })
      end
      if data then
        self:_enqueue({ kind = kind, data = data })
      else
        close_handle(pipe)
        self:_enqueue({ kind = kind .. "_eof" })
      end
    end)
    if not read_ok or not result then
      close_handle(pipe)
      self:_enqueue({
        kind = "error",
        message = "Cannot read pi RPC " .. kind .. ": " .. tostring(read_ok and err or result),
      })
      self:_enqueue({ kind = kind .. "_eof" })
    end
  end
  start_reader(self._stdout_pipe, "stdout")
  start_reader(self._stderr_pipe, "stderr")
  return self
end

return M
