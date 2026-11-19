-- Smoke test against the real pi without model calls. Run with DYADIC_REAL_PI=1.
local H = dofile("tests/helpers.lua")
local eq = H.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if vim.env.DYADIC_REAL_PI ~= "1" then
        MiniTest.skip("set DYADIC_REAL_PI=1 to run against the real pi")
      end
      child.setup()
    end,
    post_once = child.stop,
  },
})

T["starts, reports stats, and closes without leaving a process"] = function()
  child.lua([[
    require("dyadic").setup({ args = { "--no-session" } })
    _G.S = require("dyadic").open()
  ]])
  child.wait("_G.S.state.sessionId ~= nil and _G.S.phase == 'Idle'", 15000)
  child.lua("_G.S:set_draft('/session'); _G.S:submit()")
  child.wait("#_G.notes > 0", 5000)
  eq(child.lua_get("_G.notes[1].msg"):match("^Dyadic: Session: ") ~= nil, true)
  local pid = child.lua_get("_G.S.rpc.pid")
  child.lua("_G.S:close()")
  child.wait("_G.S.rpc._finished == true", 5000)
  eq(child.lua_get("vim.uv.kill(..., 0)", { pid }) == 0, false)
end

return T
