local H = dofile("tests/helpers.lua")
local eq, screenshot = H.expect.equality, H.expect.reference_screenshot
local child = H.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = child.setup,
    post_once = child.stop,
  },
})

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
    { role = "user", content = "Fix the bug", timestamp = 1 },
    assistant(2, {
      { type = "thinking", thinking = "The bug is *probably*\nin a.lua" },
      { type = "text", text = "Let me look." },
      { type = "toolCall", id = "c1", name = "read", arguments = { path = "a.lua" } },
    }),
    result("c1", "read", "local x = 1\nreturn x"),
    assistant(3, { { type = "toolCall", id = "c2", name = "bash", arguments = { command = "rg 'foo*' -n" } } }),
    result("c2", "bash", "a.lua:1:foo", { isError = true }),
    assistant(4, { { type = "text", text = "Fixed it.\n\n```lua\nprint(1)\n```" } }),
  })
end

T["finished runs collapse activity that text follows"] = function()
  child.open({ entries = finished_run() })
  child.settle()
  screenshot(child.get_screenshot())
  -- The buffer holds only message text; everything else is overlay rows on empty lines.
  eq(child.transcript(), {
    "",
    "",
    "",
    "Fix the bug",
    "",
    "",
    "",
    "Let me look.",
    "",
    "Fixed it.",
    "",
    "```lua",
    "print(1)",
    "```",
  })
  eq(child.row_texts(), {
    "── Dyadic · /work",
    "── You",
    "── Assistant · fake-model",
    "▸ thinking",
    "▸ 2 tools · 1 error",
  })
end

T["za expands a group in place and K opens an item's details"] = function()
  child.open({ entries = finished_run() })
  child.settle()
  child.cursor_to_row("2 tools")
  child.type_keys("za")
  eq(vim.list_slice(child.row_texts(), 5), {
    "  ◦ read a.lua · done",
    "  ◦ bash rg 'foo*' -n · error",
  })
  screenshot(child.get_screenshot())
  child.cursor_to_row("read a.lua")
  child.type_keys("K")
  eq(child.lua_get("vim.bo.filetype"), "lua")
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), { "local x = 1", "return x" })
  eq(child.lua_get("vim.api.nvim_buf_get_name(0)"):match("dyadic://%d+/detail/c1$") ~= nil, true)
  -- q closes the detail window, and hiding it wipes the buffer.
  local detail = child.lua_get("vim.api.nvim_get_current_buf()")
  child.type_keys("q")
  eq(child.lua_get("vim.api.nvim_buf_is_valid(...)", { detail }), false)
  -- za on an item row collapses its group again.
  child.cursor_to_row("bash rg")
  child.type_keys("za")
  eq(child.row_texts()[5], "▸ 2 tools · 1 error")
end

T["K on a collapsed summary expands it"] = function()
  child.open({ entries = finished_run() })
  child.settle()
  child.cursor_to_row("▸ thinking")
  child.type_keys("K")
  eq(child.row_texts()[4], "  ◦ thinking · 2 lines")
  child.type_keys("K")
  eq(child.lua_get("vim.bo.filetype"), "markdown")
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), { "The bug is *probably*", "in a.lua" })
end

