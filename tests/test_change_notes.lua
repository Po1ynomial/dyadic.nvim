local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local api = vim.api
local Files = require("dyadic.files")

-- A project directory with files; returns its path. The agent's cwd is set to it.
local function project(files)
  local dir = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")) .. "/notes-" .. math.random(1e9)
  vim.fn.mkdir(dir, "p")
  for name, lines in pairs(files) do
    vim.fn.writefile(lines, dir .. "/" .. name)
  end
  return dir
end

local function open(config, dir)
  local log = vim.fn.tempname()
  local agent = H.open({ log = log }, config or { change_notes = true })
  agent.cwd = dir
  return agent, log
end

-- Edit files in the main area; the sidebar's windows keep their buffers.
local function edit(path)
  api.nvim_set_current_win(require("dyadic.sidebar").main_window())
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function changes(agent, log)
  local answer = H.bridge(agent, log, { kind = "changes" }).value
  return answer ~= vim.NIL and answer or nil
end

local function read(agent, log, path)
  H.bridge(agent, log, { kind = "read", path = path })
end

-- The agent changes a file without review: prepare, then apply.
local function change(agent, log, path, content)
  H.bridge(agent, log, { kind = "prepare", path = path, tool = "edit" })
  return H.bridge(agent, log, { kind = "apply", path = path, content = content, tool = "edit" }).value
end

T("off by default: nothing is recorded or told", function()
  local dir = project({ ["a.txt"] = { "one" } })
  local agent, log = open({}, dir)
  read(agent, log, dir .. "/a.txt")
  vim.fn.writefile({ "two" }, dir .. "/a.txt")
  eq(changes(agent, log), nil)
  eq(agent._seen, nil)
end)

T("a run start tells the agent about files it saw that changed since, once", function()
  local dir = project({ ["a.txt"] = { "one", "two", "three" }, ["b.txt"] = { "same" } })
  local agent, log = open(nil, dir)
  read(agent, log, dir .. "/a.txt")
  read(agent, log, dir .. "/b.txt")
  eq(changes(agent, log), nil)
  -- An unsaved edit in a buffer counts: the agent would read it.
  edit(dir .. "/a.txt")
  api.nvim_buf_set_lines(0, 1, 2, false, { "TWO" })
  local note = changes(agent, log)
  eq(note.files, { "a.txt" })
  eq(
    note.text,
    table.concat({
      "These files changed since you last saw them; the current version stands.",
      "",
      "a.txt:",
      "@@ -1,3 +1,3 @@",
      " one",
      "-two",
      "+TWO",
      " three",
    }, "\n")
  )
  eq(changes(agent, log), nil)
end)

T("a large change is described, not shown; a deleted file is named", function()
  local lines = {}
  for i = 1, 60 do
    lines[i] = "line " .. i
  end
  local dir = project({ ["big.txt"] = lines, ["gone.txt"] = { "x" } })
  local agent, log = open(nil, dir)
  read(agent, log, dir .. "/big.txt")
  read(agent, log, dir .. "/gone.txt")
  local changed = vim.deepcopy(lines)
  for i = 10, 40 do
    changed[i] = "changed " .. i
  end
  vim.fn.writefile(changed, dir .. "/big.txt")
  vim.fn.delete(dir .. "/gone.txt")
  local note = changes(agent, log)
  eq(note.files, { "big.txt", "gone.txt" })
  ok(
    note.text:find("big.txt: 62 lines changed, around lines 10–40; read it before relying on it.", 1, true),
    note.text
  )
  ok(note.text:find("gone.txt: deleted.", 1, true), note.text)
end)

T("a save that formats the file adds a note to the edit's result", function()
  local dir = project({ ["a.txt"] = { "one" } })
  local agent, log = open(nil, dir)
  edit(dir .. "/a.txt")
  local buf = api.nvim_get_current_buf()
  api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    callback = function()
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(string.upper, api.nvim_buf_get_lines(buf, 0, -1, false)))
    end,
  })
  local outcome = change(agent, log, dir .. "/a.txt", "one\ntwo\n")
  eq(
    outcome.note,
    "The file now differs from your version; the current version stands.\na.txt:\n@@ -1,2 +1,2 @@\n-one\n-two\n+ONE\n+TWO"
  )
  -- The agent was told, so the next run start has nothing to add.
  eq(changes(agent, log), nil)
