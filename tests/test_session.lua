local H = dofile("tests/helpers.lua")
local eq = H.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = child.setup,
    post_once = child.stop,
  },
})

T["starts idle and reports the model"] = function()
  child.open()
  eq(child.lua_get("_G.S.status"), "Idle")
  eq(child.lua_get("_G.S.state.model.id"), "fake-model")
end

T["submit sends a prompt and clears the draft"] = function()
  child.open()
  child.lua("_G.S:set_draft('hello'); _G.S:submit()")
  child.wait("#_G.S.messages == 2 and _G.S.status == 'Idle'")
  eq(child.draft(), "")
  eq(child.lua_get("_G.S.messages[2].content[1].text"), "echo: hello")
end

T["abort restores pi's queue into the draft"] = function()
  child.open()
  child.lua([[_G.S:request("test_set", { queue = { steering = { "one" }, followUp = { "two" } } })]])
  child.lua("_G.S:set_draft('draft'); _G.S:abort()")
  child.wait("_G.S:get_draft() ~= 'draft'")
  eq(child.draft(), "draft\n\none\n\ntwo")
end

T["status resyncs after a compaction pi started itself"] = function()
  child.open()
  child.lua([[_G.S:request("test_emit", { events = {
    { type = "compaction_start", reason = "threshold" },
    { type = "compaction_end", reason = "threshold", aborted = false, willRetry = false },
  } })]])
  child.wait("_G.S.status == 'Idle' and not _G.S.active")
end

T["notices go through vim.notify, not the transcript"] = function()
  child.open()
  child.lua("_G.S:set_draft('/session'); _G.S:submit()")
  child.wait("#_G.notes > 0")
  eq(child.lua_get("_G.notes[1].msg"):match("^Dyadic: Session: ") ~= nil, true)
  local text = table.concat(child.transcript(), "\n")
  eq(text:find("Session:", 1, true), nil)
end

T["a crash notifies once with the stderr log path"] = function()
  child.open()
  child.lua([[_G.S:request("test_crash", {}); _G.S:request("get_state", {})]])
  child.wait("_G.S.status:match('^Pi exited') ~= nil")
  child.settle()
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  local path = notes[1].msg:match("stderr log: (.+)$")
  eq(path ~= nil, true)
  eq(vim.fn.readfile(path), { "fake stack trace" })
  eq(child.lua_get("_G.S.status"), "Pi exited (code 3)")
end

-- Headless Neovim also checks timestamps on its own, so observe dyadic's checktime calls.
T["file-changing tools check only unmodified file buffers"] = function()
  child.open()
  local clean, dirty = vim.fn.tempname() .. "-clean.txt", vim.fn.tempname() .. "-dirty.txt"
  vim.fn.writefile({ "old" }, clean)
  vim.fn.writefile({ "old" }, dirty)
  child.lua(
    [[
    local clean, dirty = ...
    vim.cmd.edit(clean)
    vim.cmd.edit(dirty)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "mine" })
    _G.bufs = { vim.fn.bufnr(clean), vim.fn.bufnr(dirty) }
    _G.checked = {}
    local cmd = vim.cmd
    vim.cmd = setmetatable({}, {
      __index = cmd,
      __call = function(_, command)
        local buf = type(command) == "string" and command:match("^silent! checktime (%d+)$")
        if buf then
          table.insert(_G.checked, tonumber(buf))
        end
        return cmd(command)
      end,
    })
  ]],
    { clean, dirty }
  )
  local function emit(tool)
    child.lua(
      "_G.S:request('test_emit', { events = { { type = 'tool_execution_end', toolCallId = 'c', toolName = ... } } })",
      { tool }
    )
    child.settle(120)
  end
  emit("read")
  eq(child.lua_get("_G.checked"), {})
  emit("edit")
  local checked = child.lua_get("_G.checked")
  local bufs = child.lua_get("_G.bufs")
  eq(vim.tbl_contains(checked, bufs[1]), true)
  eq(vim.tbl_contains(checked, bufs[2]), false)
  -- Only file buffers are checked: never the transcript or draft.
  eq(vim.tbl_contains(checked, child.lua_get("_G.S.buf")), false)
end

T["an inherited NVIM is not passed to pi"] = function()
  child.lua("vim.env.NVIM = '/tmp/outer-nvim.sock'")
  child.open()
  eq(child.lua_get("_G.S.state._env_nvim"), vim.NIL)
end

T["closing ends the pi process"] = function()
  child.open()
  local pid = child.lua_get("_G.S.rpc.pid")
  child.lua("require('dyadic').command('close')")
  child.wait("_G.S.rpc._finished == true")
  eq(child.lua_get("vim.uv.kill(..., 0)", { pid }) == 0, false)
end

return T
