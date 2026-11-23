local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local Tokens = require("dyadic.tokens")

local function project()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir .. "/lua", "p")
  vim.fn.writefile({ "return 1" }, dir .. "/lua/a.lua")
  vim.fn.writefile({ "# title" }, dir .. "/my file.md")
  return dir
end

local function lead(agent, lines)
  agent:set_draft(table.concat(lines, "\n"))
  return Tokens.lead(agent, agent.composer_buf)
end

T("the draft's start is highlighted when it runs a command or shell command", function()
  local agent = H.open({ commands = { { name = "llama", source = "extension" } } })
  eq(lead(agent, { "/model sonnet" }), { 0, 0, 6, "DyadicCommand" })
  -- Commands are read from the trimmed draft, as dyadic and pi read them.
  eq(lead(agent, { "", "  /new" }), { 1, 2, 6, "DyadicCommand" })
  eq(lead(agent, { "/llama" }), { 0, 0, 6, "DyadicCommand" })
  -- Not a command: plain text for the model; the bridge's command is not for typing.
  eq(lead(agent, { "/foo bar" }), nil)
  eq(lead(agent, { "/dyadic tree" }), nil)
  eq(lead(agent, { "/mo" }), nil)
  eq(lead(agent, { "say /model" }), nil)
  eq(lead(agent, { "!ls" }), { 0, 0, 1, "DyadicShell" })
  eq(lead(agent, { "!!git status" }), { 0, 0, 2, "DyadicShell" })
  eq(lead(agent, { "!!", "ls" }), { 0, 0, 2, "DyadicShell" })
  -- An empty shell command does not run.
  eq(lead(agent, { "!  " }), nil)
end)

T("@paths are highlighted when they name something", function()
  local agent = H.open()
  agent.cwd = project()
  eq(Tokens.references(agent, "see @lua/a.lua."), { { 4, 14 } })
  eq(Tokens.references(agent, "@lua/a.lua) and @lua/"), { { 0, 10 }, { 16, 21 } })
  -- At the start of a word only, as completion has it.
  eq(Tokens.references(agent, "(@lua/a.lua)"), {})
  eq(Tokens.references(agent, 'read @"my file.md", then'), { { 5, 18 } })
  eq(Tokens.references(agent, "@missing.lua a@lua/a.lua @"), {})
  eq(Tokens.references(agent, "@" .. agent.cwd .. "/lua/a.lua"), { { 0, #agent.cwd + 11 } })
  local home = vim.fn.fnamemodify(agent.cwd, ":~")
  if home:sub(1, 1) == "~" then
    eq(Tokens.references(agent, "@" .. home .. "/lua"), { { 0, #home + 5 } })
  end
end)

-- The foreground colour drawn at a draft position, 1-based.
local function drawn(agent, lnum, col)
  vim.cmd("redraw!")
  local win = vim.fn.win_findbuf(agent.composer_buf)[1]
  local pos = vim.fn.screenpos(win, lnum, col)
  ok(pos.row > 0, "position on screen")
  return vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].foreground
end

T("the composer draws them, except inside Markdown code", function()
  local agent = H.open()
  agent.cwd = project()
  vim.api.nvim_set_hl(0, "DyadicCommand", { fg = 0xff0000 })
  vim.api.nvim_set_hl(0, "DyadicReference", { fg = 0x0000ff })
  vim.api.nvim_set_hl(0, "DyadicShell", { fg = 0x00ff00 })
  agent:set_draft(table.concat({
    "/compact keep @lua/a.lua",
    "not `@lua/a.lua` here",
    "```",
    "@lua/a.lua",
    "```",
    "/model",
  }, "\n"))
  eq(drawn(agent, 1, 2), 0xff0000)
  ok(drawn(agent, 1, 10) ~= 0xff0000, "the argument is plain")
  eq(drawn(agent, 1, 16), 0x0000ff)
  ok(drawn(agent, 2, 7) ~= 0x0000ff, "inline code is skipped")
  ok(drawn(agent, 4, 2) ~= 0x0000ff, "fenced code is skipped")
  -- Only the draft's start runs.
  ok(drawn(agent, 6, 2) ~= 0xff0000, "a later /model is prose")
  -- The highlights follow edits.
  agent:set_draft("!!ls @lua/a.lua")
  eq(drawn(agent, 1, 1), 0x00ff00)
  eq(drawn(agent, 1, 2), 0x00ff00)
  ok(drawn(agent, 1, 3) ~= 0x00ff00, "the shell command is plain")
  eq(drawn(agent, 1, 6), 0x0000ff)
end)

return T
