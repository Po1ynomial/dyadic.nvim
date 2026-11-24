local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local Bridge = require("dyadic.bridge")
local Commands = require("dyadic.commands")

local function prompts(log)
  local result = {}
  for _, record in ipairs(H.sent(log)) do
    if record.type == "prompt" then
      result[#result + 1] = record.message
    end
  end
  return result
end

local function messages()
  return vim.tbl_map(function(note)
    return note.msg
  end, _G.notes)
end

T("loads the bridge by default and hides its command", function()
  ok(vim.uv.fs_stat(Bridge.path()), Bridge.path())
  local agent = H.open()
  ok(Bridge.available(agent))
  eq(Bridge.args(agent.config), { "-e", Bridge.path() })
  eq(H.completions(agent, "/dy"), {})
  eq(messages(), {})
end)

T("bridge = false starts stock pi without warnings", function()
  local agent = H.open({}, { bridge = false })
  ok(not Bridge.available(agent))
  eq(messages(), {})
  agent:set_draft("/reload")
  agent:submit()
  H.settle()
  eq(agent:get_draft(), "/reload")
  ok(_G.notes[1].msg:find("/reload needs the bridge", 1, true), _G.notes[1].msg)
end)

T("warns once when pi does not load the bridge", function()
  local agent = H.open({ no_bridge = true })
  agent:refresh()
  H.settle(200)
  eq(#_G.notes, 1)
  ok(_G.notes[1].msg:find("The bridge did not load", 1, true), _G.notes[1].msg)
end)

T("/reload runs the bridge command and refreshes", function()
  local log = vim.fn.tempname()
  local agent = H.open({ log = log })
  local refreshed = false
  local refresh = agent.refresh
  agent.refresh = function(self, ...)
    refreshed = true
    return refresh(self, ...)
  end
  agent:set_draft("/reload")
  agent:submit()
  H.wait(function()
    return refreshed
  end, 3000, "refresh after reload")
  eq(agent:get_draft(), "")
  eq(prompts(log), { '/dyadic reload {"token":"1"}' })
  ok(messages()[1]:find("Reloaded", 1, true))
end)

T("/reload waits for the agent to finish", function()
  local log = vim.fn.tempname()
  local agent = H.open({ log = log })
  H.emit(agent, { { type = "agent_start" } })
  agent:set_draft("/reload")
  require("dyadic").action("reload")
  H.settle()
  eq(prompts(log), {})
  ok(messages()[1]:find("Wait for the agent", 1, true))
end)

return T
