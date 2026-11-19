local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local Commands = require("dyadic.commands")

T("completes slash commands at the line start", function()
  local agent = H.open({ commands = { { name = "skill:review", source = "skill" } } })
  eq(Commands.complete(agent, "/re"), { "/resume" })
  eq(Commands.complete(agent, "/sk"), { "/skill:review" })
end)

T("omnifunc completes absolute paths after the line start", function()
  H.open()
  local View = require("dyadic.view")
  require("dyadic").command("composer")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "look at /us" })
  vim.api.nvim_win_set_cursor(0, { 1, 11 })
  eq(View.complete(1, ""), 8)
  ok(vim.tbl_contains(View.complete(0, "/us"), "/usr/"))
end)

T("unsupported TUI commands are rejected locally", function()
  local agent = H.open()
  agent:set_draft("/tree")
  agent:submit()
  H.settle()
  eq(agent:get_draft(), "/tree")
  eq(#agent.messages, 0)
end)

T("/resume lists sessions for this cwd and rereads only changed files", function()
  local dir = vim.fn.tempname() .. "-sessions"
  vim.fn.mkdir(dir, "p")
  local function session(name, cwd, prompt)
    local path = dir .. "/" .. name .. ".jsonl"
    vim.fn.writefile({
      vim.json.encode({ type = "session", id = name, cwd = cwd, timestamp = "2026-01-01" }),
      vim.json.encode({ type = "message", id = "m", message = { role = "user", content = prompt } }),
    }, path)
    return path
  end
  local here = session("a", "/work", "first prompt")
  session("b", "/elsewhere", "other project")
  -- The active session's directory is authoritative, so keep the fake's file there too.
  H.open({ state = { sessionFile = here } }, { args = { "--session-dir", dir } })
  local opened, picked = 0, nil
  local open = vim.uv.fs_open
  vim.uv.fs_open = function(path, ...)
    if path:match("%.jsonl$") then
      opened = opened + 1
    end
    return open(path, ...)
  end
  vim.ui.select = function(items, opts)
    picked = vim.tbl_map(opts.format_item, items)
  end
  require("dyadic").command("resume")
  eq(#picked, 1)
  ok(picked[1]:match("^first prompt"), picked[1])
  eq(opened, 2)
  require("dyadic").command("resume")
  eq(opened, 2)
  vim.uv.fs_utime(here, os.time() + 60, os.time() + 60)
  require("dyadic").command("resume")
  eq(opened, 3)
end)

T("/hotkeys points to native mapping lists", function()
  local agent = H.open()
  agent:set_draft("/hotkeys")
  agent:submit()
  H.settle()
  ok(_G.notes[1].msg:find(":nmap <buffer>", 1, true), _G.notes[1].msg)
  eq(#agent.messages, 0)
  ok(not vim.tbl_contains(Commands.complete(agent, "/h"), "/hotkeys"))
end)

T("focus actions work through the Lua API", function()
  local agent = H.open()
  -- From any buffer, actions go to the last agent used.
  vim.cmd("tabnew")
  require("dyadic").action("focus_composer")
  eq(vim.api.nvim_get_current_buf(), agent.composer_buf)
  vim.api.nvim_set_current_win(H.history_win(agent))
  require("dyadic").action("focus_composer")
  eq(vim.api.nvim_get_current_buf(), agent.composer_buf)
  require("dyadic").action("focus_history")
  eq(vim.api.nvim_get_current_buf(), agent.history_buf)
end)

return T
