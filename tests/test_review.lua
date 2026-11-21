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

T("editing inside a hunk accepts it, and the outcome says the user edited", function()
  local agent, log = open()
  local path = file({ "a", "b", "c" })
  local _, id = propose(agent, log, path, "a\nB\nc\n")
  local buf = require("dyadic.files").buffer(path)
  api.nvim_buf_set_lines(buf, 1, 2, false, { "Bee" })
  local outcome = answer(log, id)
  eq(
    outcome,
    { note = "Accepted by the user; unsaved in the editor. The user also edited the file during the review." }
  )
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

return T
