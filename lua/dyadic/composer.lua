-- The composer window. An agent has at most one in each tab, all showing its one composer
-- buffer; each is a split directly below one history window, its anchor, and stays there
-- while attached: its height is computed and restored, a moved composer is put back,
-- windows split into the pair are moved out, and a composer never stays alone. Without a
-- composer a history window is an ordinary window.
local M = {}
local api = vim.api

-- agent -> tabpage -> { win = composer window, anchor = history window }
local attached = {}
-- Windows created since the last check; only these can be intruders.
local created = {}
-- tabpage -> the window last focused outside any history/composer pair.
local outside = {}
local check_pending = false

local function valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function is_float(win)
  return api.nvim_win_get_config(win).relative ~= ""
end

local function view()
  return require("dyadic.view")
end

local function sidebar()
  return require("dyadic.sidebar")
end

-- Ordinary (non-floating) windows of a tab.
local function tiled(tab)
  return vim.tbl_filter(function(win)
    return not is_float(win)
  end, api.nvim_tabpage_list_wins(tab))
end

-- The attachment of an agent's composer in a tab, the current one by default.
local function state_of(agent, tab)
  local tabs = attached[agent]
  return tabs and tabs[tab or api.nvim_get_current_tabpage()]
end

local function set_state(agent, tab, state)
  if state then
    attached[agent] = attached[agent] or {}
    attached[agent][tab] = state
  elseif attached[agent] then
    attached[agent][tab] = nil
    if next(attached[agent]) == nil then
      attached[agent] = nil
    end
  end
end

