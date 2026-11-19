local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()

local function assistant(ts, content, extra)
  return vim.tbl_extend(
    "force",
    { role = "assistant", model = "fake-model", timestamp = ts, content = content },
    extra or {}
  )
end

local function result(id, name, output, extra)
  return vim.tbl_extend("force", {
    role = "toolResult",
    toolCallId = id,
    toolName = name,
    content = { { type = "text", text = output } },
  }, extra or {})
end

-- One finished run: thinking, preamble, two tools, final answer.
local function finished_run()
  return H.chain({
    { role = "user", content = "Fix the bug", timestamp = 1000 },
    assistant(2000, {
      { type = "thinking", thinking = "The bug is *probably*\nin a.lua" },
      { type = "text", text = "Let me look." },
      { type = "toolCall", id = "c1", name = "read", arguments = { path = "a.lua" } },
    }),
    result("c1", "read", "local x = 1\nreturn x"),
    assistant(3000, { { type = "toolCall", id = "c2", name = "bash", arguments = { command = "rg 'foo*' -n" } } }),
    result("c2", "bash", "a.lua:1:foo", { isError = true }),
    assistant(4000, { { type = "text", text = "\nFixed it.\n\n```lua\nprint(1)\n```\n" } }),
  })
end

local function open_finished()
  local agent = H.open({ entries = finished_run() })
  H.settle()
  return agent
end

T("finished runs collapse activity that text follows", function()
  local agent = open_finished()
  -- The buffer holds only message text; blocks are separated by one blank line.
  eq(H.history(agent), {
    "",
    "",
    "Fix the bug",
    "",
    "",
    "",
    "",
    "",
    "Let me look.",
    "",
    "",
    "",
    "Fixed it.",
    "",
    "```lua",
    "print(1)",
    "```",
  })
  eq(H.rows(agent), {
    { line = 1, text = "▍ You" },
    { line = 5, text = "▍ Assistant", right = "fake-model · 3.0s" },
    { line = 7, text = "▎ ▸ thinking" },
    { line = 11, text = "▎ ▸ 2 tools · 1 error" },
  })
end)

