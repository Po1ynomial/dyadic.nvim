local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local api = vim.api
local Review = require("dyadic.review")

local function file(lines, name)
  local dir = vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/")) .. "/review-" .. math.random(1e9)
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. (name or "a.txt")
  vim.fn.writefile(lines, path)
  return path, dir
end

local function open(config)
  local log = vim.fn.tempname()
  local agent = H.open({ log = log }, config or { review = true })
  return agent, log
end

-- Ask for a plan and send the change, as the edit tool does; returns the apply request id.
local function propose(agent, log, path, content, tool)
  local plan = H.bridge(agent, log, { kind = "prepare", path = path, tool = tool or "edit" })
  local id = H.bridge_send(agent, { kind = "apply", path = path, content = content, tool = tool or "edit" })
  return plan.value, id
end

local function answer(log, id)
  local result
  H.wait(function()
    result = H.bridge_answer(log, id)
    return result ~= nil
  end, 3000, "the review outcome")
  return result.value
end

-- Review keys work in the main area; the sidebar's windows keep their buffers.
local function show(buf)
  api.nvim_set_current_win(require("dyadic.sidebar").main_window())
  api.nvim_win_set_buf(0, buf)
end

local function lines(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

T("a reviewed change lands in a loaded, unsaved buffer and waits for decisions", function()
  local agent, log = open()
  local path = file({ "a", "b", "c", "d", "e", "f", "g", "h" })
  local plan, id = propose(agent, log, path, "A\nb\nc\nd\ne\nf\ng\nH\n")
  eq(plan, { mode = "review", text = "a\nb\nc\nd\ne\nf\ng\nh\n" })
  local buf = require("dyadic.files").buffer(path)
  ok(buf and vim.bo[buf].buflisted)
  eq(lines(buf), { "A", "b", "c", "d", "e", "f", "g", "H" })
  eq(vim.bo[buf].modified, true)
  eq(Review.pending(agent), 2)
  ok(require("dyadic.bars").composer_winbar(agent):find("review: 2 hunks", 1, true))
  H.settle()
  eq(H.bridge_answer(log, id), nil)
  -- No window changed for the review.
  ok(#vim.fn.win_findbuf(buf) == 0)
  -- Accept the first hunk at the cursor, reject the second with a reason.
  show(buf)
  api.nvim_win_set_cursor(0, { 1, 0 })
  H.keys("ga")
  eq(Review.pending(agent), 1)
  eq(api.nvim_win_get_cursor(0)[1], 8)
  vim.ui.input = function(_, on_confirm)
    on_confirm("keep h lowercase")
  end
  H.keys("gS")
  local outcome = answer(log, id)
  eq(
    outcome.text,
    "The user accepted 1 of 2 hunks in "
      .. vim.fn.fnamemodify(path, ":~")
      .. "; unsaved in the editor. Rejected:\n- line 8: keep h lowercase"
  )
  ok(outcome.diff:find("+A", 1, true) and not outcome.diff:find("+H", 1, true))
  eq(lines(buf), { "A", "b", "c", "d", "e", "f", "g", "h" })
  eq(vim.fn.readfile(path)[1], "a")
  eq(vim.fn.maparg("ga", "n"), "")
  eq(Review.pending(agent), 0)
end)

T("accepting everything adds a note; rejecting everything is an error", function()
  local agent, log = open()
  local path = file({ "one", "two" })
  local _, id = propose(agent, log, path, "ONE\ntwo\n")
  Review.decide(Review.first(agent), true, true)
  eq(answer(log, id), { note = "Accepted by the user; unsaved in the editor." })
  local _, second = propose(agent, log, path, "ONE\nTWO\nthree\n")
  local buf = require("dyadic.files").buffer(path)
  eq(lines(buf), { "ONE", "TWO", "three" })
  require("dyadic").command("review")
  require("dyadic").command("review reject all")
  local outcome = answer(log, second)
  eq(outcome.error, "The user rejected the change to " .. vim.fn.fnamemodify(path, ":~") .. ".\n- line 2 (no reason)")
  eq(lines(buf), { "ONE", "two" })
end)

T("editing a hunk leaves it undecided; accepting it takes the user's version", function()
  local agent, log = open()
  local path = file({ "a", "b", "c" })
  local _, id = propose(agent, log, path, "a\nB\nc\n")
  local buf = require("dyadic.files").buffer(path)
  api.nvim_buf_set_lines(buf, 1, 2, false, { "Bee" })
  H.settle()
  eq(Review.pending(agent), 1)
  ok(Review.get(buf).hunks[1].edited)
  eq(H.bridge_answer(log, id), nil)
  show(buf)
  api.nvim_win_set_cursor(0, { 2, 0 })
  H.keys("ga")
  eq(
    answer(log, id),
    { note = "Accepted by the user; unsaved in the editor. The user also edited the file during the review." }
  )
  eq(lines(buf), { "a", "Bee", "c" })
end)

T("a deletion and an insertion revert in place", function()
  local agent, log = open()
  local path = file({ "a", "b", "c", "d" })
  local _, id = propose(agent, log, path, "a\nc\nd\ne\n")
  local buf = require("dyadic.files").buffer(path)
  eq(lines(buf), { "a", "c", "d", "e" })
  Review.decide(Review.first(agent), false, true)
  eq(answer(log, id).error:match("\n(.*)$"), "- line 2 (no reason)\n- after line 4 (no reason)")
  eq(lines(buf), { "a", "b", "c", "d" })
end)

T("a rejected new file leaves no buffer behind", function()
  local agent, log = open()
  local _, dir = file({ "x" })
  local path = dir .. "/sub/new.txt"
  local plan, id = propose(agent, log, path, "hello\n", "write")
  eq(plan.text, "")
  local buf = require("dyadic.files").buffer(path)
  eq(lines(buf), { "hello" })
  Review.decide(Review.first(agent), false, true)
  ok(answer(log, id).error)
  eq(require("dyadic.files").buffer(path), nil)
  eq(vim.fn.filereadable(path), 0)
end)

T("rejecting a new file keeps the windows that show it", function()
  local agent, log = open()
  local old, dir = file({ "old" })
  local path = dir .. "/new.txt"
  local _, id = propose(agent, log, path, "hello\n", "write")
  api.nvim_set_current_win(require("dyadic.sidebar").main_window())
  vim.cmd("edit " .. old)
  local buf = require("dyadic.files").buffer(path)
  api.nvim_win_set_buf(0, buf)
  vim.cmd("split")
  local windows = api.nvim_tabpage_list_wins(0)
  Review.decide(Review.first(agent), false, true)
  ok(answer(log, id).error)
  eq(api.nvim_tabpage_list_wins(0), windows)
  for _, win in ipairs(vim.fn.win_findbuf(vim.fn.bufnr(old))) do
    windows = vim.tbl_filter(function(other)
      return other ~= win
    end, windows)
  end
  -- Both windows went back to the file shown before; the sidebar's two keep theirs.
  eq(#windows, 2)
  eq(api.nvim_buf_is_valid(buf), false)
end)

T("rejecting a new file with no other file to show leaves an empty buffer in its window", function()
  local agent, log = open()
  local _, dir = file({ "x" })
  local path = dir .. "/new.txt"
  local _, id = propose(agent, log, path, "hello\n", "write")
  local main = require("dyadic.sidebar").main_window()
  vim.bo[api.nvim_win_get_buf(main)].buflisted = false
  api.nvim_win_set_buf(main, require("dyadic.files").buffer(path))
  Review.decide(Review.first(agent), false, true)
  ok(answer(log, id).error)
  ok(api.nvim_win_is_valid(main))
  local shown = api.nvim_win_get_buf(main)
  eq(api.nvim_buf_get_name(shown), "")
  eq(lines(shown), { "" })
end)

T("a new file is one hunk, blank lines and all", function()
  local agent, log = open()
  local _, dir = file({ "x" })
  local path = dir .. "/new.md"
  local _, id = propose(agent, log, path, "# Title\n\nText.\n", "write")
  local buf = require("dyadic.files").buffer(path)
  eq(lines(buf), { "# Title", "", "Text." })
  eq(Review.pending(agent), 1)
  Review.decide(Review.first(agent), true, true)
  -- Nothing but the change is in the buffer, so the user did not edit it.
  eq(answer(log, id), { note = "Accepted by the user; unsaved in the editor." })
end)

T("an aborted run keeps accepted hunks and reverts the rest", function()
  local agent, log = open()
  local path = file({ "a", "b", "c", "d", "e", "f", "g" })
  local _, id = propose(agent, log, path, "A\nb\nc\nd\ne\nf\nG\n")
  local buf = require("dyadic.files").buffer(path)
  show(buf)
  api.nvim_win_set_cursor(0, { 1, 0 })
  H.keys("ga")
  H.emit(agent, { { type = "agent_settled", aborted = true } })
  H.settle()
  eq(lines(buf), { "A", "b", "c", "d", "e", "f", "g" })
  eq(Review.pending(agent), 0)
  eq(H.bridge_answer(log, id), nil)
end)

T("a second change to a buffer under review waits, then refuses a stale base", function()
  local agent, log = open()
  local path = file({ "a", "b" })
  local _, first = propose(agent, log, path, "A\nb\n")
  local other = H.open({ log = log }, { review = true })
  local plan = H.bridge(other, log, { kind = "prepare", path = path, tool = "edit" }).value
  eq(plan.text, "A\nb\n")
  local second = H.bridge_send(other, { kind = "apply", path = path, content = "A\nB\n", tool = "edit" })
  -- The first review is still open, so the second waits.
  show(require("dyadic.files").buffer(path))
  require("dyadic").command("review reject")
  ok(answer(log, first).error)
  -- The first review reverted to "a", so the second's base no longer matches.
  eq(answer(log, second).error, "The file changed in the editor since this edit read it; read it again.")
end)

T("review rules: the nearest rule wins, and the agent's switch overrides rules", function()
  local _, dir = file({ "x" })
  vim.fn.mkdir(dir .. "/scratch", "p")
  local agent = H.open({}, { review = { default = false, paths = { [dir] = true, [dir .. "/scratch"] = false } } })
  ok(Review.enabled(agent, dir .. "/a.txt"))
  ok(Review.enabled(agent, dir .. "/new/dir/b.txt"))
  ok(not Review.enabled(agent, dir .. "/scratch/c.txt"))
  ok(not Review.enabled(agent, dir .. "-other/a.txt"))
  require("dyadic").command("review off")
  ok(not Review.enabled(agent, dir .. "/a.txt"))
  require("dyadic").command("review on")
  ok(Review.enabled(agent, dir .. "/scratch/c.txt"))
  require("dyadic").command("review auto")
  ok(not Review.enabled(agent, dir .. "/scratch/c.txt"))
end)

-- A real directory and a symlink to it.
local function linked()
  local _, dir = file({ "x" })
  local real, link = dir .. "/real", dir .. "/link"
  vim.fn.mkdir(real, "p")
  assert(vim.uv.fs_symlink(real, link))
  return real, link, dir
end

T("a new file under a symlinked directory is reviewed", function()
  local agent, log = open()
  local _, link = linked()
  local path = link .. "/new.txt"
  local plan, id = propose(agent, log, path, "hello\n", "write")
  eq(plan.mode, "review")
  local buf = require("dyadic.files").buffer(path)
  ok(buf, "no buffer for " .. path)
  eq(lines(buf), { "hello" })
  eq(Review.pending(agent), 1)
  Review.decide(Review.first(agent), false, true)
  ok(answer(log, id).error)
  eq(require("dyadic.files").buffer(path), nil)
end)

T("review rules match where files really are, through symlinks either way", function()
  local real, link, dir = linked()
  local outside = dir .. "/shared"
  vim.fn.mkdir(outside, "p")
  assert(vim.uv.fs_symlink(outside, real .. "/vendor"))
  local agent = H.open({}, {
    review = {
      default = false,
      -- One rule through the symlink for a directory that exists, one that does not yet.
      paths = { [link .. "/src"] = true, [link .. "/later"] = true },
    },
  })
  vim.fn.mkdir(real .. "/src", "p")
  ok(Review.enabled(agent, real .. "/src/a.lua"))
  ok(Review.enabled(agent, link .. "/src/a.lua"))
  ok(Review.enabled(agent, real .. "/later/new/b.lua"))
  ok(Review.enabled(agent, link .. "/later/b.lua"))
  ok(not Review.enabled(agent, real .. "/other.lua"))
  -- A symlink inside a reviewed directory follows the rules of its target.
  agent.config.review.paths = { [real] = true }
  ok(Review.enabled(agent, real .. "/a.lua"))
  ok(not Review.enabled(agent, real .. "/vendor/lib.lua"))
end)

T("the user's own buffer-local mapping comes back after the review", function()
  local agent, log = open()
  local path = file({ "a" })
  api.nvim_set_current_win(require("dyadic.sidebar").main_window())
  vim.cmd("edit " .. path)
  vim.keymap.set("n", "ga", "<Cmd>let g:mine = 1<CR>", { buffer = 0 })
  local _, id = propose(agent, log, path, "b\n")
  H.keys("ga")
  ok(answer(log, id).note)
  eq(vim.fn.maparg("ga", "n"), "<Cmd>let g:mine = 1<CR>")
end)

-- Undo and redo. The file has two hunks: line 3 and line 5.
local OLD = { "local M = {}", "function M.greet(name)", '  print("hello " .. name)', "end", "return M" }
local NEW3, NEW5 = '  print(("hello %s"):format(name))', "return setmetatable(M, {})"

-- The review of the two hunks, shown in the main area; returns the agent, log, request
-- id, buffer, and path.
local function two_hunks()
  local agent, log = open()
  local path = file(OLD)
  local new = vim.deepcopy(OLD)
  new[3], new[5] = NEW3, NEW5
  local _, id = propose(agent, log, path, table.concat(new, "\n") .. "\n")
  local buf = require("dyadic.files").buffer(path)
  show(buf)
  return agent, log, id, buf, path
end

local function states(buf)
  return vim.tbl_map(function(hunk)
    return hunk.state
  end, Review.get(buf).hunks)
end

-- Run keys as typed, at `line` when given, and let the review catch up.
local function press(keys, line)
  if line then
    api.nvim_win_set_cursor(0, { line, 0 })
  end
  H.keys(keys)
  -- Neovim's main loop fires CursorMoved after a key; feedkeys in a test does not.
  api.nvim_exec_autocmds("CursorMoved", { buffer = api.nvim_get_current_buf() })
  H.settle()
end

local function reason(text)
  vim.ui.input = function(_, on_confirm)
    on_confirm(text)
  end
end

-- Rows with a review highlight on the added lines.
local function marked(buf)
  local rows = {}
  local ns = api.nvim_get_namespaces().dyadic_review
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == "DyadicReviewAdd" then
      rows[#rows + 1] = mark[2] + 1
    end
  end
  return rows
end

-- The review's virtual lines by row: { row = { text of each virtual line } }, and any
-- end-of-line text.
local function virtual(buf)
  local rows, eol = {}, {}
  local ns = api.nvim_get_namespaces().dyadic_review
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local details = mark[4]
    for _, line in ipairs(details.virt_lines or {}) do
      rows[mark[2] + 1] = rows[mark[2] + 1] or {}
      table.insert(
        rows[mark[2] + 1],
        vim.trim(table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, line)))
      )
    end
    if details.virt_text then
      eol[#eol + 1] = mark[2] + 1
    end
  end
  return rows, eol
end

T("the banner shows on the hunk at the cursor only, and no hunk has end-of-line text", function()
  local _, _, _, buf = two_hunks()
  press("3G")
  local rows, eol = virtual(buf)
  eq(eol, {})
  -- The banner wraps in the narrow test window; the removed line follows it.
  eq(rows[3][#rows[3]], vim.trim(OLD[3]))
  eq(
    table.concat(vim.list_slice(rows[3], 1, #rows[3] - 1), "  "),
    "Review 1/2  ga accept  gs reject  gS +reason  gA all  ]c [c"
  )
  eq(rows[5], { OLD[5] })
  press("4G")
  rows = virtual(buf)
  eq(rows[3], { vim.trim(OLD[3]) })
  press("]c")
  eq(api.nvim_win_get_cursor(0)[1], 5)
  eq(virtual(buf)[5][1]:sub(1, 10), "Review 2/2")
end)

T("with one undecided hunk left, the banner drops accept all and the moves", function()
  local _, _, _, buf = two_hunks()
  press("ga", 3)
  local rows = virtual(buf)
  eq(table.concat(vim.list_slice(rows[5], 1, #rows[5] - 1), "  "), "Review 2/2  ga accept  gs reject  gS +reason")
end)

T("keys away from a hunk change nothing and say how to reach one", function()
  local _, log, id, buf = two_hunks()
  _G.notes = {}
  press("ga", 1)
  press("gs", 4)
  eq(states(buf), { "pending", "pending" })
  eq(lines(buf)[5], NEW5)
  eq(H.bridge_answer(log, id), nil)
  eq(_G.notes[#_G.notes].msg, "Dyadic: No hunk at the cursor; ]c and [c move to one")
end)

T("changed words are highlighted in the added and the removed line", function()
  local _, _, _, buf = two_hunks()
  press("", 3)
  local ns = api.nvim_get_namespaces().dyadic_review
  local added = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == "DyadicReviewAddText" then
      added[#added + 1] = NEW3:sub(mark[3] + 1, mark[4].end_col)
    end
  end
  eq(added, { "(", "%s", "):format(", ")" })
  local removed = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do
        if chunk[2] == "DyadicReviewDeleteText" then
          removed[#removed + 1] = chunk[1]
        end
      end
    end
  end
  eq(removed, { " .. " })
end)

T("added lines are a range under their changed words, not a line highlight", function()
  local _, _, _, buf = two_hunks()
  local ns = api.nvim_get_namespaces().dyadic_review
  local line, words
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, { 2, 0 }, { 2, -1 }, { details = true })) do
    local details = mark[4]
    eq(details.line_hl_group, nil)
    if details.hl_group == "DyadicReviewAdd" then
      line = details
    elseif details.hl_group == "DyadicReviewAddText" then
      words = details
    end
  end
  eq({ line.end_row, line.end_col, line.hl_eol }, { 3, 0, true })
  ok(words.priority > line.priority)
end)

-- The resolved background of a highlight group.
local function bg(name)
  return api.nvim_get_hl(0, { name = name, link = false }).bg
end

T("changed words take their line's tint, stronger, and follow the colour scheme", function()
  require("dyadic.view")
  vim.cmd("hi clear")
  api.nvim_set_hl(0, "Normal", { bg = 0x101010 })
  api.nvim_set_hl(0, "DiffAdd", { bg = 0x203020 })
  -- A removed line with red text and no background.
  api.nvim_set_hl(0, "DiffDelete", { fg = 0xff0000 })
  api.nvim_exec_autocmds("ColorScheme", {})
  eq(bg("DyadicReviewAddText"), 0x305030)
  eq(bg("DyadicReviewDeleteText"), 0x580b0b)
  -- A colour the user set wins.
  vim.cmd("hi clear")
  api.nvim_set_hl(0, "DiffAdd", { bg = 0x203020 })
  api.nvim_set_hl(0, "DyadicReviewAddText", { bg = 0x123456 })
  api.nvim_exec_autocmds("ColorScheme", {})
  eq(bg("DyadicReviewAddText"), 0x123456)
end)

T("a removal is picked from the line below it, or the last line at the end", function()
  local agent, log = open()
  local path = file({ "head", "a", "b", "middle", "c", "tail" })
  local _, id = propose(agent, log, path, "a\nb\nc\n")
  local buf = require("dyadic.files").buffer(path)
  show(buf)
  eq(lines(buf), { "a", "b", "c" })
  local rows = virtual(buf)
  eq(rows[1], { "head" })
  eq(rows[3], { "middle", "tail" })
  press("gs", 3)
  eq(lines(buf), { "a", "b", "middle", "c" })
  eq(states(buf), { "pending", "rejected", "pending" })
  press("gs", 4)
  eq(lines(buf), { "a", "b", "middle", "c", "tail" })
  press("ga", 1)
  ok(answer(log, id).text:find("accepted 1 of 3", 1, true))
end)

T("removed lines are laid out like the window shows text", function()
  local view = { width = 10, wrap = true, linebreak = false, breakat = { [" "] = true }, tabstop = 4 }
  local function rows(chunks)
    return vim.tbl_map(function(line)
      return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, line))
    end, Review._layout(chunks, view, "Fill"))
  end
  eq(rows({ { "\tab", "Del" } }), { "    ab    " })
  eq(rows({ { "aaaa bbbb cccc", "Del" } }), { "aaaa bbbb ", "cccc      " })
  eq(rows({ { "aaaaaa bbbbbb", "Del" } }), { "aaaaaa bbb", "bbb       " })
  view.linebreak = true
  eq(rows({ { "aaaaaa bbbbbb", "Del" } }), { "aaaaaa    ", "bbbbbb    " })
  eq(rows({ { "", "Del" } }), { "          " })
  view.wrap = false
  eq(rows({ { "aaaaaa bbbbbb", "Del" } }), { "aaaaaa bbbbbb" })
  -- Highlight groups stay with their text across rows.
  view.wrap, view.linebreak = true, false
  local laid = Review._layout({ { "aaaaaaaa", "Del" }, { "XXXX", "Word" } }, view, "Fill")
  eq(laid[1], { { "aaaaaaaa", "Del" }, { "XX", "Word" } })
  eq(laid[2], { { "XX", "Word" }, { "        ", "Fill" } })
end)

T("undo after a reject reopens the hunk; redo rejects it again, reason and all", function()
  local _, log, id, buf, path = two_hunks()
  reason("keep it plain")
  press("gS", 5)
  eq(states(buf), { "pending", "rejected" })
  eq(lines(buf)[5], "return M")
  press("u")
  eq(states(buf), { "pending", "pending" })
  eq(lines(buf)[5], NEW5)
  eq(marked(buf), { 3, 5 })
  press("<C-r>")
  eq(states(buf), { "pending", "rejected" })
  press("ga", 3)
  eq(
    answer(log, id).text,
    "The user accepted 1 of 2 hunks in "
      .. vim.fn.fnamemodify(path, ":~")
      .. "; unsaved in the editor. Rejected:\n- line 5: keep it plain"
  )
end)

T("undo after an accept reopens the hunk", function()
  local _, _, _, buf = two_hunks()
  press("ga", 3)
  eq(states(buf), { "accepted", "pending" })
  press("u")
  eq(states(buf), { "pending", "pending" })
  eq(lines(buf)[3], NEW3)
  eq(marked(buf), { 3, 5 })
end)

-- Whether each hunk is edited.
local function edited(buf)
  return vim.tbl_map(function(hunk)
    return hunk.edited
  end, Review.get(buf).hunks)
end

T("editing never ends a review, even mid-word on the last hunk", function()
  local _, log, id, buf = two_hunks()
  press("ga", 3)
  -- cw empties the word first: a half-typed line must not answer the model.
  press("cw", 5)
  press("<Esc>")
  eq(states(buf), { "accepted", "pending" })
  eq(edited(buf), { false, true })
  eq(H.bridge_answer(log, id), nil)
  press("Agiven<Esc>", 5)
  eq(H.bridge_answer(log, id), nil)
  ok(virtual(buf)[5][1]:find("Review 2/2 · edited", 1, true))
  press("ga", 5)
  ok(answer(log, id).note)
end)

T("rejecting an edited hunk puts the old lines back; undo brings the edits back", function()
  local _, _, _, buf = two_hunks()
  press("A -- mine<Esc>", 5)
  press("gs", 5)
  eq(lines(buf)[5], "return M")
  eq(states(buf), { "pending", "rejected" })
  press("u")
  eq(lines(buf)[5], NEW5 .. " -- mine")
  eq(states(buf), { "pending", "pending" })
  eq(edited(buf), { false, true })
end)

T("undo after an edit inside a hunk makes it the agent's again", function()
  local _, _, _, buf = two_hunks()
  press("A -- hi<Esc>", 3)
  eq(edited(buf), { true, false })
  press("u")
  eq(states(buf), { "pending", "pending" })
  eq(edited(buf), { false, false })
end)

T("an edited hunk that lost all its lines is picked like a removal", function()
  local _, _, _, buf = two_hunks()
  press("dd", 3)
  eq(edited(buf), { true, false })
  eq(states(buf), { "pending", "pending" })
  -- The removed line shows above the line that took its place.
  press("ga", 3)
  eq(states(buf), { "accepted", "pending" })
  eq(lines(buf)[3], "end")
end)

T("undoing the agent's change ends the review as undone, and redo cannot bring it back", function()
  local _, log, id, buf, path = two_hunks()
  press("u")
  eq(answer(log, id), { error = "The user undid the change to " .. vim.fn.fnamemodify(path, ":~") .. "." })
  eq(lines(buf), OLD)
  eq(vim.bo[buf].modified, false)
  press("<C-r>")
  eq(lines(buf), OLD)
  eq(marked(buf), {})
end)

T("each undo takes back one step: the decision, then the change", function()
  local _, log, id, buf = two_hunks()
  press("ga", 3)
  press("u")
  eq(states(buf), { "pending", "pending" })
  eq(H.bridge_answer(log, id), nil)
  press("u")
  ok(answer(log, id).error:find("undid", 1, true))
end)

T("an accept on an abandoned undo branch no longer counts; g- brings it back", function()
  local _, _, _, buf = two_hunks()
  press("ga", 3)
  press("u")
  press("Ix<Esc>", 1)
  eq(states(buf), { "pending", "pending" })
  press("<C-r>")
  eq(states(buf), { "pending", "pending" })
  press("g-")
  eq(lines(buf)[1], "local M = {}")
  eq(states(buf), { "accepted", "pending" })
end)

T("an aborted run keeps the hunks the user edited", function()
  local agent, _, _, buf = two_hunks()
  press("A -- mine<Esc>", 3)
  H.emit(agent, { { type = "agent_settled", aborted = true } })
  H.settle()
  eq(lines(buf)[3], NEW3 .. " -- mine")
  eq(lines(buf)[5], "return M")
  eq(Review.get(buf), nil)
end)

T("retyping a hunk's old text is an edit, not a decision", function()
  local _, _, _, buf = two_hunks()
  press("ccreturn M<Esc>", 5)
  eq(states(buf), { "pending", "pending" })
  eq(edited(buf), { false, true })
end)

T("lines added above move the hunks and their marks", function()
  local _, _, _, buf = two_hunks()
  press("ggOone<CR>two<CR>three<Esc>")
  eq(marked(buf), { 6, 8 })
  press("ga", 6)
  eq(states(buf), { "accepted", "pending" })
end)

-- A review of `new` for a file holding `old`, shown in the main area; returns the buffer.
local function review_of(old, new)
  local agent, log = open()
  local path = file(old)
  propose(agent, log, path, table.concat(new, "\n") .. "\n")
  local buf = require("dyadic.files").buffer(path)
  show(buf)
  return buf
end

-- The agent removes x.
local REMOVAL = { { "a", "x", "b", "c", "d" }, { "a", "b", "c", "d" } }

T("an edit right below a removal stays out of the hunk", function()
  local buf = review_of(unpack(REMOVAL))
  press("ccB<Esc>", 2)
  eq(edited(buf), { false })
  eq(marked(buf), {})
  ok(vim.tbl_contains(virtual(buf)[2], "x"))
  press("gs", 2)
  eq(lines(buf), { "a", "x", "B", "c", "d" })
end)

T("an edit right above a removal stays out of the hunk, and above its removed lines", function()
  local buf = review_of(unpack(REMOVAL))
  press("ccA<Esc>", 1)
  eq(edited(buf), { false })
  eq(marked(buf), {})
  ok(vim.tbl_contains(virtual(buf)[2], "x"))
  press("gs", 2)
  eq(lines(buf), { "A", "x", "b", "c", "d" })
end)

T("deleting the line below a removal keeps the removal on the next line", function()
  local buf = review_of(unpack(REMOVAL))
  press("dd", 2)
  eq(edited(buf), { false })
  ok(vim.tbl_contains(virtual(buf)[2], "x"))
  press("gs", 2)
  eq(lines(buf), { "a", "x", "c", "d" })
end)

T("an edit between two close hunks joins neither", function()
  local buf = review_of({ "a", "b", "c", "d" }, { "A", "b", "C", "d" })
  press("ccB<Esc>", 2)
  eq(edited(buf), { false, false })
  eq(marked(buf), { 1, 3 })
  press("gs", 1)
  eq(lines(buf), { "a", "B", "C", "d" })
  eq(states(buf), { "rejected", "pending" })
end)

T("an added line retyped as a copy of its neighbour stays in its hunk", function()
  local buf = review_of({ "a", "b", "c" }, { "a", "X", "b", "c" })
  press("ccb<Esc>", 2)
  eq(edited(buf), { true })
  eq(marked(buf), { 2 })
  press("gs", 2)
  eq(lines(buf), { "a", "b", "c" })
end)

T("a rejected hunk edited afterwards stays rejected, and the edit is reported", function()
  local _, log, id, buf = two_hunks()
  reason("no metatable")
  press("gS", 5)
  press("A -- done<Esc>", 5)
  eq(states(buf), { "pending", "rejected" })
  press("ga", 3)
  local text = answer(log, id).text
  ok(text:find("The user also edited the file during the review.", 1, true), text)
  ok(text:find("- line 5: no metatable", 1, true), text)
end)

T("a decision is its own undo step even when run through :normal", function()
  local _, _, _, buf = two_hunks()
  api.nvim_win_set_cursor(0, { 5, 0 })
  vim.cmd("normal gs")
  H.settle()
  vim.cmd("undo")
  H.settle()
  eq(states(buf), { "pending", "pending" })
  eq(lines(buf)[3], NEW3)
end)

T("closing the buffer during a review ends it", function()
  local _, log, id, buf, path = two_hunks()
  vim.cmd("bwipeout! " .. buf)
  H.settle()
  eq(answer(log, id), {
    error = "The buffer of "
      .. vim.fn.fnamemodify(path, ":~")
      .. " was closed during the review; the change was dropped.",
  })
end)

return T
