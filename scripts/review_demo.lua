-- Try reviews by hand: an agent backed by the fake pi proposes changes to sample files, the
-- same way pi's edit and write tools do through the bridge.
--
--   just demo-review             with your own config (colorscheme, keymaps)
--   just demo-review --clean     without it
--
-- Commands:
--   :ReviewDemo [name]   propose a change; without a name, every one. Names:
--                        edit   several hunks in sample.lua: changed words, added lines,
--                               a removed function, a changed last line
--                        long   a long, wrapped line and a tab-indented block in notes.txt
--                        top    a change on the first line of top.txt
--                        new    a new file, new.md, through write
--                        remove lines removed and nothing added, in list.txt: at the
--                               top, in the middle, and at the end
--   :ReviewDemo reset    put the sample files back (and close their buffers)
-- What the model would be told shows as a notification when a review ends.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
if not vim.tbl_contains(vim.opt.runtimepath:get(), root) then
  vim.opt.runtimepath:prepend(root)
  vim.cmd("runtime plugin/dyadic.lua")
end
local api = vim.api

local dir = vim.fn.tempname() .. "-review-demo"
vim.fn.mkdir(dir, "p")
dir = vim.uv.fs_realpath(dir)

local samples = {
  ["sample.lua"] = {
    "local M = {}",
    "",
    "function M.greet(name)",
    '  print("hello " .. name)',
    "end",
    "",
    "function M.add(a, b)",
    "  return a + b",
    "end",
    "",
    "function M.unused()",
    "  local x = 1",
    "end",
    "",
    "return M",
  },
  ["notes.txt"] = {
    "Notes",
    "",
    "The review shows removed lines above the added ones, and this line is long enough that it wraps in most windows, so the removed copy has to wrap the same way to stay readable.",
    "",
    "\tif ready then",
    "\t\tstart()",
    "\tend",
  },
  ["top.txt"] = { "first line", "second line", "third line" },
  ["list.txt"] = {
    "header to remove",
    "another header line to remove",
    "one",
    "two",
    "three",
    "a middle line to remove",
    "four",
    "five",
    "six",
    "a footer line to remove",
    "another footer line to remove",
  },
}

local proposals = {
  edit = {
    path = "sample.lua",
    tool = "edit",
    content = {
      "local M = {}",
      "",
      "-- Greets someone by name.",
      "function M.greet(name)",
      '  print(("hello %s"):format(name))',
      "end",
      "",
      "function M.add(a, b)",
      "  return a + b",
      "end",
      "",
      "return setmetatable(M, { __index = error })",
    },
  },
  long = {
    path = "notes.txt",
    tool = "edit",
    content = {
      "Notes",
      "",
      "The review shows removed lines above the added ones, and this line is long enough that it wraps in narrow windows, so the removed copy wraps the same way and stays readable.",
      "",
      "\tif ready and not started then",
      "\t\tstart()",
      "\tend",
    },
  },
  top = {
    path = "top.txt",
    tool = "edit",
    content = { "first line, changed", "second line", "third line" },
  },
  remove = {
    path = "list.txt",
    tool = "edit",
    content = { "one", "two", "three", "four", "five", "six" },
  },
  new = {
    path = "new.md",
    tool = "write",
    content = { "# New file", "", "Written by the agent; reject it and the buffer goes away." },
  },
}

local function reset()
  for name, lines in pairs(samples) do
    local path = dir .. "/" .. name
    local buf = vim.fn.bufnr(path)
    if buf > 0 then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
    vim.fn.writefile(lines, path)
  end
  local new = vim.fn.bufnr(dir .. "/new.md")
  if new > 0 then
    pcall(api.nvim_buf_delete, new, { force = true })
  end
  vim.fn.delete(dir .. "/new.md")
end
reset()

local scenario = vim.fn.tempname() .. "-review-demo-scenario.lua"
vim.fn.writefile({
  "return { state = { sessionName = 'Review demo' }, entries = {",
  "  { type = 'message', id = 'e1', message = { role = 'user', content = 'Tidy up the sample files.' } },",
  "} }",
}, scenario)

vim.cmd.cd(dir)
local dyadic = require("dyadic")
dyadic.setup({
  cmd = { vim.v.progpath, "--clean", "-l", root .. "/tests/fakepi.lua", scenario },
  review = true,
})

-- Show what the model would be told when a review ends.
local Bridge = require("dyadic.bridge")
local apply = Bridge.handlers.apply
Bridge.handlers.apply = function(agent, request, reply)
  apply(agent, request, function(value, err)
    local name = vim.fn.fnamemodify(request.path, ":t")
    local text = err and ("error: " .. tostring(err))
      or value.error and ("error: " .. value.error)
      or table.concat(
        vim.tbl_filter(function(part)
          return part ~= nil
        end, { value.text or "pi's own result", value.note }),
        "\n"
      )
    vim.notify(name .. " → the model is told:\n" .. text, vim.log.levels.INFO)
    reply(value, err)
  end)
end

vim.cmd.edit(vim.fn.fnameescape(dir .. "/sample.lua"))
local agent = dyadic.open()
vim.wait(5000, function()
  return agent.state.sessionId ~= nil and agent.phase == "Idle"
end, 20)
-- Start in the file, not the composer.
api.nvim_set_current_win(require("dyadic.sidebar").main_window())

local ids = 0
local function propose(name)
  local proposal = proposals[name]
  local path = dir .. "/" .. proposal.path
  local content = table.concat(proposal.content, "\n") .. "\n"
  local function request(kind, fields)
    ids = ids + 1
    return {
      type = "extension_ui_request",
      id = "demo-" .. ids,
      method = "input",
      title = "dyadic.bridge",
      placeholder = vim.json.encode(
        vim.tbl_extend("force", { kind = kind, path = path, tool = proposal.tool }, fields)
      ),
    }
  end
  -- prepare and apply arrive in order, as when pi runs the tool.
  agent:request("test_emit", { events = { request("prepare", {}), request("apply", { content = content }) } })
end

local order = { "edit", "long", "top", "remove", "new" }
api.nvim_create_user_command("ReviewDemo", function(opts)
  local name = opts.args
  if name == "reset" then
    require("dyadic.review").abort(agent)
    reset()
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/sample.lua"))
    return
  end
  if name ~= "" and not proposals[name] then
    vim.notify("ReviewDemo: unknown proposal " .. name, vim.log.levels.ERROR)
    return
  end
  for _, each in ipairs(name == "" and order or { name }) do
    propose(each)
  end
end, {
  nargs = "?",
  complete = function()
    return vim.list_extend(vim.deepcopy(order), { "reset" })
  end,
})

vim.schedule(function()
  propose("edit")
  vim.notify(
    "Review demo in " .. dir .. "\n:ReviewDemo [edit|long|top|remove|new|reset]; :Dyadic review jumps to a hunk",
    vim.log.levels.INFO
  )
end)
