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

T("windows split into the pair are moved out", function()
  local agent = H.open(nil, { placement = "free" })
  local anchor = Composer.anchor(agent)
  vim.o.splitbelow = true
  api.nvim_set_current_win(anchor)
  vim.cmd("split")
  local split = api.nvim_get_current_win()
  H.settle()
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  eq(api.nvim_get_current_win(), split)
  api.nvim_set_current_win(anchor)
  vim.cmd("vsplit")
  H.settle()
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  -- A split of the composer would be a second composer; it is closed.
  local count = #api.nvim_list_wins()
  api.nvim_set_current_win(Composer.window(agent))
  vim.cmd("vsplit")
  H.settle()
  eq(#api.nvim_list_wins(), count)
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
end)

T("a moved-out window goes beside another window outside the pair", function()
  vim.cmd("vsplit")
  local other = api.nvim_list_wins()[2]
  local agent = H.open(nil, { placement = "free" })
  local anchor = Composer.anchor(agent)
  api.nvim_set_current_win(anchor)
  vim.cmd("vsplit")
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

T("closing the history closes its composer, not the other way round", function()
  local agent = H.open(nil, { placement = "free" })
  vim.cmd("vsplit")
  local other = api.nvim_get_current_win()
  vim.cmd.enew()
  api.nvim_win_close(Composer.window(agent), true)
  H.settle()
  eq(#vim.fn.win_findbuf(agent.history_buf), 1)
  require("dyadic").command("composer")
  H.settle()
  local anchor = Composer.anchor(agent)
  api.nvim_win_close(anchor, true)
  H.settle()
  eq(Composer.window(agent), nil)
  eq(vim.fn.win_findbuf(agent.composer_buf), {})
  eq(api.nvim_list_wins(), { other })
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

T("a composer left alone shows the history instead", function()
  local agent = H.open(nil, { placement = "free" })
  vim.cmd("only")
  H.settle()
  eq(#api.nvim_list_wins(), 1)
  eq(api.nvim_get_current_buf(), agent.history_buf)
  eq(vim.wo.winfixbuf, false)
  eq(Composer.window(agent), nil)
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

T("an agent has one composer; focusing it from another history window moves it", function()
  local agent = H.open(nil, { placement = "free" })
  local first = Composer.anchor(agent)
  vim.cmd("tabnew")
  api.nvim_win_set_buf(0, agent.history_buf)
  local second = api.nvim_get_current_win()
  require("dyadic").action("focus_composer")
  H.settle()
  eq(Composer.anchor(agent), second)
  ok(attached(agent), vim.inspect(vim.fn.winlayout()))
  eq(#vim.fn.win_findbuf(agent.composer_buf), 1)
  ok(api.nvim_win_is_valid(first), "the first history window was closed")
end)

return T
