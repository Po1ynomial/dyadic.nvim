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

T["closing ends the pi process"] = function()
  child.open()
  local pid = child.lua_get("_G.S.rpc.pid")
  child.lua("require('dyadic').command('close')")
  child.wait("_G.S.rpc._finished == true")
  eq(child.lua_get("vim.uv.kill(..., 0)", { pid }) == 0, false)
end

return T