end)

T("an edit that lands as written adds nothing", function()
  local dir = project({ ["a.txt"] = { "one" } })
  local agent, log = open(nil, dir)
  eq(change(agent, log, dir .. "/a.txt", "one\ntwo\n"), {})
  eq(changes(agent, log), nil)
end)

T("a review the user edited reports the edits as a note, not a sentence", function()
  local dir = project({ ["a.txt"] = { "a", "b", "c" } })
  local agent, log = open({ change_notes = true, review = true }, dir)
  local path = dir .. "/a.txt"
  H.bridge(agent, log, { kind = "prepare", path = path, tool = "edit" })
  local id = H.bridge_send(agent, { kind = "apply", path = path, content = "a\nB\nc\n", tool = "edit" })
  H.settle()
  local buf = Files.buffer(path)
  api.nvim_set_current_win(require("dyadic.sidebar").main_window())
  api.nvim_win_set_buf(0, buf)
  api.nvim_buf_set_lines(buf, 1, 2, false, { "Bee" })
  H.settle()
  api.nvim_win_set_cursor(0, { 2, 0 })
  H.keys("ga")
  local answer
  H.wait(function()
    answer = H.bridge_answer(log, id)
    return answer ~= nil
  end, 3000, "the review outcome")
  eq(
    answer.value.note,
    "Accepted by the user; unsaved in the editor. The file now differs from your version; the current version stands.\n"
      .. "a.txt:\n@@ -1,3 +1,3 @@\n a\n-B\n+Bee\n c"
  )
end)

T("a rejected change leaves the agent believing the original", function()
  local dir = project({ ["a.txt"] = { "a" } })
  local agent, log = open({ change_notes = true, review = true }, dir)
  local path = dir .. "/a.txt"
  H.bridge(agent, log, { kind = "prepare", path = path, tool = "edit" })
  local id = H.bridge_send(agent, { kind = "apply", path = path, content = "A\n", tool = "edit" })
  H.settle()
  require("dyadic.review").decide(require("dyadic.review").first(agent), false, true)
  H.wait(function()
    return H.bridge_answer(log, id) ~= nil
  end, 3000, "the review outcome")
  eq(H.bridge_answer(log, id).value.error, "The user rejected the change to a.txt.\n- line 1 (no reason)")
  eq(changes(agent, log), nil)
end)

T("switching sessions forgets what the agent saw", function()
  local dir = project({ ["a.txt"] = { "one" } })
  local agent, log = open(nil, dir)
  read(agent, log, dir .. "/a.txt")
  H.request(agent, "test_set", { state = { sessionId = "s2" } })
  local done = false
  agent:refresh(function()
    done = true
  end)
  H.wait(function()
    return done
  end, 3000, "the refresh")
  vim.fn.writefile({ "two" }, dir .. "/a.txt")
  eq(changes(agent, log), nil)
end)

T("the history shows a change note as one line, and the note in its detail", function()
  local agent = H.open({
    entries = H.chain({
      { role = "user", content = "go", timestamp = 1 },
      {
        type = "custom_message",
        customType = "dyadic-changes",
        content = "These files changed since you last saw them; the current version stands.\n\na.txt: deleted.",
        display = true,
        details = { files = { "a.txt", "b.lua" } },
      },
    }),
  })
  H.settle()
  local found
  for i, line in ipairs(H.history(agent)) do
    if line:find("told the agent", 1, true) then
      found = i
    end
  end
  ok(not found, "the row is overlay text, not buffer text")
  H.cursor_to_row(agent, "told the agent: a.txt, b.lua changed")
  H.keys("K")
  ok(api.nvim_buf_get_lines(0, 0, -1, false)[1]:find("These files changed", 1, true))
end)

return T