T["the live run keeps trailing activity expanded until text follows"] = function()
  child.open()
  child.emit({
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
  child.settle()
  eq(child.row_texts()[4], "  ◦ bash make test · running")
  screenshot(child.get_screenshot())
  child.emit({
    { type = "message_update", assistantMessageEvent = { type = "text_start", contentIndex = 1 } },
    { type = "message_update", assistantMessageEvent = { type = "text_delta", contentIndex = 1, delta = "Tests run" } },
  })
  child.settle()
  eq(child.row_texts()[4], "▸ 1 tool · 1 running")
  eq(child.transcript()[#child.transcript()], "Tests run")
end

T["a failed run keeps its trailing activity expanded"] = function()
  child.open()
  local entries = H.chain({
    { role = "user", content = "go", timestamp = 10 },
    assistant(11, {
      { type = "toolCall", id = "c1", name = "bash", arguments = { command = "sleep 100" } },
    }, { stopReason = "aborted" }),
  })
  child.lua("_G.S:request('test_set', { entries = ... })", { entries })
  child.emit({ { type = "agent_start" }, { type = "agent_settled", aborted = true } })
  child.wait("_G.S.run_failed == true and #_G.S.messages == 2")
  child.settle()
  eq(
    vim.list_slice(child.row_texts(), 2),
    { "── You", "── Assistant · fake-model", "  ◦ bash sleep 100 · no result", "✗ Aborted" }
  )
end

T["saved history loads fully collapsed"] = function()
  child.open({
    entries = H.chain({
      { role = "user", content = "go", timestamp = 10 },
      assistant(11, {
        { type = "toolCall", id = "c1", name = "bash", arguments = { command = "sleep 100" } },
      }, { stopReason = "aborted" }),
    }),
  })
  child.settle()
  eq(child.row_texts()[4], "▸ 1 tool")
end

T["shell commands, summaries, usage, errors, and queues are rows"] = function()
  child.open({
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
    }),
  })
  child.settle()
  child.emit({ { type = "queue_update", steering = { "also check b.lua" }, followUp = { "then summarize" } } })
  child.settle()
  screenshot(child.get_screenshot())
  local rows = child.row_texts()
  eq(rows[#rows - 1], "⧗ steer · also check b.lua")
  eq(rows[#rows], "⧗ follow-up · then summarize")
  child.cursor_to_row("Context compacted")
  child.type_keys("K")
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), { "Earlier work" })
end

T["the cached render matches a fresh one"] = function()
  child.open({ entries = finished_run() })
  child.settle()
  local function snapshot(cache)
    return child.lua_get(
      [[(function(cache)
        local model = require("dyadic.transcript").build(_G.S, { cache = cache })
        local rows = {}
        for _, row in ipairs(model.rows) do
          rows[#rows + 1] = { row.line, row.kind, row.chunks }
        end
        return { model.lines, rows }
      end)(...)]],
      { cache }
    )
  end
  -- Build once to fill the cache, then compare a cached build with an uncached one.
  snapshot(true)
  eq(child.lua_get("vim.tbl_count(_G.S._render_cache)"), 1)
  eq(snapshot(true), snapshot(false))
  child.lua("_G.S.expanded['group:c1'] = true")
  eq(snapshot(true), snapshot(false))
end

T["output follows only while the cursor is on the last line"] = function()
  child.open({ entries = finished_run() })
  child.settle()
  child.lua("local w = vim.fn.win_findbuf(_G.S.buf)[1]; vim.api.nvim_set_current_win(w); vim.cmd('normal! G')")
  child.lua("_G.S:set_draft('more'); _G.S:submit()")
  child.wait("_G.S.phase == 'Idle' and #_G.S.messages == 8")
  child.settle()
  local last = #child.transcript()
  eq(child.lua_get("vim.api.nvim_win_get_cursor(vim.fn.win_findbuf(_G.S.buf)[1])[1]"), last)
  child.lua("vim.api.nvim_win_set_cursor(vim.fn.win_findbuf(_G.S.buf)[1], { 3, 0 })")
  child.lua("_G.S:set_draft('again'); _G.S:submit()")
  child.wait("#_G.S.messages == 10")
  child.settle()
  eq(child.lua_get("vim.api.nvim_win_get_cursor(vim.fn.win_findbuf(_G.S.buf)[1])[1]"), 3)
end

T["g] and g[ jump between messages"] = function()
  child.open({ entries = finished_run() })
  child.settle()
  child.lua(
    "local w = vim.fn.win_findbuf(_G.S.buf)[1]; vim.api.nvim_set_current_win(w); vim.api.nvim_win_set_cursor(w, { 1, 0 })"
  )
  child.type_keys("g]")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(0)[1]"), 3)
  child.type_keys("g]")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(0)[1]"), 6)
  child.type_keys("g[")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(0)[1]"), 3)
end

T["a hidden transcript catches up when shown"] = function()
  child.open()
  child.lua(
    "local w = vim.fn.win_findbuf(_G.S.buf)[1]; vim.api.nvim_win_set_buf(w, vim.api.nvim_create_buf(true, true))"
  )
  child.lua("_G.S:set_draft('hello'); _G.S:submit()")
  child.wait("_G.S.phase == 'Idle' and #_G.S.messages == 2")
  child.settle()
  eq(child.lua_get("_G.S._view.stale"), true)
  eq(#child.transcript(), 1)
  child.lua("require('dyadic').show(_G.S)")
  eq(child.lua_get("_G.S._view.stale"), false)
  eq(vim.tbl_contains(child.transcript(), "echo: hello"), true)
end

T["status is shown on the transcript window"] = function()
  child.open()
  child.settle()
  local line = child.lua_get("vim.wo[vim.fn.win_findbuf(_G.S.buf)[1]].statusline")
  eq(line, " Dyadic | Idle | fake/fake-model | thinking off | tokens 0 | $0.0000")
  eq(child.lua_get("_G.S:status().model"), "fake/fake-model")
end

return T
