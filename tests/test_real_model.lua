-- End to end against the real pi and its default model: a reviewed edit and change notes.
-- Makes model calls. Run with `just test-real-model`.
local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local api = vim.api
local Review = require("dyadic.review")

local RUN_MS = 240000

local function entries(agent)
  local err, data = H.request(agent, "get_entries")
  assert(not err, err)
  return data.entries
end

local function text_of(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, part in ipairs(content or {}) do
    parts[#parts + 1] = part.text or ""
  end
  return table.concat(parts)
end

-- Send `prompt` and wait for the run to end; `on_review(review)` decides each review,
-- or every hunk is accepted.
local function run(agent, prompt, on_review)
  agent:set_draft(prompt)
  agent:submit()
  H.wait(function()
    return agent.phase ~= "Idle"
  end, 15000, "the run to start")
  H.wait(function()
    local review = Review.first(agent)
    if review and not review.handled then
      review.handled = true
      vim.schedule(function()
        if on_review then
          on_review(review)
        else
          Review.decide(review, true, true)
        end
      end)
    end
    return agent.phase == "Idle"
  end, RUN_MS, "the run to end")
end

T("a reviewed edit and change notes reach the model", function()
  if vim.env.DYADIC_REAL_MODEL ~= "1" then
    H.skip("set DYADIC_REAL_MODEL=1 to run against the real pi and its default model")
  end
  local dir = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")) .. "/real-model-" .. math.random(1e9)
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/a.txt"
  vim.fn.writefile({ "one", "two", "three" }, path)
  vim.cmd.cd(dir)
  local dyadic = require("dyadic")
  dyadic.setup({ args = { "--no-session" }, review = true, change_notes = true })
  local agent = dyadic.open()
  H.wait(function()
    return require("dyadic.bridge").available(agent) and agent.phase == "Idle"
  end, 30000, "pi and the bridge")

  -- 1. The agent edits; during the review the user changes another line, then accepts.
  local reviewed
  run(
    agent,
    "Use the edit tool to replace the line `two` with `TWO` in a.txt. Do not read or change anything else, "
      .. "and do not edit again whatever the result says. Then reply with just DONE.",
    function(review)
      reviewed = review.buf
      api.nvim_buf_set_lines(review.buf, 2, 3, false, { "three (user)" })
      vim.schedule(function()
        Review.decide(review, true, true)
      end)
    end
  )
  ok(reviewed, "the edit was not reviewed")
  eq(api.nvim_buf_get_lines(reviewed, 0, -1, false), { "one", "TWO", "three (user)" })
  ok(vim.bo[reviewed].modified, "a reviewed change stays unsaved")
  eq(vim.fn.readfile(path), { "one", "two", "three" })
  local result
  for _, entry in ipairs(entries(agent)) do
    local message = entry.message
    if message and message.role == "toolResult" and message.toolName == "edit" then
      result = text_of(message.content)
    end
  end
  ok(result, "no edit result")
  ok(result:find("Accepted by the user; unsaved in the editor.", 1, true), result)
  ok(result:find("The file now differs from your version", 1, true), result)
  ok(result:find("+three (user)", 1, true), result)

  -- 2. Between runs the user changes the file; the next run starts with a change note.
  api.nvim_buf_set_lines(reviewed, 0, 1, false, { "one (user)" })
  run(agent, "Reply with just OK.")
  local note
  for _, entry in ipairs(entries(agent)) do
    if entry.type == "custom_message" and entry.customType == "dyadic-changes" then
      note = entry
    end
  end
  ok(note, "no change note in the session")
  ok(text_of(note.content):find("+one (user)", 1, true), text_of(note.content))
  eq(note.details.files, { "a.txt" })
  H.settle()
  H.cursor_to_row(agent, "told the agent: a.txt changed")
end)

return T
