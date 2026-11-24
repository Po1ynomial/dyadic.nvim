local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local Tree = require("dyadic.tree")
local Picker = require("dyadic.tree_picker")

local function user(text)
  return { role = "user", content = text }
end
local function assistant(text)
  return { role = "assistant", content = { { type = "text", text = text } }, stopReason = "stop" }
end

-- e1 -> e2 -> e3 -> e4, and a second branch e2 -> e5 -> e6 that holds the leaf.
local function branching()
  local entries = H.chain({ user("first"), assistant("answer one"), user("second"), assistant("answer two") })
  entries[5] = { type = "message", id = "e5", parentId = "e2", message = user("alt second") }
  entries[6] = { type = "message", id = "e6", parentId = "e5", message = assistant("alt answer") }
  return entries
end

local expected_rows = {
  "• You: first",
  "• Assistant: answer one",
  "├⊟ • You: alt second",
  "│     • Assistant: alt answer",
  "└⊟ You: second",
  "      Assistant: answer two",
}

local function prompts(log)
  local result = {}
  for _, record in ipairs(H.sent(log)) do
    if record.type == "prompt" then
      result[#result + 1] = record.message
    end
  end
  return result
end

local function bridge_args(log, name)
  for _, message in ipairs(prompts(log)) do
    local json = message:match("^/dyadic " .. name .. " (.*)$")
    if json then
      return vim.json.decode(json)
    end
  end
end

-- Open the agent and its picker with `/tree`; returns the agent and the picker.
local function open_picker(scenario, config)
  local agent = H.open(vim.tbl_extend("force", { entries = branching() }, scenario or {}), config)
  agent:set_draft("/tree")
  agent:submit()
  H.wait(function()
    return Picker.current() ~= nil
  end, 3000, "the picker")
  return agent, Picker.current()
end

local function lines(p)
  return vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false)
end

local function cursor_line(p)
  return vim.api.nvim_win_get_cursor(p.list_win)[1]
end

