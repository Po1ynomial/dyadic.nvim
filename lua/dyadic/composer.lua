-- The composer window. An agent has at most one; it is a split directly below one history
-- window, its anchor, and stays there while attached: its height is computed and restored,
-- a moved composer is put back, windows split into the pair are moved out, and a composer
-- never stays alone. Without a composer a history window is an ordinary window.
local M = {}
local api = vim.api

-- agent -> { win = composer window, anchor = history window }
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

local function pair_member(win)
  for _, state in pairs(attached) do
    if state.win == win or state.anchor == win then
      return true
    end
  end
  return false
end
M.pair_member = pair_member

function M.window(agent)
  local state = attached[agent]
  return state and valid_win(state.win) and state.win or nil
end

function M.anchor(agent)
  local state = attached[agent]
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

function M.resize(agent)
  local state = attached[agent]
  if not (state and valid_win(state.win) and valid_win(state.anchor)) then
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

-- Attach the composer below a history window, moving it if it is attached elsewhere.
function M.attach(agent, anchor, focus)
  local state = attached[agent]
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
  attached[agent] = { win = win, anchor = anchor }
  M.resize(agent)
  if focus then
    api.nvim_set_current_win(win)
  end
  return win
end

function M.close(agent)
  local state = attached[agent]
  attached[agent] = nil
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
  if attached[agent] and attached[agent].win == win then
    attached[agent] = nil
  end
  require("dyadic.pin").unpin(win)
  vim.wo[win].winfixheight = false
  api.nvim_win_set_buf(win, agent.history_buf)
  view().adopt(win)
end

local function check_agent(agent, state)
  local win, anchor = state.win, state.anchor
  if agent.closed or not valid_win(win) then
    attached[agent] = nil
    return
  end
  -- The history window closed or shows another buffer: the composer goes too.
  if not valid_win(anchor) or api.nvim_win_get_buf(anchor) ~= agent.history_buf then
    M.close(agent)
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
      M.close(agent)
      return
    end
  end
  M.resize(agent)
end

-- Windows that show a composer buffer without being its attached composer.
local function check_strays()
  local agents = {}
  for _, agent in ipairs(require("dyadic").list()) do
    agents[agent.composer_buf] = agent
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    local agent = agents[api.nvim_win_get_buf(win)]
    if agent and win ~= M.window(agent) and not is_float(win) then
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
  for agent, state in pairs(attached) do
    check_agent(agent, state)
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
  local state = attached[agent]
  attached[agent] = nil
  if state and valid_win(state.win) and #tiled(api.nvim_win_get_tabpage(state.win)) > 1 then
    pcall(api.nvim_win_close, state.win, true)
  end
end

-- `:q` on a history window whose only neighbour is its composer: close the composer first,
-- so the quit behaves as if the history were alone. When quitting Neovim is refused, the
-- composer comes back.
local function quit_pre()
  local current = api.nvim_get_current_win()
  local refused = #api.nvim_list_tabpages() == 1 and require("dyadic.quit_guard").blocks_exit()
  for agent, state in pairs(attached) do
    if state.anchor == current and valid_win(state.win) then
      local others = vim.tbl_filter(function(win)
        return win ~= current and win ~= state.win
      end, tiled(api.nvim_win_get_tabpage(current)))
      if #others == 0 then
        attached[agent] = nil
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
