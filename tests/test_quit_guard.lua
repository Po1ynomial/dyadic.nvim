local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()

-- A quit that gets through would end this case as a pass; make it a failure instead.
-- Returns a function that allows the runner's own exit again.
local function forbid_exit()
  local id = vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      io.stderr:write("Neovim exited\n")
      os.exit(1)
    end,
  })
  return function()
    vim.api.nvim_del_autocmd(id)
  end
end

T("quitting is refused while an agent works, with a reason", function()
  local agent = H.open()
  local allow_exit = forbid_exit()
  H.emit(agent, { { type = "agent_start" } })
  H.settle()
  local main = require("dyadic.sidebar").main_window()
  vim.api.nvim_set_current_win(main)
  local quit, err = pcall(vim.cmd, "quit")
  eq(quit, false)
  ok(tostring(err):match("E37") or tostring(err):match("E162"), err)
  ok(_G.notes[#_G.notes].msg:find("pi is working in agent 1", 1, true), vim.inspect(_G.notes))
  -- After the refusal the sidebar and composer come back, and the cursor stays.
  H.settle()
  local Composer = require("dyadic.composer")
  eq(Composer.anchor(agent), require("dyadic.sidebar").window())
  eq(vim.api.nvim_get_current_win(), main)
  eq(pcall(vim.cmd, "qall"), false)
  -- ":wqall" "writes" the guard without an error, but Neovim stays.
  pcall(vim.cmd, "wqall")
  allow_exit()
end)

T(":q on a lone history and composer is refused and keeps the composer", function()
  local agent = H.open(nil, { placement = "free" })
  local allow_exit = forbid_exit()
  H.emit(agent, { { type = "agent_start" } })
  H.settle()
  local Composer = require("dyadic.composer")
  local anchor = Composer.anchor(agent)
  vim.api.nvim_set_current_win(anchor)
  eq(pcall(vim.cmd, "quit"), false)
  H.settle()
  eq(Composer.anchor(agent), anchor)
  allow_exit()
end)

T("the guard lifts when the agent settles", function()
  local agent = H.open()
  H.emit(agent, { { type = "agent_start" } })
  H.settle()
  eq(#vim.fn.getbufinfo({ bufmodified = 1 }), 1)
  H.emit(agent, { { type = "agent_settled", aborted = false } })
  H.wait(function()
    return not agent.active
  end)
  H.settle()
  eq(#vim.fn.getbufinfo({ bufmodified = 1 }), 0)
end)

T("a closed agent does not hold the guard", function()
  local agent = H.open()
  H.emit(agent, { { type = "agent_start" } })
  H.settle()
  agent:close()
  eq(#vim.fn.getbufinfo({ bufmodified = 1 }), 0)
end)

return T
