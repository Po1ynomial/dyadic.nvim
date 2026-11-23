local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()

T("starts idle and reports the model", function()
  local agent = H.open()
  eq(agent.phase, "Idle")
  eq(agent.state.model.id, "fake-model")
end)

T("submit sends a prompt and clears the draft", function()
  local agent = H.open()
  agent:set_draft("hello")
  agent:submit()
  H.wait(function()
    return #agent.messages == 2 and agent.phase == "Idle"
  end)
  eq(agent:get_draft(), "")
  eq(agent.messages[2].content[1].text, "echo: hello")
end)

T("abort restores pi's queue into the draft", function()
  local agent = H.open()
  H.request(agent, "test_set", { queue = { steering = { "one" }, followUp = { "two" } } })
  agent:set_draft("draft")
  agent:abort()
  H.wait(function()
    return agent:get_draft() ~= "draft"
  end)
  eq(agent:get_draft(), "draft\n\none\n\ntwo")
end)

T("status resyncs after a compaction pi started itself", function()
  local agent = H.open()
  H.emit(agent, {
    { type = "compaction_start", reason = "threshold" },
    { type = "compaction_end", reason = "threshold", aborted = false, willRetry = false },
  })
  H.wait(function()
    return agent.phase == "Idle" and not agent.active
  end)
end)

T("the agent's directory follows a resumed session's", function()
  local agent = H.open()
  local file = vim.fn.tempname() .. ".jsonl"
  vim.fn.writefile({ vim.json.encode({ type = "session", id = "s2", cwd = "/elsewhere" }) }, file)
  H.request(agent, "test_set", { state = { sessionId = "s2", sessionFile = file } })
  local done = false
  agent:refresh(function()
    done = true
  end)
  H.wait(function()
    return done
  end)
  eq(agent.cwd, "/elsewhere")
  -- A new session has no file yet and keeps the directory.
  H.request(agent, "test_set", { state = { sessionId = "s3", sessionFile = file .. ".new" } })
  done = false
  agent:refresh(function()
    done = true
  end)
  H.wait(function()
    return done
  end)
  eq(agent.cwd, "/elsewhere")
end)

T("notices go through vim.notify, not the history", function()
  local agent = H.open()
  agent:set_draft("/session")
  agent:submit()
  H.wait(function()
    return #_G.notes > 0
  end)
  ok(_G.notes[1].msg:match("^Dyadic: Session: "), _G.notes[1].msg)
  eq(table.concat(H.history(agent), "\n"):find("Session:", 1, true), nil)
end)

