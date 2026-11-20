local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local api = vim.api

local function file(lines)
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile(lines, path)
  return vim.uv.fs_realpath(path)
end

local function open_agent()
  local log = vim.fn.tempname()
  local agent = H.open({ log = log })
  return agent, log
end

local function edit(path)
  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  return api.nvim_get_current_buf()
end

T("read answers with a buffer's text only while it has unsaved changes", function()
  local agent, log = open_agent()
  local path = file({ "one", "two" })
  eq(H.bridge(agent, log, { kind = "read", path = path }), { ok = true, value = vim.NIL })
  local buf = edit(path)
  eq(H.bridge(agent, log, { kind = "read", path = path }).value, vim.NIL)
  api.nvim_buf_set_lines(buf, 0, 1, false, { "ONE" })
  eq(H.bridge(agent, log, { kind = "read", path = path }).value, "ONE\ntwo\n")
end)

T("prepare sends files without a buffer to the disk", function()
  local agent, log = open_agent()
  local path = file({ "one" })
  eq(H.bridge(agent, log, { kind = "prepare", path = path, tool = "edit" }).value, { mode = "disk" })
  edit(path)
  eq(H.bridge(agent, log, { kind = "prepare", path = path, tool = "edit" }).value, { mode = "buffer", text = "one\n" })
end)

T("apply changes an open file's buffer hunk by hunk and saves it", function()
  local agent, log = open_agent()
  local path = file({ "a", "b", "c", "d", "e" })
  local buf = edit(path)
  -- A mark on an untouched line stays put; the user's unsaved change is saved too.
  api.nvim_buf_set_mark(buf, "x", 5, 0, {})
  api.nvim_buf_set_lines(buf, 0, 1, false, { "A" })
  local answer = H.bridge(agent, log, { kind = "apply", path = path, content = "A\nB\nc\nd\ne\nf\n", tool = "edit" })
  eq(answer, { ok = true, value = {} })
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), { "A", "B", "c", "d", "e", "f" })
  eq(vim.fn.readfile(path), { "A", "B", "c", "d", "e", "f" })
  eq(vim.bo[buf].modified, false)
  eq(api.nvim_buf_get_mark(buf, "x"), { 5, 0 })
  -- One undo reverts the agent's change, leaving the user's.
  api.nvim_buf_call(buf, function()
    vim.cmd("silent undo")
  end)
  eq(api.nvim_buf_get_lines(buf, 0, -1, false), { "A", "b", "c", "d", "e" })
end)

T("apply runs save hooks such as formatters", function()
  local agent, log = open_agent()
  local path = file({ "x" })
  local buf = edit(path)
  api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    callback = function()
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(string.upper, api.nvim_buf_get_lines(buf, 0, -1, false)))
    end,
  })
  H.bridge(agent, log, { kind = "apply", path = path, content = "y\n", tool = "edit" })
  eq(vim.fn.readfile(path), { "Y" })
end)

T("apply keeps a missing final newline and writes new files", function()
  local agent, log = open_agent()
  local path = file({ "x" })
  local buf = edit(path)
  H.bridge(agent, log, { kind = "apply", path = path, content = "x\ny", tool = "write" })
  eq(vim.bo[buf].eol, false)
  ok(not vim.bo[buf].fixeol or vim.fn.readfile(path, "b")[2] == "y")
  -- A buffer for a file that does not exist yet is saved with its directories.
  local new = vim.fn.tempname() .. "/sub/new.txt"
  local new_buf = edit(new)
  eq(H.bridge(agent, log, { kind = "prepare", path = new, tool = "write" }).value.mode, "buffer")
  H.bridge(agent, log, { kind = "apply", path = new, content = "hello\n", tool = "write" })
  eq(vim.fn.readfile(new), { "hello" })
  eq(vim.bo[new_buf].modified, false)
end)

T("malformed and unknown requests get errors", function()
  local agent, log = open_agent()
  eq(H.bridge(agent, log, { kind = "nope" }).ok, false)
end)

return T
