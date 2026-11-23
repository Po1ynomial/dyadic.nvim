local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local Commands = require("dyadic.commands")

T("built-in commands leave the composer as they run and come back when they fail", function()
  local agent = H.open({ fail = { compact = "compact boom" } })
  agent:set_draft("/session")
  agent:submit()
  eq(agent:get_draft(), "")
  H.wait(function()
    return vim.iter(_G.notes):any(function(note)
      return note.msg:find("Dyadic: Session:", 1, true) ~= nil
    end)
  end, 3000, "the session notice")
  agent:set_draft("/compact now")
  agent:submit()
  eq(agent:get_draft(), "")
  H.wait(function()
    return agent:get_draft() == "/compact now"
  end, 3000, "the failed command to come back")
  -- What was typed meanwhile stays.
  agent:submit()
  agent:set_draft("typed")
  H.settle(200)
  eq(agent:get_draft(), "typed")
  -- A refusal keeps the text to fix; a failure found later brings it back.
  agent:set_draft("/new now")
  agent:submit()
  eq(agent:get_draft(), "/new now")
  agent:set_draft("/thinking bogus")
  agent:submit()
  eq(agent:get_draft(), "")
  H.wait(function()
    return agent:get_draft() == "/thinking bogus"
  end, 3000, "the unavailable level to come back")
end)

T("unsupported TUI commands are rejected locally", function()
  local agent = H.open()
  agent:set_draft("/login")
  agent:submit()
  H.settle()
  eq(agent:get_draft(), "/login")
  eq(#agent.messages, 0)
end)

T("TUI-only names that pi lists as commands are forwarded", function()
  local log = vim.fn.tempname()
  local agent = H.open({ log = log, commands = { { name = "llama", source = "extension" } } })
  agent:set_draft("/llama")
  agent:submit()
  H.wait(function()
    return vim.iter(H.sent(log)):any(function(record)
      return record.type == "prompt" and record.message == "/llama"
    end)
  end, 3000, "the /llama prompt")
  H.wait(function()
    return agent:get_draft() == ""
  end, 3000, "the draft to clear")
end)

T(":Dyadic reports unknown subcommands", function()
  local log = vim.fn.tempname()
  H.open({ log = log, commands = { { name = "handoff", source = "extension" } } })
  require("dyadic").command("modle")
  require("dyadic").command("handoff")
  H.settle()
  eq(
    vim.tbl_map(function(note)
      return note.msg
    end, _G.notes),
    { "Dyadic: unknown command modle", "Dyadic: unknown command handoff" }
  )
  ok(not vim.iter(H.sent(log)):any(function(record)
    return record.type == "prompt"
  end))
end)

T("/hotkeys points to native mapping lists", function()
  local agent = H.open()
  agent:set_draft("/hotkeys")
  agent:submit()
  H.settle()
  ok(_G.notes[1].msg:find(":nmap <buffer>", 1, true), _G.notes[1].msg)
  eq(#agent.messages, 0)
  ok(not vim.tbl_contains(H.completions(agent, "/h"), "/hotkeys"))
end)

T(":Dyadic composer focuses the last agent's composer from anywhere", function()
  local agent = H.open()
  vim.cmd("tabnew")
  require("dyadic").command("composer")
  eq(vim.api.nvim_get_current_buf(), agent.composer_buf)
  vim.api.nvim_set_current_win(H.history_win(agent))
  require("dyadic").command("composer")
  eq(vim.api.nvim_get_current_buf(), agent.composer_buf)
end)

T("focus actions are gone; window commands move within the pair", function()
  local agent = H.open()
  for _, name in ipairs({ "focus_composer", "focus_history" }) do
    eq(require("dyadic.view").actions[name], nil, name)
    eq(vim.fn.maparg("<localleader>i", "n", false, true).buffer, nil, name)
  end
  eq(vim.fn.maparg("<localleader>s", "n"), "")
  vim.api.nvim_set_current_win(H.history_win(agent))
  vim.cmd("wincmd j")
  eq(vim.api.nvim_get_current_buf(), agent.composer_buf)
  vim.cmd("wincmd k")
  eq(vim.api.nvim_get_current_buf(), agent.history_buf)
end)

return T
