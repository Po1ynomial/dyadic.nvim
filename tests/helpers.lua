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

-- Configure dyadic to use tests/fakepi.lua with a scenario, open a conversation, and wait
-- until it is idle. Scenario values must be plain Lua data.
function H.open(scenario, config)
  local path = vim.fn.tempname() .. "-dyadic-scenario.lua"
  vim.fn.writefile(vim.split("return " .. vim.inspect(scenario or {}), "\n"), path)
  config = config or {}
  config.cmd = { vim.v.progpath, "--clean", "-l", H.root .. "/tests/fakepi.lua", path }
  local dyadic = require("dyadic")
  dyadic.setup(config)
  local s = dyadic.open()
  H.wait(function()
    return s.state.sessionId ~= nil and s.phase == "Idle"
  end, 3000, "conversation to become idle")
  -- The startup refresh continues with stats and commands; wait for a complete one.
  local refreshed = false
  s:refresh(function()
    refreshed = true
  end)
  H.wait(function()
    return refreshed
  end, 3000, "refresh")
  -- Keep row text independent of this machine's paths.
  s.cwd = "/work"
  require("dyadic.view").render(s)
  return s
end

-- Send a request and wait for its response; events pi sent before it are handled by then.
function H.request(s, kind, fields)
  local done, response_err, response_data = false, nil, nil
  s:request(kind, fields or {}, function(err, data)
    done, response_err, response_data = true, err, data
  end)
  H.wait(function()
    return done
  end, 3000, kind .. " response")
  return response_err, response_data
end

function H.emit(s, events)
  H.request(s, "test_emit", { events = events })
end

function H.transcript(s)
  return vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
end

-- Overlay rows as { line = 1-based, text = concatenated chunks }.
function H.rows(s)
  local out = {}
  for _, row in ipairs(s._view.model.rows) do
    local parts = {}
    for _, chunk in ipairs(row.chunks) do
      parts[#parts + 1] = chunk[1]
    end
    out[#out + 1] = { line = row.line + 1, text = table.concat(parts) }
  end
  return out
end

function H.row_texts(s)
  return vim.tbl_map(function(row)
    return row.text
  end, H.rows(s))
end

function H.transcript_win(s)
  return vim.fn.win_findbuf(s.buf)[1]
end

-- Focus the transcript and put the cursor on the first row whose text matches.
function H.cursor_to_row(s, pattern)
  for _, row in ipairs(H.rows(s)) do
    if row.text:find(pattern) then
      local win = H.transcript_win(s)
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

-- Requests dyadic sent to the fake pi, decoded from the scenario log.
function H.sent(log)
  local records = {}
  for _, line in ipairs(vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}) do
    records[#records + 1] = vim.json.decode(line)
  end
  return records
end

return H
