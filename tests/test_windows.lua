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
  -- A new agent starts in its history.
  eq(api.nvim_get_current_win(), Composer.anchor(agent))
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
  api.nvim_set_current_win(win)
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

T("insert keys in the history go into the composer's draft", function()
  local agent = H.open(nil, { placement = "free" })
  local cases = {
    { "i", { 1, 1 }, "oXne\ntwo" },
    { "a", { 1, 1 }, "onXe\ntwo" },
    { "I", { 2, 1 }, "Xone\ntwo" },
    { "A", { 1, 0 }, "one\ntwoX" },
    { "o", { 1, 0 }, "one\ntwo\nX" },
    { "O", { 2, 0 }, "X\none\ntwo" },
  }
  for _, case in ipairs(cases) do
    agent:set_draft("one\ntwo")
    api.nvim_win_set_cursor(Composer.window(agent), case[2])
    api.nvim_set_current_win(Composer.anchor(agent))
    H.keys(case[1] .. "X")
    eq(agent:get_draft(), case[3], case[1])
    eq(api.nvim_get_current_win(), Composer.window(agent), case[1])
  end
  -- An empty draft just starts.
  agent:set_draft("")
  api.nvim_set_current_win(Composer.anchor(agent))
  H.keys("oX")
  eq(agent:get_draft(), "X")
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

T("hiding the free pair gives its window back what it showed", function()
  local file = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "x" }, file)
  vim.cmd("edit " .. file)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  vim.wo[win].number = true
  local agent = H.open(nil, { placement = "free" })
  eq(Composer.anchor(agent), win)
  eq(vim.wo[win].number, false)
  for _ = 1, 2 do
    require("dyadic").command("toggle")
    H.settle()
    eq(api.nvim_list_wins(), { win })
    eq(api.nvim_win_get_buf(win), buf)
    eq(vim.wo[win].number, true)
    eq(api.nvim_get_current_win(), win)
    require("dyadic").command("toggle")
    H.settle()
    eq(Composer.anchor(agent), win)
    ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  end
end)

T("toggle outside the free pair goes into it; inside, it hides it", function()
  local main = api.nvim_get_current_win()
  vim.cmd("vsplit")
  local agent = H.open(nil, { placement = "free" })
  local anchor = Composer.anchor(agent)
  api.nvim_set_current_win(main)
  require("dyadic").command("toggle")
  eq(api.nvim_get_current_win(), anchor)
  api.nvim_set_current_win(Composer.window(agent))
  require("dyadic").command("toggle")
  H.settle()
  eq(Composer.anchor(agent), nil)
  eq(api.nvim_get_current_win(), main)
  require("dyadic").command("toggle")
  H.settle()
  eq(api.nvim_get_current_win(), Composer.window(agent))
end)

T("a window opened for the free pair closes when it hides", function()
  local agent = H.open(nil, { placement = "free" })
  local main = api.nvim_list_wins()[1]
  api.nvim_set_current_win(main)
  require("dyadic").command("toggle")
  H.settle()
  -- From a float, the pair opens in a new split.
  local float = api.nvim_open_win(api.nvim_create_buf(false, true), true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 10,
    height = 2,
  })
  require("dyadic").command("")
  H.settle()
  api.nvim_win_close(float, true)
  ok(Composer.anchor(agent) ~= main, "the pair took the main window")
  require("dyadic").command("toggle")
  H.settle()
  eq(api.nvim_list_wins(), { main })
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
    -- The pair's old window shows what it had before.
    ok(api.nvim_win_is_valid(first) and not require("dyadic.view").agent_of(api.nvim_win_get_buf(first)))
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
