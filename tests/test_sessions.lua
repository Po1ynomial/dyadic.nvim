local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local Sessions = require("dyadic.sessions")

local function write(path, records)
  vim.fn.writefile(vim.tbl_map(vim.json.encode, records), path)
end

local function message(role, content, extra)
  return vim.tbl_extend("force", { type = "message", message = { role = role, content = content } }, extra or {})
end

-- Load `paths` and wait for the end; returns the details by path.
local function load(paths)
  local found, done = {}, false
  Sessions.load(paths, function(details)
    found[details.path] = details
  end, function()
    done = true
  end)
  H.wait(function()
    return done
  end, 5000, "loading")
  return found
end

T("loads session details in worker threads as pi lists them", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local main, other, broken = dir .. "/main.jsonl", dir .. "/fork.jsonl", dir .. "/broken.jsonl"
  local long = string.rep("é", 400)
  write(main, {
    { type = "session", id = "s-main", cwd = "/work", timestamp = "2026-01-02T03:04:05Z" },
    { type = "model_change", provider = "p", modelId = "m1" },
    { type = "message", message = { role = "user", content = "first   question\nhere", timestamp = 1000 } },
    {
      type = "message",
      message = {
        role = "assistant",
        content = { { type = "text", text = "answer" } },
        provider = "p",
        model = "m2",
        timestamp = 2000,
      },
    },
    { type = "message", message = { role = "toolResult", content = { { type = "text", text = "big output" } } } },
    { type = "session_info", name = "  named  " },
    { type = "thinking_level_change", thinkingLevel = "high" },
    { type = "message", message = { role = "user", content = long, timestamp = 3000 } },
  })
  write(other, {
    { type = "session", id = "s-fork", cwd = "/work", parentSession = main },
    { type = "session_info", name = "old" },
    { type = "session_info", name = "" },
  })
  vim.fn.writefile({ "not json" }, broken)
  local found = load({ main, other, broken })
  eq(vim.tbl_count(found), 2)
  local details = found[main]
  eq(details.id, "s-main")
  eq(details.cwd, "/work")
  eq(details.created, "2026-01-02T03:04:05Z")
  eq(details.name, "named")
  eq(details.count, 4)
  eq(details.first, "first question here")
  eq(details.last_assistant, "answer")
  eq(details.model, "p/m2")
  eq(details.thinking, "high")
  eq(details.modified, 3)
  -- Text is cut at a character boundary.
  ok(vim.fn.strchars(details.last_user) == 250, details.last_user)
  eq(found[other].parent, main)
  -- A cleared name counts, as in pi.
  eq(found[other].name, nil)
  ok(found[other].modified > 0)
end)

T("cached details come at once until a file changes", function()
  local path = vim.fn.tempname() .. ".jsonl"
  write(path, { { type = "session", id = "a", cwd = "/work" }, message("user", "one") })
  load({ path })
  local now = {}
  Sessions.load({ path }, function(details)
    now[#now + 1] = details.first
  end)
  eq(now, { "one" })
  write(path, { { type = "session", id = "a", cwd = "/work" }, message("user", "two") })
  vim.uv.fs_utime(path, os.time() + 60, os.time() + 60)
  eq(load({ path })[path].first, "two")
end)

T("cancelling stops files not started yet", function()
  local paths = {}
  for index = 1, 40 do
    paths[index] = vim.fn.tempname() .. ".jsonl"
    write(paths[index], { { type = "session", id = "s" .. index, cwd = "/work" } })
  end
  local count, done = 0, false
  local handle = Sessions.load(paths, function()
    count = count + 1
  end, function()
    done = true
  end)
  handle:cancel()
  H.wait(function()
    return done
  end)
  ok(count < 40, "loaded " .. count)
end)

return T
