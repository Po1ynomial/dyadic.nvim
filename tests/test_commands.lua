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

T["/resume lists sessions for this cwd and rereads only changed files"] = function()
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
  child.open({ state = { sessionFile = here } }, { args = { "--session-dir", dir } })
  child.lua([[
    _G.opened = 0
    local open = vim.uv.fs_open
    vim.uv.fs_open = function(path, ...)
      if path:match("%.jsonl$") then
        _G.opened = _G.opened + 1
      end
      return open(path, ...)
    end
    vim.ui.select = function(items, opts)
      _G.picked = vim.tbl_map(opts.format_item, items)
    end
  ]])
  child.lua("require('dyadic').command('resume')")
  eq(#child.lua_get("_G.picked"), 1)
  eq(child.lua_get("_G.picked[1]"):match("^first prompt") ~= nil, true)
  eq(child.lua_get("_G.opened"), 2)
  child.lua("require('dyadic').command('resume')")
  eq(child.lua_get("_G.opened"), 2)
  vim.uv.fs_utime(here, os.time() + 60, os.time() + 60)
  child.lua("require('dyadic').command('resume')")
  eq(child.lua_get("_G.opened"), 3)
end

T["/hotkeys points to native mapping lists"] = function()
  child.open()
  child.lua("_G.S:set_draft('/hotkeys'); _G.S:submit()")
  child.settle()
  eq(child.lua_get("_G.notes[1].msg"):find(":nmap <buffer>", 1, true) ~= nil, true)
  eq(child.lua_get("#_G.S.messages"), 0)
  eq(vim.tbl_contains(child.lua_get("require('dyadic.commands').complete(_G.S, '/h')"), "/hotkeys"), false)
end

T["focus actions work through the Lua API"] = function()
  child.open()
  child.lua("vim.api.nvim_set_current_win(vim.fn.win_findbuf(_G.S.buf)[1]); require('dyadic').action('focus_draft')")
  eq(child.lua_get("vim.api.nvim_get_current_buf() == _G.S.draft"), true)
  child.lua("require('dyadic').action('focus_transcript')")
  eq(child.lua_get("vim.api.nvim_get_current_buf() == _G.S.buf"), true)
end

return T