-- Every attachment, as { agent, tab, state } items.
local function all()
  local result = {}
  for agent, tabs in pairs(attached) do
    for tab, state in pairs(tabs) do
      result[#result + 1] = { agent, tab, state }
    end
  end
  return result
end

local function pair_member(win)
  for _, item in ipairs(all()) do
    if item[3].win == win or item[3].anchor == win then
      return true
    end
  end
  return false
end
M.pair_member = pair_member

-- The agent's composer window in a tab, the current one by default.
function M.window(agent, tab)
  local state = state_of(agent, tab)
  return state and valid_win(state.win) and state.win or nil
end

-- The agent's composer windows in all tabs.
function M.windows(agent)
  local result = {}
  for _, state in pairs(attached[agent] or {}) do
    if valid_win(state.win) then
      result[#result + 1] = state.win
    end
  end
  return result
end

-- The history window the agent's composer is attached to in a tab, the current one by
-- default.
function M.anchor(agent, tab)
  local state = state_of(agent, tab)
  return state and valid_win(state.win) and valid_win(state.anchor) and state.anchor or nil
end

-- Parent frame and index of a window in a winlayout() tree.
local function locate(node, win, parent, index)
  if node[1] == "leaf" then
    if node[2] == win then
      return parent, index
    end
    return nil
  end
  for i, child in ipairs(node[2]) do
    local found, at = locate(child, win, node, i)
    if found then
      return found, at
    end
  end
end

local function layout_of(win)
  return vim.fn.winlayout(api.nvim_tabpage_get_number(api.nvim_win_get_tabpage(win)))
end

-- The composer must be the next window in the anchor's column.
local function in_place(anchor, win)
  if api.nvim_win_get_tabpage(anchor) ~= api.nvim_win_get_tabpage(win) then
    return false
  end
  local parent, index = locate(layout_of(anchor), anchor)
  if not parent or parent[1] ~= "col" then
    return false
  end
  local next = parent[2][index + 1]
  return next ~= nil and next[1] == "leaf" and next[2] == win
end

-- How a new window entered the pair, if it did: "vertical" when it was split beside the
-- anchor, "horizontal" when it sits between the anchor and the composer.
local function intrusion(new, anchor, win)
  if api.nvim_win_get_tabpage(new) ~= api.nvim_win_get_tabpage(anchor) then
    return nil
  end
  local layout = layout_of(anchor)
  local parent_new, index_new = locate(layout, new)
  local parent_anchor, index_anchor = locate(layout, anchor)
  if not parent_new or parent_new ~= parent_anchor then
    return nil
  end
  if parent_new[1] == "row" then
    return "vertical"
  end
  local parent_win, index_win = locate(layout, win)
  if parent_win == parent_new and index_anchor < index_new and index_new < index_win then
    return "horizontal"
  end
end

-- Move a window out beside the window last used outside any pair and the sidebar, or to
-- the editor edge away from the sidebar.
function M.move_out(win, vertical)
  local tab = api.nvim_win_get_tabpage(win)
  local function usable(target)
    return valid_win(target)
      and target ~= win
      and api.nvim_win_get_tabpage(target) == tab
      and not is_float(target)
      and not pair_member(target)
      and not sidebar().contains(target)
  end
  local target = outside[tab]
  if not usable(target) then
    target = nil
    for _, candidate in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if usable(candidate) then
        target = candidate
        break
      end
    end
  end
  if target then
    pcall(api.nvim_win_set_config, win, { split = vertical and "left" or "above", win = target })
    return
  end
  local side = vertical and "left" or "above"
  local bar = sidebar().window(tab)
  if bar then
    side = api.nvim_win_get_position(bar)[2] == 0 and "right" or "left"
  end
  pcall(api.nvim_win_set_config, win, { split = side, win = -1 })
end

local function limits(agent, total)
  local config = agent.config.composer or {}
  local min = config.min_height or 3
  local max = config.max_height or 0.4
  if max < 1 then
    max = math.floor(total * max)
  end
  return min, math.max(min, max)
end

-- Height of the composer window: its text, wrapped and with virtual lines, within the
-- configured limits, plus the window bar.
local function target_height(agent, win, anchor)
  local text = api.nvim_win_text_height(win, {}).all
  local info = vim.fn.getwininfo(win)[1] or {}
  local bar = info.winbar or 0
  local total = api.nvim_win_get_height(win) - bar + api.nvim_win_get_height(anchor)
  local min, max = limits(agent, total)
  -- Leave the history at least one line.
  return math.max(1, math.min(math.max(text, min), max, total - 1)) + bar
end

local function resize(agent, state)
  if not (valid_win(state.win) and valid_win(state.anchor)) then
    return
  end
  local height = target_height(agent, state.win, state.anchor)
  if api.nvim_win_get_height(state.win) ~= height then
    api.nvim_win_set_config(state.win, { height = height })
  end
  -- A window that grew after scrolling stays scrolled; show everything once it fits.
  local info = vim.fn.getwininfo(state.win)[1] or {}
  if api.nvim_win_text_height(state.win, {}).all <= (info.height or 0) and (info.topline or 1) > 1 then
    api.nvim_win_call(state.win, function()
      -- topfill is limited to the virtual lines above line 1.
      vim.fn.winrestview({ topline = 1, topfill = 1000 })
    end)
  end
end

-- Fit the agent's composer windows in all tabs to their text.
function M.resize(agent)
  for _, state in pairs(attached[agent] or {}) do
    resize(agent, state)
  end
end

local function composer_options(win)
  local wo = vim.wo[win]
  wo.winfixheight = true
  require("dyadic.pin").pin(win, api.nvim_win_get_buf(win))
  wo.wrap = true
  wo.linebreak = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.scrolloff = 0
end

-- Attach the composer below a history window, moving it if it is attached elsewhere in
-- that tab.
function M.attach(agent, anchor, focus)
  local tab = api.nvim_win_get_tabpage(anchor)
  local state = state_of(agent, tab)
  local win = state and valid_win(state.win) and state.win or nil
  if win and state.anchor ~= anchor then
    if not pcall(api.nvim_win_set_config, win, { split = "below", win = anchor }) then
      pcall(api.nvim_win_close, win, true)
      win = nil
    end
  end
  if not win then
    local ok, opened = pcall(api.nvim_open_win, agent.composer_buf, false, {
      split = "below",
      win = anchor,
      height = limits(agent, api.nvim_win_get_height(anchor)) + 1,
    })
    if not ok then
      return nil
    end
    win = opened
    composer_options(win)
  end
  state = { win = win, anchor = anchor }
  set_state(agent, tab, state)
  resize(agent, state)
  if focus then
    api.nvim_set_current_win(win)
  end
  return win
end

-- Close the agent's composer in a tab, the current one by default.
function M.close(agent, tab)
  tab = tab or api.nvim_get_current_tabpage()
  local state = state_of(agent, tab)
  set_state(agent, tab, nil)
  if state and valid_win(state.win) then
    if #tiled(api.nvim_win_get_tabpage(state.win)) > 1 then
      pcall(api.nvim_win_close, state.win, true)
    else
      M.to_history(agent, state.win)
    end
  end
end

-- A composer never stays alone: its window shows the history instead.
function M.to_history(agent, win)
  for tab, state in pairs(attached[agent] or {}) do
    if state.win == win then
      set_state(agent, tab, nil)
    end
  end
  require("dyadic.pin").unpin(win)
  vim.wo[win].winfixheight = false
  api.nvim_win_set_buf(win, agent.history_buf)
  view().adopt(win)
end

local function check_agent(agent, tab, state)
  local win, anchor = state.win, state.anchor
  if agent.closed or not valid_win(win) then
    set_state(agent, tab, nil)
    return
  end
  -- The history window closed or shows another buffer: the composer goes too.
  if not valid_win(anchor) or api.nvim_win_get_buf(anchor) ~= agent.history_buf then
    M.close(agent, tab)
    return
  end
  for new in pairs(created) do
    if valid_win(new) and new ~= win and new ~= anchor and not is_float(new) then
      local how = intrusion(new, anchor, win)
      if how then
        M.move_out(new, how == "vertical")
      end
    end
  end
  if not in_place(anchor, win) then
    if not pcall(api.nvim_win_set_config, win, { split = "below", win = anchor }) then
      M.close(agent, tab)
      return
    end
  end
  resize(agent, state)
end

-- Windows that show a composer buffer without being an attached composer.
local function check_strays()
  local agents, composers = {}, {}
  for _, agent in ipairs(require("dyadic").list()) do
    agents[agent.composer_buf] = agent
  end
  for _, item in ipairs(all()) do
    composers[item[3].win] = true
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    local agent = agents[api.nvim_win_get_buf(win)]
    if agent and not composers[win] and not is_float(win) then
      if #tiled(api.nvim_win_get_tabpage(win)) > 1 then
        pcall(api.nvim_win_close, win, true)
      else
        M.to_history(agent, win)
      end
    end
  end
end

function M.check()
  check_pending = false
  -- A forced buffer switch in the sidebar is undone before it looks like a closed pair.
  require("dyadic.pin").check()
  for _, item in ipairs(all()) do
    check_agent(item[1], item[2], item[3])
  end
  check_strays()
  sidebar().check(created)
  created = {}
end

function M.schedule_check()
  if not check_pending then
    check_pending = true
    vim.schedule(M.check)
  end
end

function M.dispose(agent)
  local tabs = attached[agent] or {}
  attached[agent] = nil
  for _, state in pairs(tabs) do
    if valid_win(state.win) and #tiled(api.nvim_win_get_tabpage(state.win)) > 1 then
      pcall(api.nvim_win_close, state.win, true)
    end
  end
end

-- `:q` on a history window whose only neighbour is its composer: close the composer first,
-- so the quit behaves as if the history were alone. When quitting Neovim is refused, the
-- composer comes back.
local function quit_pre()
  local current = api.nvim_get_current_win()
  local refused = #api.nvim_list_tabpages() == 1 and require("dyadic.quit_guard").blocks_exit()
  for _, item in ipairs(all()) do
    local agent, tab, state = item[1], item[2], item[3]
    if state.anchor == current and valid_win(state.win) then
      local others = vim.tbl_filter(function(win)
        return win ~= current and win ~= state.win
      end, tiled(api.nvim_win_get_tabpage(current)))
      if #others == 0 then
        set_state(agent, tab, nil)
        pcall(api.nvim_win_close, state.win, true)
        if refused then
          vim.schedule(function()
            if not agent.closed and valid_win(current) and api.nvim_win_get_buf(current) == agent.history_buf then
              M.attach(agent, current, false)
            end
          end)
        end
      end
    end
  end
end

-- Windows that would stay open after `:q` in the current window.
local function remaining()
  local current = api.nvim_get_current_win()
  local count = 0
  for _, win in ipairs(tiled(0)) do
    if win ~= current and not pair_member(win) and not sidebar().contains(win) then
      count = count + 1
    end
  end
  return count
end

local group = api.nvim_create_augroup("DyadicComposer", { clear = true })
api.nvim_create_autocmd("WinNew", {
  group = group,
  callback = function()
    created[api.nvim_get_current_win()] = true
    M.schedule_check()
  end,
})
api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    local win = api.nvim_get_current_win()
    if not is_float(win) and not pair_member(win) and not sidebar().contains(win) then
      outside[api.nvim_get_current_tabpage()] = win
    end
    sidebar().entered(win)
    M.schedule_check()
  end,
})
api.nvim_create_autocmd({ "WinClosed", "WinResized", "VimResized", "TabEnter", "BufWinEnter" }, {
  group = group,
  callback = M.schedule_check,
})
api.nvim_create_autocmd("QuitPre", {
  group = group,
  callback = function()
    require("dyadic.quit_guard").explain(remaining())
    sidebar().quit_pre()
    quit_pre()
  end,
})

return M
