local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local api = vim.api
local Composer = require("dyadic.composer")
local Picker = require("dyadic.tree_picker")
local Sidebar = require("dyadic.sidebar")

-- A file in the main area, so :bprevious from a dyadic window has somewhere to go.
local function file_in_main()
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "x" }, path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return api.nvim_get_current_buf(), api.nvim_get_current_win()
end

local function refused(cmd)
  local done, err = pcall(vim.cmd, cmd)
  eq(done, false, cmd .. " should fail")
  ok(tostring(err):find("E1513", 1, true), err)
end

local function open_picker()
  local agent = H.open({ entries = H.chain({ { role = "user", content = "hi" } }) })
  agent:set_draft("/tree")
  agent:submit()
  H.wait(function()
    return Picker.current() ~= nil
  end, 3000, "the picker")
  return agent, Picker.current()
end

T("the tree picker refuses buffer switches", function()
  file_in_main()
  local _, p = open_picker()
  eq(api.nvim_get_current_win(), p.list_win)
  for _, cmd in ipairs({ "bprevious", "bnext", "buffer #", "enew", "normal [b", 'execute "normal! \\<C-^>"' }) do
    refused(cmd)
  end
  H.settle()
  eq(api.nvim_win_get_buf(p.list_win), p.list_buf)
  eq(Picker.current(), p)
end)

T("a forced switch in the tree picker opens the buffer in the main area and closes the picker", function()
  for _, part in ipairs({ "list", "bar" }) do
    local file, main = file_in_main()
    local _, p = open_picker()
    api.nvim_set_current_win(p[part .. "_win"])
    vim.cmd("buffer! " .. file)
    H.settle()
    eq(Picker.current(), nil, part)
    ok(not api.nvim_win_is_valid(p.list_win) and not api.nvim_win_is_valid(p.bar_win), part)
    eq(api.nvim_get_current_win(), main, part)
    eq(api.nvim_win_get_buf(main), file, part)
    require("dyadic").shutdown()
    H.settle()
  end
end)

T("a forced switch in the detail float closes it and opens the buffer in the main area", function()
  local file, main = file_in_main()
  local agent = H.open({
    entries = H.chain({
      { role = "user", content = "look", timestamp = 1 },
      {
        role = "assistant",
        model = "m",
        timestamp = 2,
        content = { { type = "toolCall", id = "c1", name = "read", arguments = { path = "a.lua" } } },
      },
      { role = "toolResult", toolCallId = "c1", toolName = "read", content = { { type = "text", text = "1" } } },
    }),
  })
  H.settle()
  H.cursor_to_row(agent, "1 tool")
  H.keys("za")
  H.cursor_to_row(agent, "read a.lua")
  H.keys("K")
  local detail = api.nvim_get_current_win()
  ok(api.nvim_buf_get_name(0):match("/detail/"))
  refused("bprevious")
  vim.cmd("bprevious!")
  H.settle()
  ok(not api.nvim_win_is_valid(detail))
  eq(api.nvim_get_current_win(), main)
  eq(api.nvim_win_get_buf(main), file)
end)

T("a forced switch in the extension editor cancels it and opens the buffer in the main area", function()
  local log = vim.fn.tempname()
  local file, main = file_in_main()
  local agent = H.open({ log = log })
  H.emit(agent, { { type = "extension_ui_request", id = "ed1", method = "editor", title = "Edit", prefill = "x" } })
  H.wait(function()
    return api.nvim_buf_get_name(0):match("/editor/ed1$") ~= nil
  end, 3000, "the editor float")
  local editor = api.nvim_get_current_win()
  refused("bprevious")
  vim.cmd("bprevious!")
  H.settle()
  ok(not api.nvim_win_is_valid(editor))
  eq(api.nvim_get_current_win(), main)
  eq(api.nvim_win_get_buf(main), file)
  local answered = vim.tbl_filter(function(record)
    return record.type == "extension_ui_response" and record.id == "ed1"
  end, H.sent(log))
  eq(#answered, 1)
  eq(answered[1].cancelled, true)
end)

T("a forced switch in the sidebar or composer is undone and opens the buffer in the main area", function()
  local file, main = file_in_main()
  local agent = H.open()
  for _, which in ipairs({ "sidebar", "composer" }) do
    local win = which == "sidebar" and Sidebar.window() or Composer.window(agent)
    local own = which == "sidebar" and agent.history_buf or agent.composer_buf
    api.nvim_set_current_win(win)
    refused("bprevious")
    vim.cmd("bprevious!")
    H.settle()
    eq(api.nvim_win_get_buf(win), own, which)
    eq(vim.wo[win].winfixbuf, true, which)
    eq(Composer.anchor(agent), Sidebar.window(), which)
    eq(Composer.window(agent) ~= nil, true, which)
    eq(api.nvim_get_current_win(), main, which)
    eq(api.nvim_win_get_buf(main), file, which)
  end
  -- The history keeps its window options after coming back.
  eq(vim.wo[Sidebar.window()].wrap, true)
  eq(vim.wo[Sidebar.window()].number, false)
end)

T("the sidebar still switches agents, and the switched window stays pinned", function()
  local first = H.open()
  local second = H.open()
  local win = Sidebar.window()
  eq(api.nvim_win_get_buf(win), second.history_buf)
  require("dyadic.view").show(first)
  H.settle()
  eq(api.nvim_win_get_buf(win), first.history_buf)
  api.nvim_set_current_win(win)
  refused("bprevious")
  eq(api.nvim_win_get_buf(win), first.history_buf)
end)

return T
