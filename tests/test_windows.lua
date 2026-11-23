local H = dofile("tests/helpers.lua")
local eq, ok = H.eq, H.ok
local T = H.suite()
local api = vim.api
local Composer = require("dyadic.composer")

-- The composer must be the next window in its history window's column.
local function attached(agent)
  local anchor, win = Composer.anchor(agent), Composer.window(agent)
  if not (anchor and win) then
    return false
  end
  local function find(node)
    if node[1] == "leaf" then
      return nil
    end
    for i, child in ipairs(node[2]) do
      if child[1] == "leaf" and child[2] == anchor then
        local next = node[2][i + 1]
        return node[1] == "col" and next and next[1] == "leaf" and next[2] == win
      end
      local found = find(child)
      if found ~= nil then
        return found
      end
    end
  end
  return find(vim.fn.winlayout()) == true
end

T("free placement shows the history with the composer below it", function()
  local agent = H.open(nil, { placement = "free" })
  local win = Composer.window(agent)
  eq(api.nvim_get_current_win(), win)
  eq(api.nvim_win_get_buf(Composer.anchor(agent)), agent.history_buf)
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  -- The minimum of 3 lines holds the draft and the footer, plus the window bar.
  eq(api.nvim_win_get_height(win), 4)
  eq(vim.wo[win].winfixbuf, true)
  eq(vim.wo[win].winfixheight, true)
end)

T("the composer grows with its text up to the limit", function()
  local agent = H.open(nil, { placement = "free" })
  local win = Composer.window(agent)
  agent:set_draft("1\n2\n3\n4\n5")
  H.settle()
  -- Five lines, the footer's model line, and the window bar.
  eq(api.nvim_win_get_height(win), 7)
  agent:set_draft(string.rep("line\n", 30))
  H.settle()
  -- 40% of the 20 lines the history and composer share, plus the window bar.
  eq(api.nvim_win_get_height(win), 9)
  agent:set_draft("")
  H.settle()
  eq(api.nvim_win_get_height(win), 4)
end)

T("resizing or moving the composer is undone", function()
  local agent = H.open(nil, { placement = "free" })
  local win = Composer.window(agent)
  vim.cmd("resize 12")
  H.settle()
  eq(api.nvim_win_get_height(win), 4)
  api.nvim_set_current_win(Composer.anchor(agent))
  vim.cmd("resize 2")
  H.settle()
  eq(api.nvim_win_get_height(win), 4)
  api.nvim_set_current_win(win)
  vim.cmd("wincmd K")
  H.settle()
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  eq(api.nvim_win_get_height(win), 4)
end)

T("other windows split into the pair are moved out", function()
  local agent = H.open(nil, { placement = "free" })
  local anchor = Composer.anchor(agent)
  vim.o.splitbelow = true
  api.nvim_set_current_win(anchor)
  vim.cmd("new")
  local split = api.nvim_get_current_win()
  H.settle()
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  eq(api.nvim_get_current_win(), split)
  api.nvim_set_current_win(anchor)
  vim.cmd("vnew")
  H.settle()
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
end)

T("splits of the history or composer are undone", function()
  local agent = H.open(nil, { placement = "free" })
  local anchor, win = Composer.anchor(agent), Composer.window(agent)
  local wins = api.nvim_list_wins()
  for _, how in ipairs({ "split", "vsplit" }) do
    for _, from in ipairs({ anchor, win }) do
      api.nvim_set_current_win(from)
      vim.cmd(how)
      H.settle()
      eq(api.nvim_list_wins(), wins, how)
      eq(api.nvim_get_current_win(), from, how)
      ok(attached(agent), vim.inspect(vim.fn.winlayout()))
    end
  end
end)

T("a moved-out window goes beside another window outside the pair", function()
  vim.cmd("vsplit")
  local other = api.nvim_list_wins()[2]
  local agent = H.open(nil, { placement = "free" })
  local anchor = Composer.anchor(agent)
  api.nvim_set_current_win(anchor)
  vim.cmd("vnew")
  local new = api.nvim_get_current_win()
  H.settle()
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  -- Split to the left of the other window, so it sits between the pair and that window.
  local col = function(win)
    return api.nvim_win_get_position(win)[2]
  end
  ok(col(anchor) < col(new) and col(new) < col(other), vim.inspect(vim.fn.winlayout()))
end)

T("the composer refuses other buffers", function()
  H.open()
  local ok_edit, err = pcall(vim.cmd.edit, vim.fn.tempname())
  eq(ok_edit, false)
  ok(tostring(err):find("E1513", 1, true), err)
end)

T("closing either window of the pair closes both", function()
  local other = api.nvim_get_current_win()
  vim.cmd("vsplit")
  local agent = H.open(nil, { placement = "free" })
  for _, which in ipairs({ "window", "anchor" }) do
    require("dyadic").command("composer")
    H.settle()
    api.nvim_set_current_win(Composer[which](agent))
    vim.cmd("close")
    H.settle()
    eq(Composer.window(agent), nil, which)
    eq(vim.fn.win_findbuf(agent.history_buf), {}, which)
    eq(vim.fn.win_findbuf(agent.composer_buf), {}, which)
    eq(api.nvim_list_wins(), { other }, which)
    vim.cmd("vsplit")
  end
end)

