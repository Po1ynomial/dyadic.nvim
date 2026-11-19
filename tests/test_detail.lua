local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local api = vim.api

local function open_with_read()
  local agent = H.open({
    entries = H.chain({
      { role = "user", content = "look", timestamp = 1 },
      {
        role = "assistant",
        model = "m",
        timestamp = 2,
        content = { { type = "toolCall", id = "c1", name = "read", arguments = { path = "src/a.lua" } } },
      },
      {
        role = "toolResult",
        toolCallId = "c1",
        toolName = "read",
        content = { { type = "text", text = "see src/a.lua:2\nreturn 1" } },
      },
      { role = "assistant", model = "m", timestamp = 3, content = { { type = "text", text = "Done." } } },
    }),
  })
  H.settle()
  H.cursor_to_row(agent, "1 tool")
  H.keys("za")
  H.cursor_to_row(agent, "read src/a.lua")
  H.keys("K")
  return agent
end

local function title(win)
  local config = api.nvim_win_get_config(win)
  return type(config.title) == "table" and config.title[1][1] or config.title
end

T("K opens the detail in a float over most of the editor", function()
  open_with_read()
  local win = api.nvim_get_current_win()
  local config = api.nvim_win_get_config(win)
  eq(config.relative, "editor")
  eq({ config.width, config.height }, { 70, 18 })
  eq(title(win), " read · done ")
  eq(H.current_lines(), { "see src/a.lua:2", "return 1" })
  local ns = api.nvim_get_namespaces().dyadic_detail
  local mark = api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })[1]
  eq(mark[4].virt_lines, { { { "src/a.lua", "DyadicMeta" } } })
end)

T("q, Esc, K, and leaving the float close it", function()
  local agent = open_with_read()
  for _, key in ipairs({ "q", "<Esc>", "K" }) do
    local win = api.nvim_get_current_win()
    H.keys(key)
    eq(api.nvim_win_is_valid(win), false, key)
    H.cursor_to_row(agent, "read src/a.lua")
    H.keys("K")
  end
  local win = api.nvim_get_current_win()
  api.nvim_set_current_win(H.history_win(agent))
  H.settle()
  eq(api.nvim_win_is_valid(win), false)
end)

T("gF in the detail opens the file in the main area", function()
  local agent = open_with_read()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile({ "one", "two" }, dir .. "/src/a.lua")
  agent.cwd = dir
  local float = api.nvim_get_current_win()
  api.nvim_win_set_cursor(0, { 1, 5 })
  H.keys("gF")
  eq(api.nvim_win_is_valid(float), false)
  eq(api.nvim_get_current_win(), require("dyadic.sidebar").main_window())
  eq(api.nvim_buf_get_name(0), vim.fs.normalize(vim.uv.fs_realpath(dir) .. "/src/a.lua"))
  eq(api.nvim_win_get_cursor(0)[1], 2)
end)

T("the title follows a running tool", function()
  local agent = H.open()
  H.emit(agent, {
    { type = "agent_start" },
    { type = "message_start", message = { role = "user", content = "go", timestamp = 10 } },
    { type = "message_end", message = { role = "user", content = "go", timestamp = 10 } },
    {
      type = "message_end",
      message = {
        role = "assistant",
        timestamp = 11,
        content = { { type = "toolCall", id = "c1", name = "bash", arguments = { command = "make" } } },
      },
    },
    { type = "tool_execution_start", toolCallId = "c1", toolName = "bash", args = { command = "make" } },
  })
  H.settle()
  H.cursor_to_row(agent, "bash make")
  H.keys("K")
  local win = api.nvim_get_current_win()
  eq(title(win), " bash · running ")
  H.emit(
    agent,
    { { type = "tool_execution_end", toolCallId = "c1", toolName = "bash", result = {}, durationMs = 2500 } }
  )
  H.settle()
  eq(title(win), " bash · done · 2.5s ")
  ok(api.nvim_win_is_valid(win), "the float closed")
end)

return T