T("a crash notifies once with the stderr log path", function()
  local agent = H.open()
  agent:request("test_crash", {})
  agent:request("get_state", {})
  H.wait(function()
    return agent.phase:match("^Pi exited") ~= nil
  end)
  H.settle()
  eq(#_G.notes, 1)
  local path = _G.notes[1].msg:match("stderr log: (.+)$")
  ok(path, _G.notes[1].msg)
  eq(vim.fn.readfile(path), { "fake stack trace" })
  eq(agent.phase, "Pi exited (code 3)")
end)

T("a crash during the startup refresh notifies once", function()
  local dyadic = require("dyadic")
  dyadic.setup({ cmd = { vim.v.progpath, "--clean", "-l", H.root .. "/tests/fakepi.lua" } })
  local agent = dyadic.open()
  H.wait(function()
    return agent.phase == "Idle"
  end)
  -- Stats and commands are still pending; the chain would continue on a dead process.
  agent:request("test_crash", {})
  H.wait(function()
    return agent.phase:match("^Pi exited") ~= nil
  end)
  H.settle()
  eq(#_G.notes, 1, vim.inspect(_G.notes))
end)

-- Headless Neovim also checks timestamps on its own, so observe dyadic's checktime calls.
T("file-changing tools check only unmodified file buffers", function()
  local agent = H.open()
  -- Files open in their own tab; the composer window refuses other buffers.
  vim.cmd.tabnew()
  local clean, dirty = vim.fn.tempname() .. "-clean.txt", vim.fn.tempname() .. "-dirty.txt"
  vim.fn.writefile({ "old" }, clean)
  vim.fn.writefile({ "old" }, dirty)
  vim.cmd.edit(clean)
  local clean_buf = vim.api.nvim_get_current_buf()
  vim.cmd.edit(dirty)
  local dirty_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(dirty_buf, 0, -1, false, { "mine" })
  local checked = {}
  local command = vim.api.nvim_command
  vim.api.nvim_command = function(text)
    local buf = text:match("^silent! checktime (%d+)$")
    if buf then
      checked[#checked + 1] = tonumber(buf)
    end
    return command(text)
  end
  local function finish(tool)
    H.emit(agent, { { type = "tool_execution_end", toolCallId = "c", toolName = tool } })
    H.settle(120)
  end
  finish("read")
  eq(checked, {})
  finish("edit")
  ok(vim.tbl_contains(checked, clean_buf), "unmodified buffer was not checked")
  ok(not vim.tbl_contains(checked, dirty_buf), "modified buffer was checked")
  ok(not vim.tbl_contains(checked, agent.history_buf), "history was checked")
end)

T("an inherited NVIM is not passed to pi", function()
  vim.env.NVIM = "/tmp/outer-nvim.sock"
  local agent = H.open()
  eq(agent.state._env_nvim, vim.NIL)
end)

T("closing ends the pi process", function()
  local agent = H.open()
  local pid = agent.rpc.pid
  require("dyadic").command("close")
  H.wait(function()
    return agent.rpc._finished == true
  end)
  ok(vim.uv.kill(pid, 0) ~= 0, "pi is still running")
end)

-- The history and composer are unlisted, so these never fire BufDelete.
for _, where in ipairs({ "history", "composer" }) do
  for _, command in ipairs({ "bd", "bd!", "bunload", "bwipeout", "%bd", "bd N" }) do
    T(":" .. command .. " on the " .. where .. " ends the agent", function()
      local agent = H.open()
      local Composer = require("dyadic.composer")
      local buf = where == "history" and agent.history_buf or agent.composer_buf
      local pid = agent.rpc.pid
      if command == "bd N" then
        vim.cmd("vnew")
        H.settle()
        vim.cmd("bd " .. buf)
      else
        vim.api.nvim_set_current_win(where == "history" and Composer.anchor(agent) or Composer.window(agent))
        vim.cmd(command)
      end
      H.wait(function()
        return agent.closed and agent.rpc._finished == true
      end, 3000, "the agent to end")
      ok(vim.uv.kill(pid, 0) ~= 0, "pi is still running")
      eq(vim.api.nvim_buf_is_valid(agent.history_buf), false)
      eq(vim.api.nvim_buf_is_valid(agent.composer_buf), false)
      eq(require("dyadic").list(), {})
    end)
  end
end

T(":e reloads the history and composer and keeps the agent", function()
  local agent = H.open({
    entries = H.chain({
      { role = "user", content = "question", timestamp = 1 },
      { role = "assistant", content = { { type = "text", text = "line one\n\nline two" } }, timestamp = 2 },
    }),
  })
  agent:set_draft("draft\ntext")
  H.settle()
  local Composer = require("dyadic.composer")
  local function snapshot(buf)
    return {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      marks = #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}),
      highlighted = vim.treesitter.highlighter.active[buf] ~= nil,
    }
  end
  for _, where in ipairs({ "history", "composer" }) do
    local buf = where == "history" and agent.history_buf or agent.composer_buf
    local before = snapshot(buf)
    vim.api.nvim_set_current_win(where == "history" and Composer.anchor(agent) or Composer.window(agent))
    for _, command in ipairs({ "e", "e!" }) do
      vim.cmd(command)
      H.settle()
      eq(agent.closed, false, where .. " " .. command)
      eq(snapshot(buf), before, where .. " " .. command)
    end
  end
  eq(agent:get_draft(), "draft\ntext")
  eq(H.row_texts(agent), { "▍ You", "▍ Assistant" })
end)

return T
