local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local SessionPicker = require("dyadic.session_picker")

local now = os.time()
local cwd = vim.fn.getcwd()

-- Session files in a session directory. Each spec: id, cwd, name, prompt, reply, age in
-- seconds, parent id, count of extra tool results.
local function sessions(specs)
  local dir = vim.fn.tempname() .. "-sessions"
  vim.fn.mkdir(dir, "p")
  local paths = {}
  for _, spec in ipairs(specs) do
    paths[spec.id] = dir .. "/" .. spec.id .. ".jsonl"
  end
  for _, spec in ipairs(specs) do
    local time = (now - (spec.age or 0)) * 1000
    local records = {
      {
        type = "session",
        id = spec.id,
        cwd = spec.cwd or cwd,
        timestamp = "2026-01-01T00:00:00Z",
        parentSession = spec.parent and paths[spec.parent],
      },
      { type = "message", message = { role = "user", content = spec.prompt or spec.id, timestamp = time } },
    }
    if spec.reply then
      records[#records + 1] = {
        type = "message",
        message = { role = "assistant", content = { { type = "text", text = spec.reply } }, timestamp = time },
      }
    end
    if spec.name then
      records[#records + 1] = { type = "session_info", name = spec.name }
    end
    vim.fn.writefile(vim.tbl_map(vim.json.encode, records), paths[spec.id])
  end
  return dir, paths
end

local function open(dir, extra)
  H.configure({}, { args = { "--session-dir", dir } })
  require("dyadic").command("-r" .. (extra or ""))
  return H.session_picker()
end

local function preview(p)
  return vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false)
end

local function settle(p)
  H.wait(function()
    local state = p.scopes[p.scope]
    return state and state.done and not p.render_pending
  end)
end

T("lists this directory's sessions threaded by fork, newest first", function()
  local dir = sessions({
    { id = "root", age = 3600, reply = "sure" },
    { id = "fork", parent = "root", age = 60, name = "named fork" },
    { id = "other", age = 7200 },
    { id = "away", cwd = "/elsewhere" },
  })
  local p = open(dir)
  eq(H.picker_lines(p), {
    "root  2  1h",
    "└─ named fork  1  1m",
    "other  1  2h",
  })
  ok(p.list_win and vim.api.nvim_win_get_config(p.list_win).title[1][1]:match("Sessions · current · threaded"))
  -- The age column shows each session's own activity.
  eq(SessionPicker.age(now - 3600, now), "1h")
end)

T("the scope key shows every directory grouped, this one first", function()
  local dir = sessions({
    { id = "here", age = 100 },
    { id = "there", cwd = "/elsewhere", age = 10 },
  })
  local p = open(dir)
  H.keys("<Tab>")
  settle(p)
  local lines = H.picker_lines(p)
  eq(lines[1], "⊟ " .. vim.fn.fnamemodify(cwd, ":~") .. "  1 session  1m")
  eq(lines[2], "here  1  1m")
  -- Other directories start folded.
  eq(lines[3], "⊟ /elsewhere  1 session  now")
  eq(vim.fn.foldclosed(3), 3)
  eq(p.scope, "all")
  -- <CR> on a directory opens its fold.
  vim.api.nvim_win_set_cursor(p.list_win, { 3, 0 })
  H.keys("<CR>")
  eq(vim.fn.foldclosed(3), -1)
end)

