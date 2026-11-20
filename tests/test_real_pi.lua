-- Smoke test against the real pi without model calls. Run with DYADIC_REAL_PI=1.
local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()

local function require_real_pi()
  if vim.env.DYADIC_REAL_PI ~= "1" then
    H.skip("set DYADIC_REAL_PI=1 to run against the real pi")
  end
end

-- A saved session with two branches, e1 -> e2 -> {e3 -> e4, e5 -> e6}, leaf e6.
local function session_file()
  local dir = vim.fn.tempname() .. "-dyadic-real"
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/tree.jsonl"
  local time = "2026-01-01T00:00:00.000Z"
  local function user(id, parent, text)
    return {
      type = "message",
      id = id,
      parentId = parent or vim.NIL,
      timestamp = time,
      message = { role = "user", content = { { type = "text", text = text } }, timestamp = 1 },
    }
  end
  local function assistant(id, parent, text)
    return {
      type = "message",
      id = id,
      parentId = parent,
      timestamp = time,
      message = {
        role = "assistant",
        content = { { type = "text", text = text } },
        api = "openai-completions",
        provider = "fake",
        model = "fake",
        usage = {
          input = 0,
          output = 0,
          cacheRead = 0,
          cacheWrite = 0,
          totalTokens = 0,
          cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
        },
        stopReason = "stop",
        timestamp = 2,
      },
    }
  end
  local records = {
    { type = "session", version = 3, id = "dyadic-real-tree", timestamp = time, cwd = vim.fn.getcwd() },
    user("e1", nil, "first"),
    assistant("e2", "e1", "answer one"),
    user("e3", "e2", "second"),
    assistant("e4", "e3", "answer two"),
    user("e5", "e2", "alt second"),
    assistant("e6", "e5", "alt answer"),
  }
  vim.fn.writefile(vim.tbl_map(vim.json.encode, records), path)
  return path, dir
end

T("starts with the bridge, reports stats, reloads, and closes without leaving a process", function()
  require_real_pi()
  local dyadic = require("dyadic")
  dyadic.setup({ args = { "--no-session" } })
  local agent = dyadic.open()
  H.wait(function()
    return agent.state.sessionId ~= nil and agent.phase == "Idle"
  end, 15000, "pi to start")
  agent:set_draft("/session")
  agent:submit()
  H.wait(function()
    return #_G.notes > 0
  end, 5000, "session stats")
  ok(_G.notes[1].msg:match("^Dyadic: Session: "), _G.notes[1].msg)
  H.wait(function()
    return require("dyadic.bridge").available(agent)
  end, 5000, "the bridge to load")
  agent:set_draft("/reload")
  agent:submit()
  H.wait(function()
    return #_G.notes > 1
  end, 15000, "reload")
  ok(_G.notes[2].msg:match("^Dyadic: Reloaded"), _G.notes[2].msg)
  H.wait(function()
    return require("dyadic.bridge").available(agent)
  end, 5000, "the bridge after reload")
  local pid = agent.rpc.pid
  agent:close()
  H.wait(function()
    return agent.rpc._finished == true
  end, 5000, "pi to exit")
  ok(vim.uv.kill(pid, 0) ~= 0, "pi is still running")
end)

T("moves within the tree and labels entries through the bridge", function()
  require_real_pi()
  local path, dir = session_file()
  local dyadic = require("dyadic")
  dyadic.setup({ args = { "--session", path, "--session-dir", dir } })
  local agent = dyadic.open()
  H.wait(function()
    return require("dyadic.bridge").available(agent) and #agent.messages == 4
  end, 15000, "pi to load the session")
  local Picker = require("dyadic.tree_picker")
  agent:set_draft("/tree")
  agent:submit()
  H.wait(function()
    return Picker.current() ~= nil
  end, 5000, "the picker")
  local p = Picker.current()
  eq(#vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false), 6)
  -- Label the leaf, then go to the other branch's user message without a summary.
  vim.ui.input = function(_, on_confirm)
    on_confirm("checkpoint")
  end
  H.keys("m")
  H.wait(function()
    return vim.api.nvim_buf_get_lines(p.list_buf, 3, 4, false)[1]:find("[checkpoint]", 1, true) ~= nil
  end, 5000, "the label")
  vim.api.nvim_win_set_cursor(p.list_win, { 5, 0 })
  H.keys("<C-CR>")
  H.wait(function()
    return agent:get_draft() == "second" and #agent.messages == 2
  end, 5000, "the move")
  local _, data = H.request(agent, "get_entries", {})
  local by_id = {}
  for _, entry in ipairs(data.entries) do
    by_id[entry.id] = entry
  end
  -- Other extensions may append custom entries after a move; the last message is e2.
  local leaf = by_id[data.leafId]
  while leaf and leaf.type ~= "message" do
    leaf = by_id[leaf.parentId]
  end
  eq(leaf and leaf.id, "e2")
  agent:close()
end)

return T