T(":close leaves a pair that is all the tab has", function()
  local agent = H.open(nil, { placement = "free" })
  for _, which in ipairs({ "window", "anchor" }) do
    api.nvim_set_current_win(Composer[which](agent))
    vim.cmd("close")
    H.settle()
    eq(#api.nvim_list_wins(), 2, which)
    ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  end
end)

T("toggle hides the free pair, but not when it is all the tab has", function()
  local agent = H.open(nil, { placement = "free" })
  require("dyadic").command("toggle")
  H.settle()
  eq(#api.nvim_list_wins(), 2)
  ok(_G.notes[#_G.notes].msg:find("only windows in this tab", 1, true), vim.inspect(_G.notes))
  vim.cmd("vnew")
  H.settle()
  require("dyadic").command("toggle")
  H.settle()
  eq(#api.nvim_list_wins(), 1)
  eq(vim.fn.win_findbuf(agent.history_buf), {})
  require("dyadic").command("toggle")
  H.settle()
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
end)

T(":q in a composer whose only neighbour is its history quits both", function()
  local agent = H.open(nil, { placement = "free" })
  vim.cmd("tabnew")
  vim.cmd("tabprevious")
  api.nvim_set_current_win(Composer.window(agent))
  vim.cmd("quit")
  H.settle()
  eq(#api.nvim_list_tabpages(), 1)
  eq(vim.fn.win_findbuf(agent.history_buf), {})
  eq(vim.fn.win_findbuf(agent.composer_buf), {})
end)

T(":q on a history window whose only neighbour is its composer quits both", function()
  local agent = H.open(nil, { placement = "free" })
  vim.cmd("tabnew")
  vim.cmd("tabprevious")
  api.nvim_set_current_win(Composer.anchor(agent))
  vim.cmd("quit")
  H.settle()
  eq(#api.nvim_list_tabpages(), 1)
  eq(vim.fn.win_findbuf(agent.history_buf), {})
  eq(vim.fn.win_findbuf(agent.composer_buf), {})
end)

T(":only in either window keeps the pair", function()
  local agent = H.open(nil, { placement = "free" })
  for _, which in ipairs({ "window", "anchor" }) do
    vim.cmd("vsplit")
    api.nvim_set_current_win(Composer[which](agent))
    local current = api.nvim_get_current_win()
    vim.cmd("only")
    H.settle()
    eq(#api.nvim_list_wins(), 2, which)
    ok(attached(agent), vim.inspect(vim.fn.winlayout()))
    eq(api.nvim_get_current_win(), current, which)
  end
end)

T("a history or composer buffer shown elsewhere moves the free pair there", function()
  vim.cmd("vsplit")
  local other = api.nvim_get_current_win()
  local agent = H.open(nil, { placement = "free" })
  agent:set_draft("kept")
  local first = Composer.anchor(agent)
  for _, buf in ipairs({ agent.history_buf, agent.composer_buf }) do
    local win = vim.tbl_filter(function(w)
      return w ~= first and w ~= Composer.window(agent)
    end, api.nvim_list_wins())[1]
    api.nvim_set_current_win(win)
    vim.cmd("buffer " .. buf)
    H.settle()
    eq(Composer.anchor(agent), win)
    ok(attached(agent), vim.inspect(vim.fn.winlayout()))
    eq(api.nvim_win_is_valid(first), false)
    eq(#vim.fn.win_findbuf(agent.history_buf), 1)
    eq(agent:get_draft(), "kept")
    first = win
    api.nvim_set_current_win(win)
    vim.cmd("vnew")
    H.settle()
  end
  ok(other)
end)

T("switching the history window's buffer closes the composer and keeps the draft", function()
  local agent = H.open(nil, { placement = "free" })
  agent:set_draft("unsent")
  api.nvim_set_current_win(Composer.anchor(agent))
  vim.cmd.enew()
  H.settle()
  eq(Composer.window(agent), nil)
  eq(#api.nvim_list_wins(), 1)
  eq(agent:get_draft(), "unsent")
end)

T("an agent has one composer window in each tab", function()
  local agent = H.open(nil, { placement = "free" })
  local tab, first = api.nvim_get_current_tabpage(), Composer.anchor(agent)
  vim.cmd("tabnew")
  vim.cmd("vsplit")
  require("dyadic").command("")
  H.settle()
  local second = Composer.anchor(agent)
  ok(second and second ~= first, "no pair in the second tab")
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  eq(#vim.fn.win_findbuf(agent.composer_buf), 2)
  eq(Composer.anchor(agent, tab), first)
  -- Closing one tab's pair leaves the other.
  api.nvim_win_close(second, true)
  H.settle()
  eq(Composer.window(agent), nil)
  eq(Composer.anchor(agent, tab), first)
end)

return T