T("model: rows, connectors, and branch order follow pi", function()
  local state = Tree.new(branching(), "e6")
  local view = Tree.view(state, "default", "")
  eq(
    vim.tbl_map(function(row)
      return row.id
    end, view.rows),
    { "e1", "e2", "e5", "e6", "e3", "e4" }
  )
  ok(Tree.foldable(view, "e1") and Tree.foldable(view, "e5") and not Tree.foldable(view, "e2"))
  eq(Tree.subtree_end(view, "e5"), 4)
  eq(Tree.segment(view, 4, "up"), 3)
  eq(Tree.segment(view, 1, "down"), 3)
  -- Filters hide rows; their descendants hang under the nearest visible ancestor.
  local users = Tree.view(state, "user-only", "")
  eq(#users.rows, 3)
  eq(users.parent.e5, "e1")
  eq(Tree.nearest(state, users, "e6"), users.index.e5)
  -- Search matches every word, case-insensitively.
  local found = Tree.view(state, "default", "ALT answer")
  eq(#found.rows, 1)
  eq(found.rows[1].id, "e6")
end)

T("model: tool results, summaries, and copy text", function()
  local call = {
    type = "message",
    id = "a",
    message = {
      role = "assistant",
      content = {
        { type = "toolCall", id = "t1", name = "read", arguments = { path = "x.lua", offset = 5, limit = 10 } },
      },
      stopReason = "toolUse",
    },
  }
  local result = { type = "message", id = "r", parentId = "a", message = { role = "toolResult", toolCallId = "t1" } }
  local summary = { type = "branch_summary", id = "s", parentId = "r", summary = "what happened" }
  local state = Tree.new({ call, result, summary }, "s")
  local view = Tree.view(state, "default", "")
  -- The assistant message has no text, so only its result and the summary show.
  eq(#view.rows, 2)
  eq(Tree.chunks(state, view.rows[1].node), { { "◦ read x.lua:5-14", "DyadicActivity" } })
  eq(Tree.copy_text(view.rows[2].node), "what happened")
  eq(Tree.copy_text(view.rows[1].node), nil)
  eq(#Tree.view(state, "no-tools", "").rows, 1)
end)

T("model: children sort by timestamp with file order as a tiebreaker", function()
  local older, newer = "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:01.000Z"
  local state = Tree.new({
    { id = "root", parentId = vim.NIL, timestamp = newer },
    { id = "new", parentId = "root", timestamp = newer },
    { id = "old-first", parentId = "root", timestamp = older },
    { id = "old-second", parentId = "root", timestamp = older },
    { id = "orphan", parentId = "missing", timestamp = older },
    { id = "self", parentId = "self", timestamp = older },
  }, "self")
  local view = Tree.view(state, "all", "")
  eq(
    vim.tbl_map(function(row)
      return row.id
    end, view.rows),
    { "self", "root", "old-first", "old-second", "new", "orphan" }
  )
  eq(view.children[""], { "self", "root", "orphan" })
end)

T("model: label changes replay in file order across branches", function()
  local entries = branching()
  local time = "2026-01-01T00:00:00.000Z"
  vim.list_extend(entries, {
    { type = "label", id = "e7", parentId = "e4", targetId = "e5", label = "first", timestamp = time },
    { type = "label", id = "e8", parentId = "e7", targetId = "e6", label = "remove me", timestamp = time },
    { type = "label", id = "e9", parentId = "e8", targetId = "e5", label = "latest", timestamp = time },
    { type = "label", id = "e10", parentId = "e9", targetId = "e6", label = vim.NIL },
  })
  local state = Tree.new(entries, "e6")
  local labeled = Tree.view(state, "labeled-only", "latest")
  eq(#labeled.rows, 1)
  eq(labeled.rows[1].id, "e5")
  eq(labeled.rows[1].node.labelTimestamp, time)
  eq(state.nodes.e6.label, nil)
  eq(state.nodes.e6.labelTimestamp, nil)
  eq(#Tree.view(state, "labeled-only", "").rows, 1)
end)

T("model: a 10000-entry branch is traversed without recursion", function()
  local entries = {}
  for i = 1, 10000 do
    entries[i] = { id = "e" .. i, parentId = i > 1 and "e" .. (i - 1) or vim.NIL }
  end
  local state = Tree.new(entries, "e10000")
  local view = Tree.view(state, "all", "")
  eq(#view.rows, 10000)
  eq(view.rows[10000].id, "e10000")
  ok(state.active.e1 and state.active.e10000)
end)

T("/tree opens at the current entry with pi's rows", function()
  local _, p = open_picker()
  eq(lines(p), expected_rows)
  eq(cursor_line(p), 4)
  local config = vim.api.nvim_win_get_config(p.list_win)
  ok(vim.inspect(config.title):find("Tree · default · 4/6", 1, true), vim.inspect(config.title))
end)

T("/tree opens a branch whose nested RPC reply would exceed the decoder depth limit", function()
  local messages = {}
  for i = 1, 600 do
    messages[i] = user("message " .. i)
  end
  local agent = H.open({ entries = H.chain(messages) })
  agent:set_draft("/tree")
  agent:submit()
  H.wait(function()
    return Picker.current() ~= nil or agent.rpc._failure ~= nil
  end, 3000, "the picker to open or the RPC to fail")
  eq(agent.rpc._failure, nil)
  local p = Picker.current()
  eq(#lines(p), 600)
  eq(cursor_line(p), 600)
end)

T("filter keys toggle like pi's, and the search bar filters as you type", function()
  local _, p = open_picker()
  H.keys("u")
  eq(#lines(p), 3)
  H.keys("u")
  eq(#lines(p), 6)
  -- Typing in the bar narrows the list at once; <Esc> in the list clears the search.
  vim.api.nvim_set_current_win(p.bar_win)
  vim.api.nvim_buf_set_lines(p.bar_buf, 0, -1, false, { "second" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = p.bar_buf })
  eq(lines(p), { "• You: alt second", "You: second" })
  vim.api.nvim_set_current_win(p.list_win)
  H.keys("<Esc>")
  eq(#lines(p), 6)
  H.keys("<Esc>")
  eq(Picker.current(), nil)
end)

T("h and l fold with Neovim folds and jump between branch segments", function()
  local _, p = open_picker()
  -- One fold per foldable row, nested like the tree, all open.
  eq(
    vim.api.nvim_win_call(p.list_win, function()
      return { vim.fn.foldlevel(2), vim.fn.foldlevel(4), vim.fn.foldlevel(6), vim.fn.foldclosed(4) }
    end),
    { 1, 2, 2, -1 }
  )
  H.keys("h")
  eq(cursor_line(p), 3)
  H.keys("h")
  eq(
    vim.api.nvim_win_call(p.list_win, function()
      return vim.fn.foldclosed(3)
    end),
    3
  )
  vim.v.foldstart = 3
  local text = table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, Picker.foldtext()))
  eq(text, "├⊞ • You: alt second")
  H.keys("j")
  eq(cursor_line(p), 5)
  H.keys("k")
  H.keys("l")
  eq(
    vim.api.nvim_win_call(p.list_win, function()
      return vim.fn.foldclosed(3)
    end),
    -1
  )
end)

T("<C-CR> goes without the summary question and restores the user message", function()
  local log = vim.fn.tempname()
  local agent, p = open_picker({ log = log })
  vim.api.nvim_win_set_cursor(p.list_win, { 5, 0 })
  H.keys("<C-CR>")
  H.wait(function()
    return agent:get_draft() == "second"
  end, 3000, "the restored draft")
  eq(Picker.current(), nil)
  local args = bridge_args(log, "tree")
  eq({ args.id, args.summarize }, { "e3", false })
  -- The history now ends at e2, the parent of the chosen user message.
  H.wait(function()
    return #agent.messages == 2
  end, 3000, "the new branch")
end)

T("<CR> asks whether to summarize; cancelling keeps the picker", function()
  local log = vim.fn.tempname()
  local agent, p = open_picker({ log = log })
  local asked
  vim.ui.select = function(items, opts, on_choice)
    asked = { items = items, prompt = opts.prompt }
    on_choice(nil)
  end
  vim.api.nvim_win_set_cursor(p.list_win, { 6, 0 })
  H.keys("<CR>")
  eq(asked.prompt, "Summarize the branch you leave?")
  ok(Picker.current() == p)
  vim.ui.select = function(_, _, on_choice)
    on_choice("Summarize with instructions")
  end
  vim.ui.input = function(_, on_confirm)
    on_confirm("focus on tests")
  end
  H.keys("<CR>")
  H.wait(function()
    return bridge_args(log, "tree") ~= nil
  end, 3000, "the tree command")
  local args = bridge_args(log, "tree")
  eq({ args.id, args.summarize, args.instructions }, { "e4", true, "focus on tests" })
  eq(agent:get_draft(), "")
end)

T("a cancelled summary reopens the tree at the same entry", function()
  local agent, p = open_picker({ bridge = { tree = { outcome = { cancelled = true } } } })
  vim.ui.select = function(_, _, on_choice)
    on_choice("Summarize")
  end
  vim.api.nvim_win_set_cursor(p.list_win, { 6, 0 })
  H.keys("<CR>")
  H.wait(function()
    local reopened = Picker.current()
    return reopened and reopened ~= p
  end, 3000, "the picker to reopen")
  eq(cursor_line(Picker.current()), 6)
  ok(vim.tbl_contains(
    vim.tbl_map(function(note)
      return note.msg
    end, _G.notes),
    "Dyadic: Branch summarization cancelled"
  ))
  ok(not agent.active)
end)

T("m edits a label through the bridge and yy copies the full entry text", function()
  local log = vim.fn.tempname()
  local _, p = open_picker({ log = log })
  vim.ui.input = function(opts, on_confirm)
    eq(opts.default, "")
    on_confirm("checkpoint")
  end
  H.keys("m")
  H.wait(function()
    return lines(p)[4]:find("[checkpoint]", 1, true) ~= nil
  end, 3000, "the label")
  eq(lines(p)[4], "│     • [checkpoint] Assistant: alt answer")
  H.keys('"ayy')
  eq(vim.fn.getreg("a"), "alt answer")
end)

T("the selected entry is the selected row; the leaf is a no-op", function()
  local agent, p = open_picker()
  H.keys("<C-CR>")
  H.settle()
  eq(Picker.current(), nil)
  ok(_G.notes[#_G.notes].msg:find("Already at this point", 1, true))
  eq(#agent.messages, 4)
  eq(p.closed, true)
end)

T("from the history, the picker starts at the entry under the cursor", function()
  local agent = H.open({ entries = branching() })
  H.cursor_to_row(agent, "You")
  require("dyadic").action("tree")
  H.wait(function()
    return Picker.current() ~= nil
  end, 3000, "the picker")
  eq(cursor_line(Picker.current()), 1)
end)

T("double Esc opens the tree while idle; Esc aborts while working", function()
  local agent = H.open({ entries = branching() })
  require("dyadic.view").focus(agent, true)
  vim.cmd("stopinsert")
  H.keys("<Esc><Esc>")
  H.wait(function()
    return Picker.current() ~= nil
  end, 3000, "the picker")
  Picker.close()
  -- Not with a draft in the composer.
  vim.api.nvim_set_current_win(vim.fn.win_findbuf(agent.composer_buf)[1])
  agent:set_draft("keep me")
  H.keys("<Esc><Esc>")
  H.settle()
  eq(Picker.current(), nil)
  agent:set_draft("")
  local aborted = false
  agent.abort = function()
    aborted = true
  end
  H.emit(agent, { { type = "agent_start" } })
  H.settle()
  H.keys("<Esc>")
  ok(aborted)
  eq(vim.fn.maparg("<Esc><Esc>", "n", false, true).lhs, nil)
end)

T("double_escape = none keeps a plain <Esc> abort", function()
  local agent = H.open({}, { double_escape = "none" })
  local aborted = false
  agent.abort = function()
    aborted = true
  end
  require("dyadic.view").focus(agent, true)
  vim.cmd("stopinsert")
  H.keys("<Esc>")
  ok(aborted)
end)

T("the picker needs the bridge", function()
  local agent = H.open({ entries = branching() }, { bridge = false })
  agent:set_draft("/tree")
  agent:submit()
  H.settle()
  eq(Picker.current(), nil)
  eq(agent:get_draft(), "/tree")
  ok(_G.notes[1].msg:find("/tree needs the bridge", 1, true))
end)

return T
