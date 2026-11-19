local H = dofile("tests/helpers.lua")
local eq = H.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = child.setup,
    post_once = child.stop,
  },
})

T["completes slash commands at the line start"] = function()
  child.open({ commands = { { name = "skill:review", source = "skill" } } })
  eq(child.lua_get("require('dyadic.commands').complete(_G.S, '/re')"), { "/resume" })
  eq(child.lua_get("require('dyadic.commands').complete(_G.S, '/sk')"), { "/skill:review" })
end

T["omnifunc completes absolute paths after the line start"] = function()
  child.open()
  child.lua([[
    require("dyadic").command("input")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "look at /us" })
    vim.api.nvim_win_set_cursor(0, { 1, 11 })
  ]])
  local start = child.lua_get("require('dyadic.view').complete(1, '')")
  eq(start, 8)
  eq(vim.tbl_contains(child.lua_get("require('dyadic.view').complete(0, '/us')"), "/usr/"), true)
end

T["unsupported TUI commands are rejected locally"] = function()
  child.open()
  child.lua("_G.S:set_draft('/tree'); _G.S:submit()")
  child.settle()
  eq(child.draft(), "/tree")
  eq(child.lua_get("#_G.S.messages"), 0)
end

T["focus actions work through the Lua API"] = function()
  child.open()
  child.lua("vim.api.nvim_set_current_win(vim.fn.win_findbuf(_G.S.buf)[1]); require('dyadic').action('focus_draft')")
  eq(child.lua_get("vim.api.nvim_get_current_buf() == _G.S.draft"), true)
  child.lua("require('dyadic').action('focus_transcript')")
  eq(child.lua_get("vim.api.nvim_get_current_buf() == _G.S.buf"), true)
end

return T
