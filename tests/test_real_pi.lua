-- Smoke test against the real pi without model calls. Run with DYADIC_REAL_PI=1.
local H = dofile("tests/helpers.lua")
local ok = H.ok
local T = H.suite()

T("starts, reports stats, and closes without leaving a process", function()
  if vim.env.DYADIC_REAL_PI ~= "1" then
    H.skip("set DYADIC_REAL_PI=1 to run against the real pi")
  end
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
  local pid = agent.rpc.pid
  agent:close()
  H.wait(function()
    return agent.rpc._finished == true
  end, 5000, "pi to exit")
  ok(vim.uv.kill(pid, 0) ~= 0, "pi is still running")
end)

return T