T("sorts, filters named sessions, and searches", function()
  local dir = sessions({
    { id = "a", prompt = "fix the parser", age = 10 },
    { id = "b", prompt = "docs", name = "parser notes", age = 20 },
    { id = "c", prompt = "unrelated", parent = "a", age = 5 },
  })
  local p = open(dir)
  eq(H.picker_lines(p), { "fix the parser  1  now", "└─ unrelated  1  now", "parser notes  1  now" })
  H.keys("s")
  eq(p.sort, "recent")
  eq(H.picker_lines(p), { "unrelated  1  now", "fix the parser  1  now", "parser notes  1  now" })
  H.keys("n")
  eq(H.picker_lines(p), { "parser notes  1  now" })
  H.keys("n")
  -- Recent keeps recency with a search; relevance puts a name match first.
  require("dyadic.picker").set_query(p, "parser")
  eq(H.picker_lines(p), { "fix the parser  1  now", "parser notes  1  now" })
  H.keys("s")
  eq(p.sort, "relevance")
  eq(H.picker_lines(p), { "parser notes  1  now", "fix the parser  1  now" })
  H.keys("<Esc>")
  eq(p.query, "")
  eq(#H.picker_lines(p), 3)
end)

T("a pause in typing searches the message text in the background", function()
  local dir = sessions({
    { id = "a", prompt = "start", reply = "the Flux capacitor works", age = 10 },
    { id = "b", prompt = "flux in the first message", age = 20 },
    { id = "c", prompt = "nothing here", reply = "capacitor only", age = 30 },
    { id = "d", prompt = "other", name = "flux named", reply = "a capacitor", age = 40 },
  })
  local p = open(dir)
  require("dyadic.picker").set_query(p, "flux capacitor")
  -- At once only the details match: none has both words.
  eq(#p.rows, 0)
  H.wait(function()
    return p.searching == nil and not p.render_pending and #p.rows > 0
  end, 3000, "the text search")
  -- A name match ranks first; words may be split between the name and the text.
  eq(H.picker_lines(p), { "flux named  2  now", "start  2  now" })
  require("dyadic.picker").set_query(p, "")
  eq(#H.picker_lines(p), 4)
end)

T("the preview shows the session under the cursor", function()
  local dir, paths = sessions({
    { id = "s1", prompt = "first   prompt", reply = "the reply", name = "my session", age = 120 },
  })
  local p = open(dir)
  local lines = preview(p)
  eq(lines[1], "my session")
  eq(lines[3], "> first prompt")
  ok(vim.tbl_contains(lines, "  the reply"), vim.inspect(lines))
  ok(vim.tbl_contains(lines, "Messages  2"), vim.inspect(lines))
  ok(vim.tbl_contains(lines, "Updated   2m ago"), vim.inspect(lines))
  ok(vim.tbl_contains(lines, "File      " .. vim.fn.fnamemodify(paths.s1, ":~")), vim.inspect(lines))
  H.keys("p")
  eq(p.preview_win, nil)
  H.keys("p")
  ok(p.preview_win)
end)

T("session names look like titles; unnamed sessions are plain text", function()
  local dir = sessions({ { id = "named", name = "my session", age = 5 }, { id = "plain", age = 50 } })
  local p = open(dir)
  eq(vim.api.nvim_get_hl(0, { name = "DyadicSessionNamed" }).link, "DyadicTitle")
  local function title_groups()
    local ns = vim.api.nvim_get_namespaces().dyadic_picker_preview
    local marks = vim.api.nvim_buf_get_extmarks(p.preview_buf, ns, { 0, 0 }, { 0, -1 }, { details = true })
    return vim.tbl_map(function(mark)
      return mark[4].hl_group
    end, marks)
  end
  eq(title_groups(), { "DyadicSessionNamed" })
  vim.api.nvim_win_set_cursor(p.list_win, { 2, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = p.list_buf })
  H.wait(function()
    return preview(p)[1] == "plain"
  end, 3000, "the unnamed session's preview")
  eq(title_groups(), {})
end)

T("delete asks, refuses sessions live agents show, and copies paths", function()
  local dir, paths = sessions({ { id = "keep", age = 5 }, { id = "drop", age = 50 } })
  local p = open(dir)
  vim.fn.executable = function()
    return 0
  end
  local asked = {}
  vim.fn.confirm = function(message)
    asked[#asked + 1] = message
    return #asked == 1 and 2 or 1
  end
  vim.api.nvim_win_set_cursor(p.list_win, { 2, 0 })
  H.keys("dd")
  eq(vim.uv.fs_stat(paths.drop) ~= nil, true)
  H.keys("dd")
  eq(asked, { 'Delete session "drop"?', 'Delete session "drop"?' })
  eq(vim.uv.fs_stat(paths.drop), nil)
  eq(H.picker_lines(p), { "keep  1  now" })
  H.keys('"ayy')
  eq(vim.fn.getreg("a"), paths.keep)
  -- A session a live agent shows stays.
  p.live[paths.keep] = 7
  H.keys("dd")
  eq(#asked, 2)
  ok(_G.notes[#_G.notes].msg:find("Agent 7 shows this session", 1, true), _G.notes[#_G.notes].msg)
end)

T("/resume switches the agent to the chosen session", function()
  local dir, paths = sessions({ { id = "s1", age = 5 }, { id = "s2", age = 50 } })
  local log = vim.fn.tempname()
  local agent = H.open({ log = log, state = { sessionFile = paths.s1 } }, { args = { "--session-dir", dir } })
  agent.cwd = cwd
  agent:set_draft("/resume")
  agent:submit()
  local p = H.session_picker()
  -- As in pi, the command leaves the composer as it runs.
  eq(agent:get_draft(), "")
  local lines = H.picker_lines(p)
  -- The agent's own session is marked current and with its agent.
  eq(lines[1], "• s1  agent " .. agent.id .. "  1  now")
  -- Choosing the current session changes nothing.
  H.keys("<CR>")
  H.settle()
  eq(agent:get_draft(), "")
  eq(
    vim.iter(H.sent(log)):any(function(record)
      return record.type == "switch_session"
    end),
    false
  )
  agent:set_draft("/resume")
  agent:submit()
  p = H.session_picker()
  vim.api.nvim_win_set_cursor(p.list_win, { 2, 0 })
  H.keys("<CR>")
  H.wait(function()
    return vim.iter(H.sent(log)):any(function(record)
      return record.type == "switch_session" and record.sessionPath == paths.s2
    end)
  end)
  agent:set_draft("/resume all")
  agent:submit()
  H.settle()
  eq(SessionPicker.current(), nil)
  ok(_G.notes[#_G.notes].msg:find("Usage: /resume", 1, true))
  -- A refusal keeps the text to fix.
  eq(agent:get_draft(), "/resume all")
end)

return T
