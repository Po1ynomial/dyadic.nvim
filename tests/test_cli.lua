local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local Cli = require("dyadic.cli")

local function messages()
  return vim.tbl_map(function(note)
    return note.msg
  end, _G.notes)
end

-- Session files for `cwd` in a session directory, newest last.
local function sessions(specs)
  local dir = vim.fn.tempname() .. "-sessions"
  vim.fn.mkdir(dir, "p")
  local paths = {}
  for index, spec in ipairs(specs) do
    local path = dir .. "/" .. spec.id .. ".jsonl"
    vim.fn.writefile({
      vim.json.encode({ type = "session", id = spec.id, cwd = spec.cwd, timestamp = "2026-01-01" }),
      vim.json.encode({ type = "message", id = "m", message = { role = "user", content = spec.prompt or spec.id } }),
    }, path)
    vim.uv.fs_utime(path, os.time() + index, os.time() + index)
    paths[spec.id] = path
  end
  return dir, paths
end

-- The agent :Dyadic started, ready.
local function started()
  local agents = require("dyadic").list()
  ok(#agents == 1, "expected one agent, got " .. #agents)
  return H.ready(agents[1])
end

T("splits words like a shell", function()
  eq(Cli.split([[--model 'a b' --name "say \"hi\"" x\ y]]), { "--model", "a b", "--name", 'say "hi"', "x y" })
  eq(Cli.split("--session ~/s.jsonl '~/kept'"), { "--session", vim.uv.os_homedir() .. "/s.jsonl", "~/kept" })
  eq({ Cli.split("--name 'open") }, { nil, "unterminated '" })
end)

T("reads flag values and messages as pi does", function()
  local parsed = Cli.parse({ "--model", "@m", "--ssh", "host", "fix", "--no-session", "it", "--", "-x", "@f" })
  eq(parsed.messages, { "fix", "it", "-x" })
  eq(parsed.files, { "@f" })
  eq(parsed.has("--model").value, "@m")
  eq(parsed.has("--ssh").value, "host")
end)

T(":Dyadic with flags starts an agent with them and drafts the messages", function()
  H.configure({}, { args = { "--offline" } })
  require("dyadic").command("-c --model 'fake/one' fix the test -- and the 'docs'")
  local agent = started()
  eq(agent.args, { "--offline", "-c", "--model", "fake/one" })
  eq(agent:get_draft(), "fix the test and the docs")
  -- `new` is plain pi, with only `args` from setup().
  require("dyadic").command("new")
  eq(require("dyadic").list()[2].args, { "--offline" })
end)

T("arguments that start no agent are refused", function()
  H.configure()
  local dyadic = require("dyadic")
  for _, text in ipairs({ "-p hello", "--list-models", "--mode json", "-c @notes.md", "--fork abc -c" }) do
    dyadic.command(text)
  end
  eq(#dyadic.list(), 0)
  eq(messages(), {
    "Dyadic: -p does not start an agent. Run `pi -p` in a terminal",
    "Dyadic: --list-models does not start an agent. Run `pi --list-models` in a terminal",
    "Dyadic: --mode does not start an agent. Run `pi --mode` in a terminal",
    "Dyadic: @notes.md: @file arguments are not supported. Mention the file in the composer",
    "Dyadic: --fork cannot be combined with --continue",
  })
  ok(not pcall(dyadic.setup, { args = { "--mode", "json" } }))
  ok(not pcall(dyadic.setup, { args = { "--", "hello" } }))
end)

T("-r picks a session of this directory and opens it", function()
  local cwd = vim.fn.getcwd()
  local dir, paths = sessions({ { id = "old", cwd = cwd }, { id = "new", cwd = cwd }, { id = "x", cwd = "/other" } })
  H.configure({}, { args = { "--session-dir", dir, "-r" } })
  local listed
  vim.ui.select = function(items, opts, choose)
    listed = vim.tbl_map(opts.format_item, items)
    choose(items[2])
  end
  require("dyadic").command("--offline")
  eq(#listed, 2)
  ok(listed[1]:match("^new"), listed[1])
  eq(started().args, { "--session-dir", dir, "--offline", "--session", paths.old })
end)

T("-r opens nothing when the picker is cancelled", function()
  local dir = sessions({ { id = "a", cwd = vim.fn.getcwd() } })
  H.configure({}, { args = { "--session-dir", dir } })
  vim.ui.select = function(_, _, choose)
    choose(nil)
  end
  require("dyadic").command("-r")
  eq(#require("dyadic").list(), 0)
  -- The Lua API never asks.
  eq(require("dyadic").open({ "-r" }), nil)
  eq(messages(), { "Dyadic: -r and session IDs from other directories need :Dyadic" })
end)

T("--session IDs resolve as pi resolves them", function()
  local cwd = vim.fn.getcwd()
  local dir, paths = sessions({ { id = "abc123", cwd = cwd }, { id = "def456", cwd = "/other" } })
  H.configure({}, { args = { "--session-dir", dir } })
  local dyadic = require("dyadic")
  local prompts = {}
  vim.ui.select = function(items, opts, choose)
    prompts[#prompts + 1] = opts.prompt
    choose(items[1])
  end
  -- This directory's sessions go to pi unchanged.
  dyadic.command("--session abc")
  eq(started().args, { "--session-dir", dir, "--session", "abc" })
  dyadic.list()[1]:close()
  -- Another directory's session is forked into this one, after asking.
  dyadic.command("--session def")
  eq(prompts, { "Session found in /other. Fork it into this directory?" })
  eq(started().args, { "--session-dir", dir, "--fork", paths.def456 })
  dyadic.list()[1]:close()
  dyadic.command("--session zzz")
  eq(#dyadic.list(), 0)
  eq(messages()[#messages()], "Dyadic: No session found matching 'zzz'")
end)

T("completes pi's flags and their values", function()
  local dyadic = require("dyadic")
  eq(dyadic.complete("--mo", {}), { "--model", "--models" })
  eq(dyadic.complete("h", { "--thinking" }), { "high" })
  ok(vim.tbl_contains(dyadic.complete("tes", { "-c", "--session" }), "tests/"))
  eq(dyadic.complete("x", { "-c" }), {})
  ok(vim.tbl_contains(dyadic.complete("", {}), "toggle"))
  eq(dyadic.complete("", { "toggle" }), {})
end)

return T
