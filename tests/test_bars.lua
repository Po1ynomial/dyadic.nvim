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
  eq(plain(vim.wo[win].winbar), " %=/work ")
  agent.state.sessionName = "Fix the CI"
  rerender(agent)
  eq(plain(vim.wo[win].winbar), " Fix the CI%=/work ")
end)

T("the history winbar shortens the directory, then drops it, then cuts the title", function()
  local Bars = require("dyadic.bars")
  local agent = H.open()
  agent.cwd = vim.fn.expand("~") .. "/projects/nvim-plugins/dyadic.nvim"
  agent.state.sessionName = "completion and hl"
  local function bar(width)
    return plain(Bars.history_winbar(agent, width))
  end
  -- One space at each end, at least two between.
  eq(bar(56), " completion and hl%=~/projects/nvim-plugins/dyadic.nvim ")
  eq(bar(55), " completion and hl%=~/p/nvim-plugins/dyadic.nvim ")
  eq(bar(38), " completion and hl%=~/p/n/dyadic.nvim ")
  eq(bar(37), " completion and hl%=dyadic.nvim ")
  eq(bar(31), " completion and hl%= ")
  eq(bar(10), " complet…%= ")
  agent.cwd = "/srv/.config/app"
  eq(bar(36), " completion and hl%=/s/.config/app ")
  eq(bar(34), " completion and hl%=/s/.c/app ")
  agent.state.sessionName = nil
  eq(bar(12), " %=/s/.c/app ")
  -- Fitted to each window, again when windows change size.
  local win = H.history_win(agent)
  vim.api.nvim_win_set_width(win, 12)
  vim.api.nvim_exec_autocmds("WinResized", {})
  eq(plain(vim.wo[win].winbar), " %=/s/.c/app ")
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
  -- The level has its color, as pi's editor border; the rest stays gray.
  eq(footer(agent)[2].groups, { "DyadicFooter", "DyadicFooter", "DyadicThinkingHigh" })
  -- After a compaction pi reports no percentage until the next response.
  agent.stats = { cost = 0, contextUsage = { tokens = vim.NIL, contextWindow = 200000, percent = vim.NIL } }
  agent.state.autoCompactionEnabled = false
  agent.state.thinkingLevel = "off"
  agent.statuses = {}
  rerender(agent)
  eq(footer_texts(agent), { "ctx ?/200k", "big-model · thinking off" })
  eq(footer(agent)[2].groups[3], "DyadicThinkingOff")
  agent.stats = { contextUsage = { contextWindow = 200000, percent = 91 } }
  rerender(agent)
  eq(footer(agent)[1].groups, { "DyadicFooter", "DyadicError" })
end)

T("the separator below the history has the thinking level's color, or shell mode's", function()
  vim.o.winhighlight = "Normal:Mine,WinSeparator:Theirs"
  local agent = H.open()
  local win = H.history_win(agent)
  eq(vim.wo[win].winhighlight, "Normal:Mine,WinSeparator:DyadicThinkingOff")
  agent.state.thinkingLevel = "xhigh"
  rerender(agent)
  eq(vim.wo[win].winhighlight, "Normal:Mine,WinSeparator:DyadicThinkingXhigh")
  agent:set_draft("  !ls")
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = agent.composer_buf })
  eq(vim.wo[win].winhighlight, "Normal:Mine,WinSeparator:DyadicShellMode")
  agent:set_draft("ls")
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = agent.composer_buf })
  eq(vim.wo[win].winhighlight, "Normal:Mine,WinSeparator:DyadicThinkingXhigh")
  -- The window gets its own value back when the pair hides.
  require("dyadic").command("toggle")
  H.settle()
  for _, other in ipairs(api.nvim_tabpage_list_wins(0)) do
    eq(vim.wo[other].winhighlight, "Normal:Mine,WinSeparator:Theirs")
  end
end)

T("the thinking colors are pi's, for dark and light backgrounds", function()
  local function fg(name)
    return api.nvim_get_hl(0, { name = name }).fg
  end
  require("dyadic.view")
  eq({ fg("DyadicThinkingHigh"), fg("DyadicShellMode") }, { 0x9776e5, 0x5eb286 })
  vim.o.background = "light"
  vim.cmd("colorscheme default")
  eq({ fg("DyadicThinkingHigh"), fg("DyadicShellMode") }, { 0xb5a5e8, 0x40976c })
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
