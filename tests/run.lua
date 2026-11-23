-- Test runner. Each case runs in its own Neovim process, so module state never leaks.
--   nvim --clean -l tests/run.lua [tests/test_x.lua ...]   run files (default: tests/test_*.lua)
-- Internal modes, used by the runner itself:
--   --list <file>          print case names
--   --case <file> <index>  run one case; exit 0 pass, 77 skip, 1 fail
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local args = _G.arg or {}
local SKIP = 77
local JOBS = 8
local CASE_TIMEOUT_MS = tonumber(vim.env.DYADIC_CASE_TIMEOUT_MS) or 30000

vim.opt.runtimepath:prepend(root)

local function load(file)
  local ok, suite = pcall(dofile, file)
  if not ok then
    io.stderr:write(tostring(suite), "\n")
    os.exit(1)
  end
  return suite
end

if args[1] == "--list" then
  for _, case in ipairs(load(args[2]).cases) do
    io.stdout:write(case.name, "\n")
  end
  os.exit(0)
end

if args[1] == "--case" then
  vim.o.swapfile = false
  vim.o.shadafile = "NONE"
  vim.o.columns, vim.o.lines = 80, 24
  _G.notes = {}
  vim.notify = function(msg, level)
    table.insert(_G.notes, { msg = msg, level = level })
  end
  -- Every window dyadic opens for its own buffer is pinned to it (lua/dyadic/pin.lua); only
  -- a history window outside the sidebar is an ordinary window.
  local unpinned = {}
  local open_win = vim.api.nvim_open_win
  vim.api.nvim_open_win = function(...)
    local win = open_win(...)
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      local free_history = name:match("/history$") and not require("dyadic.sidebar").contains(win)
      if name:match("^dyadic://") and not free_history and not vim.wo[win].winfixbuf then
        unpinned[#unpinned + 1] = name
      end
    end)
    return win
  end
  local case = load(args[2]).cases[tonumber(args[3])]
  local ok, err = xpcall(case.fn, debug.traceback)
  vim.wait(10)
  if ok and #unpinned > 0 then
    ok, err = false, "windows not pinned to their buffer: " .. table.concat(unpinned, ", ")
  end
  -- Close agents so fake pi processes exit before this Neovim does.
  pcall(function()
    local dyadic = require("dyadic")
    local agents = dyadic.list()
    dyadic.shutdown()
    vim.wait(2000, function()
      for _, agent in ipairs(agents) do
        if agent.rpc and not agent.rpc._finished then
          return false
        end
      end
      return true
    end, 10)
  end)
  if ok then
    os.exit(0)
  end
  local reason = tostring(err):match("DYADIC_SKIP: ([^\n]*)")
  if reason then
    io.stdout:write(reason)
    os.exit(SKIP)
  end
  io.stderr:write(tostring(err), "\n")
  os.exit(1)
end

-- Parent: collect cases, run them in parallel, report in file order.
local files = {}
for _, file in ipairs(args) do
  files[#files + 1] = file
end
if #files == 0 then
  files = vim.fn.glob("tests/test_*.lua", false, true)
  table.sort(files)
end

local function nvim(extra)
  local cmd = { vim.v.progpath, "--clean", "--headless", "-l", root .. "/tests/run.lua" }
  vim.list_extend(cmd, extra)
  return cmd
end

local cases, by_file = {}, {}
for _, file in ipairs(files) do
  local listed = vim.system(nvim({ "--list", file }), { cwd = root, text = true }):wait()
  if listed.code ~= 0 then
    io.stdout:write(file, ": cannot load\n", listed.stderr or "", "\n")
    os.exit(1)
  end
  by_file[file] = {}
  for index, name in ipairs(vim.split(vim.trim(listed.stdout), "\n", { trimempty = true })) do
    local case = { file = file, index = index, name = name }
    cases[#cases + 1] = case
    table.insert(by_file[file], case)
  end
end

local next_case, running, done = 1, 0, 0
local function start()
  while running < JOBS and next_case <= #cases do
    local case = cases[next_case]
    next_case, running = next_case + 1, running + 1
    vim.system(
      nvim({ "--case", case.file, tostring(case.index) }),
      { cwd = root, text = true, timeout = CASE_TIMEOUT_MS },
      function(result)
        case.result = result
        running, done = running - 1, done + 1
        vim.schedule(start)
      end
    )
  end
end
start()
vim.wait(#cases * CASE_TIMEOUT_MS, function()
  return done == #cases
end, 20)

local failures, skips, passed = {}, {}, 0
for _, file in ipairs(files) do
  local marks = {}
  for _, case in ipairs(by_file[file]) do
    local result = case.result
    if result.code == 0 then
      passed, marks[#marks + 1] = passed + 1, "."
    elseif result.code == SKIP then
      skips[#skips + 1], marks[#marks + 1] = case, "s"
    else
      failures[#failures + 1], marks[#marks + 1] = case, "F"
    end
  end
  io.stdout:write(string.format("%-28s %s\n", file, table.concat(marks)))
end
for _, case in ipairs(skips) do
  io.stdout:write(string.format("\nSKIP %s | %s: %s", case.file, case.name, case.result.stdout or ""))
end
for _, case in ipairs(failures) do
  local result = case.result
  local detail = result.signal ~= 0 and "timed out or killed" or vim.trim(result.stderr or "")
  io.stdout:write(string.format("\n\nFAIL %s | %s\n%s", case.file, case.name, detail))
end
io.stdout:write(string.format("\n\n%d passed, %d failed, %d skipped\n", passed, #failures, #skips))
os.exit(#failures == 0 and 0 or 1)
