local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local api = vim.api
local Composer = require("dyadic.composer")

-- Lines below the draft, as text and highlight groups.
local function footer(agent)
  local ns = api.nvim_get_namespaces().dyadic_widgets
  local out = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(agent.composer_buf, ns, 0, -1, { details = true })) do
    if not mark[4].virt_lines_above then
      for _, line in ipairs(mark[4].virt_lines or {}) do
        local parts, groups = {}, {}
        for _, chunk in ipairs(line) do
          parts[#parts + 1] = chunk[1]
          groups[#groups + 1] = chunk[2]
        end
        out[#out + 1] = { text = table.concat(parts), groups = groups }
      end
    end
  end
  return out
end

local function footer_texts(agent)
  return vim.tbl_map(function(line)
    return line.text
  end, footer(agent))
end

-- A winbar with its highlight items removed.
local function plain(bar)
  return (bar:gsub("%%#[%w_]+#", ""))
end

local function rerender(agent)
  require("dyadic.view").render(agent)
end

T("the history winbar shows the title and pi's working directory", function()
  local agent = H.open()
  local win = H.history_win(agent)
  eq(plain(vim.wo[win].winbar), " %=%</work ")
  agent.state.sessionName = "Fix the CI"
  rerender(agent)
  eq(plain(vim.wo[win].winbar), " Fix the CI%=%</work ")
end)

T("the composer winbar shows the phase and queued messages", function()
  local agent = H.open()
  local win = Composer.window(agent)
  eq(plain(vim.wo[win].winbar), " ready%= ")
  H.emit(agent, {
    { type = "agent_start" },
    { type = "queue_update", steering = { "a", "b" }, followUp = { "c" } },
  })
  H.settle()
  local first = plain(vim.wo[win].winbar)
  ok(vim.tbl_contains(require("dyadic.bars").SPINNER, first:sub(2, 4)), first)
  eq(first:sub(5), " working%=steer 2 · follow-up 1 ")
  H.settle(250)
  ok(plain(vim.wo[win].winbar) ~= first, "the spinner does not turn")
  H.emit(agent, { { type = "agent_settled", aborted = false } })
  H.wait(function()
    return not agent.active
  end)
  H.settle()
  eq(agent._view.spinner, nil)
end)

T("the footer shows context, cost, model, level, and extension statuses", function()
  local agent = H.open()
  agent.state.model = { id = "big-model", provider = "p", reasoning = true, contextWindow = 200000 }
  agent.state.thinkingLevel = "high"
  agent.state.autoCompactionEnabled = true
  agent.stats = { cost = 0.1234, contextUsage = { tokens = 90000, contextWindow = 200000, percent = 45.2 } }
  agent.statuses = { b = "lint ok", a = "git main" }
  rerender(agent)
  eq(footer_texts(agent), { "ctx 45%/200k (auto) · $0.123", "big-model · high", "git main · lint ok" })
  -- After a compaction pi reports no percentage until the next response.
  agent.stats = { cost = 0, contextUsage = { tokens = vim.NIL, contextWindow = 200000, percent = vim.NIL } }
  agent.state.autoCompactionEnabled = false
  agent.state.thinkingLevel = "off"
  agent.statuses = {}
  rerender(agent)
  eq(footer_texts(agent), { "ctx ?/200k", "big-model · thinking off" })
  agent.stats = { contextUsage = { contextWindow = 200000, percent = 91 } }
  rerender(agent)
  eq(footer(agent)[1].groups, { "DyadicFooter", "DyadicError" })
end)

T("the statusline shows the buffer and pi's session ID", function()
  local agent = H.open()
  eq(vim.wo[H.history_win(agent)].statusline, " history · s1")
  eq(vim.wo[Composer.window(agent)].statusline, " composer · s1")
end)

T("statusline = false leaves the statusline alone", function()
  vim.o.statusline = "mine"
  local agent = H.open(nil, { statusline = false })
  eq(vim.wo[H.history_win(agent)].statusline, "mine")
  eq(vim.wo[Composer.window(agent)].statusline, "mine")
end)

return T
