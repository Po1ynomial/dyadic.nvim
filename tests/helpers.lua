-- Helpers for tests/run.lua. Tests run inside the case's own Neovim process.
local H = {}
H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- A suite is called as T(name, fn) to add a case; tests/run.lua reads T.cases in order.
function H.suite()
  return setmetatable({ cases = {} }, {
    __call = function(self, name, fn)
      table.insert(self.cases, { name = name, fn = fn })
    end,
  })
end

function H.eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%sexpected:\n%s\nactual:\n%s",
        message and (message .. "\n") or "",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function H.ok(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

function H.skip(reason)
  error("DYADIC_SKIP: " .. reason, 0)
end

function H.wait(condition, timeout, message)
  if not vim.wait(timeout or 3000, condition, 10) then
    error("timed out" .. (message and (": " .. message) or ""), 2)
  end
end

-- Let scheduled work, including the 25 ms render timer, run.
function H.settle(ms)
  vim.wait(ms or 80, function()
    return false
  end, 10)
end

-- Send a keystroke sequence as typed, with mappings.
function H.keys(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

-- Turn messages (or raw entries with a `type`) into a linked pi entry list e1, e2, ...
function H.chain(items)
  local entries = {}
  for index, item in ipairs(items) do
    local entry = item.type and vim.deepcopy(item) or { type = "message", message = vim.deepcopy(item) }
    entry.id = entry.id or ("e" .. index)
    entry.parentId = entries[index - 1] and entries[index - 1].id or nil
    entries[index] = entry
  end
  return entries
end

-- Configure dyadic to use tests/fakepi.lua with a scenario, open an agent, and wait
-- until it is idle. Scenario values must be plain Lua data.
function H.open(scenario, config)
  local path = vim.fn.tempname() .. "-dyadic-scenario.lua"
  vim.fn.writefile(vim.split("return " .. vim.inspect(scenario or {}), "\n"), path)
  config = config or {}
  config.cmd = { vim.v.progpath, "--clean", "-l", H.root .. "/tests/fakepi.lua", path }
  local dyadic = require("dyadic")
  dyadic.setup(config)
  local agent = dyadic.open()
  H.wait(function()
    return agent.state.sessionId ~= nil and agent.phase == "Idle"
  end, 3000, "agent to become idle")
  -- The startup refresh continues with stats and commands; wait for a complete one.
  local refreshed = false
  agent:refresh(function()
    refreshed = true
  end)
  H.wait(function()
    return refreshed
  end, 3000, "refresh")
  -- Keep row text independent of this machine's paths.
  agent.cwd = "/work"
  require("dyadic.view").render(agent)
  return agent
end

-- Send a request and wait for its response; events pi sent before it are handled by then.
function H.request(agent, kind, fields)
  local done, response_err, response_data = false, nil, nil
  agent:request(kind, fields or {}, function(err, data)
    done, response_err, response_data = true, err, data
  end)
  H.wait(function()
    return done
  end, 3000, kind .. " response")
  return response_err, response_data
end

function H.emit(agent, events)
  H.request(agent, "test_emit", { events = events })
end

function H.history(agent)
  return vim.api.nvim_buf_get_lines(agent.history_buf, 0, -1, false)
end

local function joined(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    parts[#parts + 1] = chunk[1]
  end
  return table.concat(parts)
end

-- Overlay rows as { line = 1-based, text = concatenated chunks, right = right-aligned text }.
function H.rows(agent)
  local out = {}
  for _, row in ipairs(agent._view.model.rows) do
    out[#out + 1] = { line = row.line + 1, text = joined(row.chunks), right = row.right and joined(row.right) or nil }
  end
  return out
end

function H.row_texts(agent)
  return vim.tbl_map(function(row)
    return row.text
  end, H.rows(agent))
end

function H.history_win(agent)
  return vim.fn.win_findbuf(agent.history_buf)[1]
end

-- Focus the history and put the cursor on the first row whose text matches.
function H.cursor_to_row(agent, pattern)
  for _, row in ipairs(H.rows(agent)) do
    if row.text:find(pattern) then
      local win = H.history_win(agent)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { row.line, 0 })
      return row.line
    end
  end
  error("no row matches " .. pattern, 2)
end

function H.current_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

-- Send a bridge request as the extension would and return dyadic's decoded answer. The
-- agent's scenario must log to `log`.
local bridge_ids = 0
function H.bridge_send(agent, payload)
  bridge_ids = bridge_ids + 1
  local id = "test-bridge-" .. bridge_ids
  H.emit(agent, {
    {
      type = "extension_ui_request",
      id = id,
      method = "input",
      title = "dyadic.bridge",
      placeholder = vim.json.encode(payload),
    },
  })
  return id
end

-- dyadic's decoded answer to bridge request `id`, or nil while it has not answered.
function H.bridge_answer(log, id)
  for _, record in ipairs(H.sent(log)) do
    if record.type == "extension_ui_response" and record.id == id then
      return vim.json.decode(record.value)
    end
  end
end

function H.bridge(agent, log, payload)
  local id = H.bridge_send(agent, payload)
  local answer
  H.wait(function()
    answer = H.bridge_answer(log, id)
    return answer ~= nil
  end, 3000, "the bridge answer")
  return answer
end

-- Requests dyadic sent to the fake pi, decoded from the scenario log.
function H.sent(log)
  local records = {}
  for _, line in ipairs(vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}) do
    records[#records + 1] = vim.json.decode(line)
  end
  return records
end

return H
