local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()

T("starts idle and reports the model", function()
  local s = H.open()
  eq(s.phase, "Idle")
  eq(s.state.model.id, "fake-model")
end)

T("submit sends a prompt and clears the draft", function()
  local s = H.open()
  s:set_draft("hello")
  s:submit()
  H.wait(function()
    return #s.messages == 2 and s.phase == "Idle"
  end)
  eq(s:get_draft(), "")
  eq(s.messages[2].content[1].text, "echo: hello")
end)

T("abort restores pi's queue into the draft", function()
  local s = H.open()
  H.request(s, "test_set", { queue = { steering = { "one" }, followUp = { "two" } } })
  s:set_draft("draft")
  s:abort()
  H.wait(function()
    return s:get_draft() ~= "draft"
  end)
  eq(s:get_draft(), "draft\n\none\n\ntwo")
end)

T("status resyncs after a compaction pi started itself", function()
  local s = H.open()
  H.emit(s, {
    { type = "compaction_start", reason = "threshold" },
    { type = "compaction_end", reason = "threshold", aborted = false, willRetry = false },
  })
  H.wait(function()
    return s.phase == "Idle" and not s.active
  end)
end)

T("notices go through vim.notify, not the transcript", function()
  local s = H.open()
  s:set_draft("/session")
  s:submit()
  H.wait(function()
    return #_G.notes > 0
  end)
  ok(_G.notes[1].msg:match("^Dyadic: Session: "), _G.notes[1].msg)
  eq(table.concat(H.transcript(s), "\n"):find("Session:", 1, true), nil)
end)

T("a crash notifies once with the stderr log path", function()
  local s = H.open()
  s:request("test_crash", {})
  s:request("get_state", {})
  H.wait(function()
    return s.phase:match("^Pi exited") ~= nil
  end)
  H.settle()
  eq(#_G.notes, 1)
  local path = _G.notes[1].msg:match("stderr log: (.+)$")
  ok(path, _G.notes[1].msg)
  eq(vim.fn.readfile(path), { "fake stack trace" })
  eq(s.phase, "Pi exited (code 3)")
end)

-- Headless Neovim also checks timestamps on its own, so observe dyadic's checktime calls.
T("file-changing tools check only unmodified file buffers", function()
  local s = H.open()
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
    H.emit(s, { { type = "tool_execution_end", toolCallId = "c", toolName = tool } })
    H.settle(120)
  end
  finish("read")
  eq(checked, {})
  finish("edit")
  ok(vim.tbl_contains(checked, clean_buf), "unmodified buffer was not checked")
  ok(not vim.tbl_contains(checked, dirty_buf), "modified buffer was checked")
  ok(not vim.tbl_contains(checked, s.buf), "transcript was checked")
end)

T("an inherited NVIM is not passed to pi", function()
  vim.env.NVIM = "/tmp/outer-nvim.sock"
  local s = H.open()
  eq(s.state._env_nvim, vim.NIL)
end)

T("closing ends the pi process", function()
  local s = H.open()
  local pid = s.rpc.pid
  require("dyadic").command("close")
  H.wait(function()
    return s.rpc._finished == true
  end)
  ok(vim.uv.kill(pid, 0) ~= 0, "pi is still running")
end)

return T
