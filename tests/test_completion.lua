local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local Completion = require("dyadic.completion")

-- Items for `line` with the cursor at its end, on draft line `row` (default 1).
local function items(agent, line, opts)
  opts = opts or {}
  local ctx = Completion.context(line, opts.row or 1, #line)
  if not ctx then
    return nil
  end
  local result
  Completion.items(agent, ctx, { sync = not opts.async, match = opts.match or "prefix" }, function(found)
    result = found
  end)
  H.wait(function()
    return result ~= nil
  end, 3000, "completion items")
  return result
end

local function field(list, name)
  return vim.tbl_map(function(item)
    return item[name] or vim.NIL
  end, list)
end

local function labels(list)
  return field(list, "label")
end

local commands = {
  {
    name = "skill:review",
    source = "skill",
    description = "Review a change",
    sourceInfo = { path = "/skills/review/SKILL.md" },
  },
  { name = "handoff", source = "extension", description = "Write a handoff" },
}

-- A project directory in git, so fd and rg read its .gitignore.
local function project()
  local dir = vim.fn.resolve(vim.fn.tempname())
  for path, text in pairs({
    ["a.txt"] = "a",
    ["dir/b.lua"] = "return 1",
    ["my file.md"] = "# title",
    [".hidden"] = "h",
    [".gitignore"] = "ignored.log",
    ["ignored.log"] = "log",
  }) do
    vim.fn.mkdir(vim.fs.dirname(vim.fs.joinpath(dir, path)), "p")
    vim.fn.writefile({ text }, vim.fs.joinpath(dir, path))
  end
  vim.system({ "git", "init", "-q" }, { cwd = dir }):wait()
  return dir
end

T("completes commands on the first line and paths after @", function()
  eq(Completion.context("/mo", 1, 3), { kind = "command", start = 0, query = "/mo" })
  -- pi reads a command only at the start of the draft.
  eq(Completion.context("/mo", 2, 3), nil)
  eq(Completion.context("look at /us", 1, 11), nil)
  eq(Completion.context("plain words", 1, 11), nil)
  eq(Completion.context("/settings au", 1, 12), { kind = "setting", start = 10, query = "au" })
  eq(
    Completion.context("/settings steering a", 1, 20),
    { kind = "value", setting = "steering", start = 19, query = "a" }
  )
  eq(Completion.context("/thinking h", 1, 11), { kind = "thinking", start = 10, query = "h" })
  eq(Completion.context("/model so", 1, 9), { kind = "model", start = 7, query = "so" })
  eq(Completion.context("/compact x", 1, 10), nil)
  eq(Completion.context("/compact see @lu", 1, 16), { kind = "path", start = 13, query = "lu" })
  eq(Completion.context("@", 2, 1), { kind = "path", start = 0, query = "" })
  eq(Completion.context("mail a@b", 1, 8), nil)
  eq(Completion.context('see @"my fi', 1, 11), { kind = "path", start = 4, query = "my fi", quoted = true })
  eq(Completion.context("see @x", 1, 4), nil)
end)

T("commands come with hints, descriptions, and sources, built-ins first, which run on accept", function()
  local agent = H.open({ commands = commands })
  eq(labels(items(agent, "/re")), { "/reload", "/resume" })
  -- Only pi's names: no /stats.
  eq(labels(items(agent, "/s")), { "/session", "/settings", "/skill:review" })
  eq(require("dyadic").complete("q"), {})
  local all = items(agent, "/")
  eq(vim.list_slice(labels(all), #all - 1), { "/handoff", "/skill:review" })
  local model = items(agent, "/model")[1]
  eq(model.word, "/model")
  eq(model.kind, "builtin")
  eq(model.menu, "[provider/model or search]")
  eq(model.doc, "Select a model")
  eq({ model.submit, model.reshow or vim.NIL }, { true, vim.NIL })
  local new = items(agent, "/new")[1]
  eq({ new.word, new.menu or vim.NIL, new.submit }, { "/new", vim.NIL, true })
  -- pi's commands often take text: they only insert.
  local skill = items(agent, "/sk")[1]
  eq({ skill.word, skill.kind, skill.menu }, { "/skill:review ", "skill", "skill" })
  eq(skill.submit, nil)
  eq(skill.doc, "Review a change\n\n`/skills/review/SKILL.md`")
  eq(field(items(agent, "/h"), "kind"), { "extension" })
  -- Fuzzy, for blink.cmp, which ranks the rest itself.
  ok(vim.tbl_contains(labels(items(agent, "/skrev", { match = "fuzzy" })), "/skill:review"))
end)

T("/settings completes names, then values, with current ones", function()
  local agent = H.open({ state = { autoCompactionEnabled = true, steeringMode = "all" } })
  local names = items(agent, "/settings ")
  eq(labels(names), { "auto-compaction", "auto-retry", "steering", "follow-up" })
  eq(field(names, "menu"), { "on", vim.NIL, "all", vim.NIL })
  eq(names[1].word, "auto-compaction ")
  ok(names[1].reshow and names[1].doc:find("Compact", 1, true))
  local values = items(agent, "/settings steering ")
  eq(labels(values), { "all", "one-at-a-time" })
  eq(field(values, "menu"), { "current", vim.NIL })
  -- A value completes the command; a name does not.
  eq({ names[1].submit or vim.NIL, values[1].submit }, { vim.NIL, true })
  eq(items(agent, "/settings bogus "), {})
end)

T("/thinking asks pi for the model's levels; the omnifunc uses the last answer", function()
  local agent = H.open()
  eq(items(agent, "/thinking "), {})
  local levels = items(agent, "/thinking ", { async = true })
  eq(labels(levels), { "off", "low", "high" })
  eq(field(levels, "menu"), { "current", vim.NIL, vim.NIL })
  eq(field(levels, "submit"), { true, true, true })
  eq(labels(items(agent, "/thinking h")), { "high" })
end)

T("/model lists pi's models, the current one first, only asynchronously", function()
  local agent = H.open()
  eq(items(agent, "/model "), {})
  local models = items(agent, "/model ", { async = true })
  eq(labels(models), { "fake/fake-model", "other/small" })
  eq(field(models, "menu"), { "Fake", "Small" })
  eq({ models[1].word, models[1].submit }, { "fake/fake-model", true })
  eq(
    models[1].doc,
    "**Fake**\n\n- Context window: 200k tokens\n- Maximum output: 8.2k tokens\n- Reasoning: yes\n- Images: yes"
  )
  ok(models[2].doc:find("Images: no", 1, true))
  eq(labels(items(agent, "/model sm", { async = true, match = "fuzzy" })), { "other/small" })
end)

T("@ lists the project with fd: hidden files, no .git, no ignored files, directories first", function()
  if vim.fn.executable("fd") == 0 then
    H.skip("fd is not installed")
  end
  local agent = H.open()
  agent.cwd = project()
  local all = items(agent, "@")
  eq(labels(all), { "dir/", ".gitignore", ".hidden", "a.txt", "dir/b.lua", "my file.md" })
  eq(field(all, "kind"), { "directory", "file", "file", "file", "file", "file" })
  eq(all[5].path, vim.fs.joinpath(agent.cwd, "dir/b.lua"))
  eq(labels(items(agent, "see @b.l")), { "dir/b.lua" })
  eq(field(items(agent, "@my"), "word"), { '@"my file.md"' })
  eq(field(items(agent, '@"b.l'), "word"), { '@"dir/b.lua"' })
end)

T("@ falls back to rg, then to walking the directory", function()
  local agent = H.open()
  agent.cwd = project()
  if vim.fn.executable("rg") == 1 then
    Completion.listers = { "rg" }
    eq(labels(items(agent, "@")), { ".gitignore", ".hidden", "a.txt", "dir/b.lua", "my file.md" })
    Completion.forget(agent)
  end
  Completion.listers = {}
  eq(
    labels(items(agent, "@", { async = true })),
    { "dir/", ".gitignore", ".hidden", "a.txt", "dir/b.lua", "ignored.log", "my file.md" }
  )
end)

T("@ keeps its listing until the composer leaves Insert mode", function()
  local agent = H.open()
  agent.cwd = project()
  Completion.listers = {}
  eq(#items(agent, "@", { async = true }), 7)
  vim.fn.writefile({ "new" }, vim.fs.joinpath(agent.cwd, "new.txt"))
  eq(#items(agent, "@"), 7)
  vim.api.nvim_exec_autocmds("InsertLeave", { buffer = agent.composer_buf })
  eq(#items(agent, "@"), 8)
end)

T("the omnifunc completes the same places, with menus and descriptions", function()
  local agent = H.open({ commands = commands })
  agent.cwd = project()
  Completion.listers = {}
  require("dyadic.view").focus(agent, true)
  eq(vim.bo.omnifunc, "v:lua.require'dyadic.completion'.omnifunc")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "/re", "/re", "see @b.l" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  eq(Completion.omnifunc(1, ""), 0)
  local submit = { dyadic = { submit = true } }
  eq(Completion.omnifunc(0, "/re"), {
    {
      word = "/reload",
      abbr = "/reload",
      info = "Reload pi's extensions, skills, prompts, and context files",
      user_data = submit,
    },
    {
      word = "/resume",
      abbr = "/resume",
      info = "Switch to a saved session with the session picker",
      user_data = submit,
    },
  })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  eq(Completion.omnifunc(1, ""), -3)
  vim.api.nvim_win_set_cursor(0, { 3, 8 })
  eq(Completion.omnifunc(1, ""), 4)
  eq(Completion.omnifunc(0, "@b.l"), {
    { word = "@dir/b.lua", abbr = "dir/b.lua", info = vim.fn.fnamemodify(agent.cwd, ":~") .. "/dir/b.lua", equal = 1 },
  })
end)

T("accepting an omnifunc item that completes a command submits it", function()
  local agent = H.open()
  require("dyadic.view").focus(agent, true)
  -- Only CTRL-Y accepts; other ways to end completion leave the draft.
  agent:set_draft("/na")
  H.keys("A<C-x><C-o><Esc>")
  H.settle()
  eq(agent:get_draft(), "/name")
  agent:set_draft("/na")
  H.keys("A<C-x><C-o> x<Esc>")
  H.settle()
  eq(agent:get_draft(), "/name x")
  agent:set_draft("/na")
  H.keys("A<C-x><C-o><C-y>")
  H.wait(function()
    return vim.iter(_G.notes):any(function(note)
      return note.msg == "Dyadic: Session name: unnamed"
    end)
  end, 3000, "the session name")
  eq(agent:get_draft(), "")
  eq(vim.api.nvim_get_mode().mode, "n")
end)

T("completion = false leaves the composer alone", function()
  local agent = H.open(nil, { completion = false })
  eq(vim.bo[agent.composer_buf].omnifunc, "")
  eq(Completion.agent(agent.composer_buf), nil)
end)

T("previews show the start of a file or a directory's size", function()
  local dir = project()
  eq(Completion.preview(vim.fs.joinpath(dir, "dir/b.lua")), "```lua\nreturn 1\n```")
  eq(Completion.preview(vim.fs.joinpath(dir, "dir")), "1 entry")
  local fenced = vim.fs.joinpath(dir, "fenced.md")
  vim.fn.writefile({ "```sh", "ls", "```" }, fenced)
  eq(Completion.preview(fenced), "````markdown\n```sh\nls\n```\n````")
  local binary = vim.fs.joinpath(dir, "binary")
  vim.fn.writefile({ "a\nb" }, binary)
  eq(Completion.preview(binary), "Binary file")
end)

-- blink.cmp, as far as the source uses it.
local function stub_blink(providers)
  local calls = { shown = {}, providers = {}, filetypes = {} }
  package.loaded["blink.cmp.types"] = {
    CompletionItemKind = { Module = 9, Keyword = 14, Value = 12, File = 17, Reference = 18, Folder = 19 },
  }
  package.loaded["blink.cmp.config"] = { sources = { providers = providers or {} } }
  package.loaded["blink.cmp"] = {
    show = function(opts)
      table.insert(calls.shown, opts)
    end,
    add_source_provider = function(id, config)
      calls.providers[id] = config
      package.loaded["blink.cmp.config"].sources.providers[id] = config
    end,
    add_filetype_source = function(filetype, id)
      table.insert(calls.filetypes, { filetype, id })
    end,
  }
  return calls
end

T("the blink.cmp source registers itself when a composer enters Insert mode", function()
  local calls = stub_blink()
  local agent = H.open()
  vim.api.nvim_exec_autocmds("InsertEnter", { buffer = agent.composer_buf })
  vim.api.nvim_exec_autocmds("InsertEnter", { buffer = agent.composer_buf })
  eq(calls.providers, { dyadic = { name = "Dyadic", module = "dyadic.completion.blink" } })
  eq(calls.filetypes, { { "dyadic_composer", "dyadic" } })
end)

T("a blink.cmp source configured by hand keeps its id", function()
  local calls = stub_blink({ mine = { module = "dyadic.completion.blink" } })
  local agent = H.open()
  vim.api.nvim_exec_autocmds("InsertEnter", { buffer = agent.composer_buf })
  eq(calls.providers, {})
  eq(calls.filetypes, { { "dyadic_composer", "mine" } })
end)

T("the blink.cmp source answers in the composer only", function()
  local calls = stub_blink({ dyadic = { module = "dyadic.completion.blink" } })
  local agent = H.open({ commands = commands })
  local source = require("dyadic.completion.blink").new()
  eq(source:get_trigger_characters(), { "/", "@" })
  vim.api.nvim_set_current_buf(agent.history_buf)
  ok(not source:enabled())
  require("dyadic.view").focus(agent, true)
  ok(source:enabled())
  local response
  source:get_completions({ bufnr = agent.composer_buf, line = "/mo", cursor = { 1, 3 } }, function(found)
    response = found
  end)
  eq(response.is_incomplete_backward, true)
  eq(response.items[1], {
    label = "/model",
    filterText = "/model",
    sortText = "1 model",
    kind = 14,
    textEdit = {
      newText = "/model",
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
    },
    labelDetails = { description = "[provider/model or search]" },
    documentation = { kind = "markdown", value = "Select a model" },
    data = { dyadic = { submit = true } },
  })
  response = nil
  source:get_completions({ bufnr = agent.composer_buf, line = "/settings ", cursor = { 1, 10 } }, function(found)
    response = found
  end)
  local setting = response.items[1]
  eq(setting.data, { dyadic = { reshow = true } })
  response = nil
  source:get_completions({ bufnr = agent.composer_buf, line = "plain", cursor = { 1, 5 } }, function(found)
    response = found
  end)
  eq(response.items, {})

  -- Accepting a setting name opens its values, once the cursor moved.
  local defaulted, done = false, false
  source:execute({}, setting, function()
    done = true
  end, function()
    defaulted = true
  end)
  H.settle()
  ok(defaulted and done)
  eq(calls.shown, {})
  vim.api.nvim_exec_autocmds("CursorMovedI", { buffer = agent.composer_buf })
  H.settle()
  eq(calls.shown, { { providers = { "dyadic" } } })
  -- Accepting what completes a command submits it.
  agent:set_draft("/name")
  source:execute({}, { data = { dyadic = { submit = true } } }, function() end, function() end)
  H.wait(function()
    return vim.iter(_G.notes):any(function(note)
      return note.msg == "Dyadic: Session name: unnamed"
    end)
  end, 3000, "the session name")
  eq(agent:get_draft(), "")
  -- A file gets a preview.
  local resolved
  local path = vim.fs.joinpath(project(), "a.txt")
  source:resolve({ label = "a.txt", data = { dyadic = { path = path } } }, function(item)
    resolved = item
  end)
  eq(resolved.documentation, { kind = "markdown", value = "```text\na\n```" })
end)

T("real blink.cmp completes commands, arguments, and paths in the composer", function()
  local blink = vim.env.DYADIC_BLINK or vim.fn.expand("~/.local/share/nvim/lazy/blink.cmp")
  if vim.fn.isdirectory(blink) == 0 then
    H.skip("blink.cmp is not installed; set DYADIC_BLINK")
  end
  -- blink.cmp reacts to typed keys, which only an idle Neovim reads: drive a child.
  local child = vim.fn.jobstart({ vim.v.progpath, "--clean", "--embed", "--headless" }, { rpc = true })
  local function lua(code, ...)
    return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
  end
  local ready = lua(
    [[
    local root, blink, cwd, commands = ...
    vim.opt.runtimepath:prepend(root)
    vim.opt.runtimepath:prepend(blink)
    vim.o.swapfile = false
    require("blink.cmp").setup({ sources = { default = {} } })
    local H = dofile(root .. "/tests/helpers.lua")
    _G.agent = H.open({ commands = commands })
    _G.agent.cwd = cwd
    require("dyadic.view").focus(agent, true)
    -- blink.cmp finishes its setup asynchronously.
    return vim.wait(5000, function()
      return require("blink.cmp.completion.trigger").buffer_events ~= nil
    end, 10)
  ]],
    H.root,
    blink,
    project(),
    commands
  )
  ok(ready, "blink.cmp set up")
  local function menu()
    local found
    vim.wait(3000, function()
      found = lua([[
        local cmp = require("blink.cmp")
        return cmp.is_menu_visible() and vim.tbl_map(function(item)
          return item.label
        end, cmp.get_items()) or nil
      ]])
      return found ~= vim.NIL and found ~= nil and #found > 0
    end, 20)
    return found ~= vim.NIL and found or {}
  end
  local function press(keys)
    vim.rpcrequest(child, "nvim_input", keys)
    vim.wait(50)
  end
  local function draft()
    vim.wait(200)
    return lua("return vim.api.nvim_buf_get_lines(_G.agent.composer_buf, 0, -1, false)")
  end
  local function sent(kind)
    return lua("return vim.tbl_contains(_G.sent, ...)", kind)
  end
  lua([[
    _G.sent = {}
    local request = _G.agent.request
    _G.agent.request = function(self, kind, ...)
      table.insert(_G.sent, kind)
      return request(self, kind, ...)
    end
  ]])
  local ok_run, err = pcall(function()
    -- Accepting a built-in runs it, in Normal mode.
    press("i/ses")
    eq(menu()[1], "/session")
    press("<C-y>")
    eq(draft(), { "" })
    ok(vim.wait(3000, function()
      return sent("get_session_stats")
    end, 20))
    eq(lua("return vim.api.nvim_get_mode().mode"), "n")
    -- A setting name opens its values; a value runs the command.
    press("S/settings st")
    eq(menu(), { "steering" })
    press("<C-y>")
    eq(menu(), { "all", "one-at-a-time" })
    press("<C-y>")
    ok(vim.wait(3000, function()
      return sent("set_steering_mode")
    end, 20))
    eq(draft(), { "" })
    -- blink.cmp ranks them itself; the current model leads only on a tie.
    press("S/model oth")
    eq(menu(), { "other/small" })
    press("<C-y>")
    ok(vim.wait(3000, function()
      return sent("set_model")
    end, 20))
    -- pi's commands only insert.
    press("S/sk")
    eq(menu(), { "/skill:review" })
    press("<C-y>")
    vim.wait(100)
    press("<Esc>")
    eq(draft(), { "/skill:review " })
    -- `.` is no keyword character: blink.cmp asks again, with the whole path typed.
    press("Ssee @dir/b.l")
    eq(menu(), { "dir/b.lua" })
    press("<C-y>")
    vim.wait(100)
    press("<Esc>")
    eq(draft(), { "see @dir/b.lua" })
    press('o@"my')
    eq(menu(), { "my file.md" })
    press("<C-y>")
    vim.wait(100)
    press("<Esc>")
    eq(draft()[2], '@"my file.md"')
  end)
  lua("require('dyadic').shutdown()")
  vim.fn.jobstop(child)
  if not ok_run then
    error(err, 0)
  end
end)

return T