T("the run time comes from the saved entries", function()
  local entries = finished_run()
  entries[#entries].timestamp = "1970-01-01T00:01:15.500Z"
  local agent = H.open({ entries = entries })
  H.settle()
  eq(H.rows(agent)[2].right, "fake-model · 1m 14s")
end)

T("za expands a group in place and K opens an activity's detail", function()
  local agent = open_finished()
  H.cursor_to_row(agent, "2 tools")
  H.keys("za")
  eq(vim.list_slice(H.row_texts(agent), 4), {
    "▎ ▾ 2 tools · 1 error",
    "▎   ◦ read a.lua · done",
    "▎   ◦ bash rg 'foo*' -n · error",
  })
  H.cursor_to_row(agent, "read a.lua")
  H.keys("K")
  eq(vim.bo.filetype, "lua")
  eq(H.current_lines(), { "local x = 1", "return x" })
  ok(vim.api.nvim_buf_get_name(0):match("dyadic://%d+/detail/c1$"), vim.api.nvim_buf_get_name(0))
  -- q closes the detail window, and hiding it wipes the buffer.
  local detail = vim.api.nvim_get_current_buf()
  H.keys("q")
  eq(vim.api.nvim_buf_is_valid(detail), false)
  -- za on an activity row collapses its group again.
  H.cursor_to_row(agent, "bash rg")
  H.keys("za")
  eq(H.row_texts(agent)[4], "▎ ▸ 2 tools · 1 error")
end)

T("K on a collapsed group expands it and leaves an open one", function()
  local agent = open_finished()
  H.cursor_to_row(agent, "▸ thinking")
  H.keys("K")
  eq(vim.list_slice(H.row_texts(agent), 3, 4), { "▎ ▾ thinking", "▎   ◦ thinking · 2 lines" })
  H.cursor_to_row(agent, "▾ thinking")
  H.keys("K")
  eq(H.row_texts(agent)[3], "▎ ▾ thinking")
  H.cursor_to_row(agent, "◦ thinking")
  H.keys("K")
  eq(vim.bo.filetype, "markdown")
  eq(H.current_lines(), { "The bug is *probably*", "in a.lua" })
end)

local function start_bash_run(agent)
  H.emit(agent, {
    { type = "agent_start" },
    { type = "message_start", message = { role = "user", content = "go", timestamp = 10 } },
    { type = "message_end", message = { role = "user", content = "go", timestamp = 10 } },
    { type = "message_start", message = { role = "assistant", content = {}, timestamp = 11 } },
    {
      type = "message_update",
      assistantMessageEvent = { type = "toolcall_start", contentIndex = 0, id = "c1", toolName = "bash" },
    },
    {
      type = "message_update",
      assistantMessageEvent = {
        type = "toolcall_end",
        contentIndex = 0,
        toolCall = { type = "toolCall", id = "c1", name = "bash", arguments = { command = "make test" } },
      },
    },
    { type = "tool_execution_start", toolCallId = "c1", toolName = "bash", args = { command = "make test" } },
  })
  H.settle()
end

T("the live run keeps trailing activity expanded until text follows", function()
  local agent = H.open()
  start_bash_run(agent)
  eq(vim.list_slice(H.row_texts(agent), 3), { "▎ ▾ 1 tool · 1 running", "▎   ◦ bash make test · running" })
  H.emit(agent, {
    { type = "message_update", assistantMessageEvent = { type = "text_start", contentIndex = 1 } },
    { type = "message_update", assistantMessageEvent = { type = "text_delta", contentIndex = 1, delta = "Tests run" } },
  })
  H.settle()
  eq(H.row_texts(agent)[3], "▎ ▸ 1 tool · 1 running")
  local lines = H.history(agent)
  eq(lines[#lines], "Tests run")
end)

T("tool durations show only when pi reports them", function()
  local agent = H.open()
  start_bash_run(agent)
  H.emit(agent, {
    { type = "tool_execution_end", toolCallId = "c1", toolName = "bash", result = {}, durationMs = 1234 },
  })
  H.settle()
  eq(H.row_texts(agent)[4], "▎   ◦ bash make test · done 1.2s")
end)

T("the live run's time counts up", function()
  local agent = H.open()
  local now = math.floor(vim.uv.gettimeofday() * 1000)
  H.emit(agent, {
    { type = "agent_start" },
    { type = "message_start", message = { role = "user", content = "go", timestamp = now - 65000 } },
    { type = "message_end", message = { role = "user", content = "go", timestamp = now - 65000 } },
    { type = "message_start", message = { role = "assistant", content = {}, timestamp = now, model = "m" } },
  })
  H.settle()
  local right = H.rows(agent)[2].right
  ok(right == "m · 1m 5s" or right == "m · 1m 6s", right)
  H.settle(1100)
  ok(H.rows(agent)[2].right ~= right, "the run time did not change")
end)

T("a visible detail buffer follows a running tool", function()
  local agent = H.open()
  start_bash_run(agent)
  H.cursor_to_row(agent, "bash make")
  H.keys("K")
  eq(H.current_lines(), { "(no output)" })
  local partial = { content = { { type = "text", text = "step 1\nstep 2" } } }
  H.emit(agent, { { type = "tool_execution_update", toolCallId = "c1", toolName = "bash", partialResult = partial } })
  H.settle()
  eq(H.current_lines(), { "step 1", "step 2" })
end)

T("a failed run keeps its trailing activity expanded", function()
  local agent = H.open()
  local entries = H.chain({
    { role = "user", content = "go", timestamp = 10 },
    assistant(11, {
      { type = "toolCall", id = "c1", name = "bash", arguments = { command = "sleep 100" } },
    }, { stopReason = "aborted" }),
  })
  H.request(agent, "test_set", { entries = entries })
  H.emit(agent, { { type = "agent_start" }, { type = "agent_settled", aborted = true } })
  H.wait(function()
    return agent.run_failed == true and #agent.messages == 2
  end)
  H.settle()
  eq(H.row_texts(agent), {
    "▍ You",
    "▍ Assistant",
    "▎ ▾ 1 tool",
    "▎   ◦ bash sleep 100 · no result",
    "✗ Aborted",
  })
end)

T("saved history loads fully collapsed", function()
  local agent = H.open({
    entries = H.chain({
      { role = "user", content = "go", timestamp = 10 },
      assistant(11, {
        { type = "toolCall", id = "c1", name = "bash", arguments = { command = "sleep 100" } },
      }, { stopReason = "aborted" }),
    }),
  })
  H.settle()
  eq(H.row_texts(agent)[3], "▎ ▸ 1 tool")
end)

T("shell commands, summaries, usage, errors, and queues are rows", function()
  local agent = H.open({
    entries = H.chain({
      { role = "user", content = "old", timestamp = 1 },
      {
        type = "compaction",
        summary = "Earlier work",
        tokensBefore = 1200,
        firstKeptEntryId = "e3",
        usage = { totalTokens = 50, cost = { total = 0.01 } },
      },
      { role = "user", content = "next", timestamp = 2 },
      {
        role = "bashExecution",
        command = "ls -la",
        output = "total 0",
        exitCode = 0,
        excludeFromContext = true,
        timestamp = 5,
      },
      assistant(3, {}, { stopReason = "error", errorMessage = "529 overloaded" }),
      { type = "branch_summary", summary = "Tried another way", fromId = "e1" },
    }),
  })
  H.settle()
  H.emit(agent, { { type = "queue_update", steering = { "also check b.lua" }, followUp = { "then summarize" } } })
  H.settle()
  eq(H.rows(agent), {
    { line = 1, text = "◇ Context compacted · 1200 tokens before" },
    { line = 3, text = "usage · compaction: 50 tokens billed, $0.0100" },
    { line = 5, text = "▍ You" },
    { line = 9, text = "▌ $ ls -la · exit 0 · excluded from context" },
    { line = 11, text = "▍ Assistant", right = "fake-model · 0.0s" },
    { line = 13, text = "✗ 529 overloaded" },
    { line = 15, text = "↳ Branch summary" },
    { line = 17, text = "⧗ steer · also check b.lua" },
    { line = 18, text = "⧗ follow-up · then summarize" },
  })
  H.cursor_to_row(agent, "Context compacted")
  H.keys("K")
  eq(H.current_lines(), { "Earlier work" })
end)

T("the cached render matches a fresh one", function()
  local agent = open_finished()
  local History = require("dyadic.history")
  local function snapshot(cache)
    local model = History.build(agent, { cache = cache })
    local rows = {}
    for _, row in ipairs(model.rows) do
      rows[#rows + 1] = { row.line, row.kind, row.chunks, row.right }
    end
    return { model.lines, rows }
  end
  -- Build once to fill the cache, then compare a cached build with an uncached one.
  snapshot(true)
  eq(vim.tbl_count(agent._render_cache), 1)
  eq(snapshot(true), snapshot(false))
  agent.expanded["group:c1"] = true
  eq(snapshot(true), snapshot(false))
end)

T("output follows only while the cursor is on the last line", function()
  local agent = open_finished()
  local win = H.history_win(agent)
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(agent.history_buf), 0 })
  agent:set_draft("more")
  agent:submit()
  H.wait(function()
    return agent.phase == "Idle" and #agent.messages == 8
  end)
  H.settle()
  eq(vim.api.nvim_win_get_cursor(win)[1], #H.history(agent))
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  agent:set_draft("again")
  agent:submit()
  H.wait(function()
    return #agent.messages == 10
  end)
  H.settle()
  eq(vim.api.nvim_win_get_cursor(win)[1], 3)
end)

T("g] and g[ jump between speakers", function()
  local agent = open_finished()
  local win = H.history_win(agent)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  H.keys("g]")
  eq(vim.api.nvim_win_get_cursor(0)[1], 5)
  H.keys("g[")
  eq(vim.api.nvim_win_get_cursor(0)[1], 1)
end)

T("a hidden history catches up when shown", function()
  local agent = H.open()
  require("dyadic").toggle()
  eq(vim.fn.win_findbuf(agent.history_buf), {})
  agent:set_draft("hello")
  agent:submit()
  H.wait(function()
    return agent.phase == "Idle" and #agent.messages == 2
  end)
  H.settle()
  eq(agent._view.stale, true)
  eq(#H.history(agent), 1)
  require("dyadic").show(agent)
  eq(agent._view.stale, false)
  ok(vim.tbl_contains(H.history(agent), "echo: hello"))
end)

T("buffers keep their own filetype and parse as markdown", function()
  local agent = H.open()
  eq(vim.bo[agent.history_buf].filetype, "dyadic")
  eq(vim.bo[agent.composer_buf].filetype, "dyadic_composer")
  ok(vim.treesitter.highlighter.active[agent.history_buf] ~= nil, "treesitter is not active")
  eq(vim.treesitter.get_parser(agent.history_buf):lang(), "markdown")
  eq(vim.treesitter.language.get_lang("dyadic"), "markdown")
end)

return T
