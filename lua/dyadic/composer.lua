-- The composer window. An agent has at most one in each tab, all showing its one composer
-- buffer; each is a split directly below one history window, its anchor, and the two form
-- a pair: neither shows without the other. Its height is computed and restored, a moved
-- composer is put back, closing either window closes both, splits of either are undone,
-- and other windows split into the pair are moved out.
local M = {}
local api = vim.api

-- agent -> tabpage -> { win = composer window, anchor = history window }
local attached = {}
-- History window -> { agent, buf }: the buffer the window showed before the free placement
-- took it for the agent's pair.
local taken = {}
-- agent -> "history" or "composer": the window of its pairs entered last.
local focused = {}
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

-- Which window of the agent's pairs was entered last: "history" (the default) or
-- "composer".
function M.focused(agent)
  return focused[agent] or "history"
end

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
  -- A window that grew after scrolling stays scrolled; show everything once it fits. With
  -- 'smoothscroll' it may have scrolled by screen rows within the first line instead.
  local info = vim.fn.getwininfo(state.win)[1] or {}
  if api.nvim_win_text_height(state.win, {}).all <= (info.height or 0) then
    api.nvim_win_call(state.win, function()
      local view = vim.fn.winsaveview()
      if view.topline > 1 or view.skipcol > 0 then
        -- topfill is limited to the virtual lines above line 1.
        vim.fn.winrestview({ topline = 1, skipcol = 0, topfill = 1000 })
      end
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

-- Close the agent's composer in a tab, the current one by default, leaving its history
-- window to the caller. The composer stays when it is all the tab has.
function M.close(agent, tab)
  tab = tab or api.nvim_get_current_tabpage()
  local state = state_of(agent, tab)
  set_state(agent, tab, nil)
  if state and valid_win(state.win) and #tiled(api.nvim_win_get_tabpage(state.win)) > 1 then
    pcall(api.nvim_win_close, state.win, true)
  end
end

-- Remember the buffer a window showed before it became the agent's history window.
function M.take(agent, win, buf)
  taken[win] = buf and { agent = agent, buf = buf } or nil
end

-- The buffer a history window showed before it was taken, if it is still there.
function M.taken(win)
  local entry = taken[win]
  return entry and api.nvim_buf_is_valid(entry.buf) and entry.buf or nil
end

-- Hide the agent's pair in a tab, the current one by default. The history window shows
-- the buffer it had before; a window opened for the pair closes, or, when it is all the
-- tab has besides the composer, shows the file used last.
function M.hide(agent, tab)
  tab = tab or api.nvim_get_current_tabpage()
  local state = state_of(agent, tab)
  if not state then
    return
  end
  set_state(agent, tab, nil)
  local previous = M.taken(state.anchor)
  taken[state.anchor] = nil
  local others = vim.tbl_filter(function(win)
    return win ~= state.win and win ~= state.anchor
  end, tiled(tab))
  pcall(api.nvim_win_close, state.win, true)
  if not valid_win(state.anchor) then
    return
  end
  if not previous and #others > 0 then
    pcall(api.nvim_win_close, state.anchor, true)
    return
  end
  previous = previous or require("dyadic.files").recent() or api.nvim_create_buf(true, false)
  api.nvim_win_set_buf(state.anchor, previous)
end

-- Open a history window above a composer that lost its own and make them a pair again.
local function rejoin(agent, tab, state)
  local ok, anchor = pcall(api.nvim_open_win, agent.history_buf, false, { split = "above", win = state.win })
  if not ok then
    set_state(agent, tab, nil)
    return
  end
  view().adopt(anchor)
  sidebar().replace(tab, state.anchor, anchor)
  state.anchor = anchor
  resize(agent, state)
end

local function check_agent(agent, tab, state)
  local win, anchor = state.win, state.anchor
  if agent.closed then
    set_state(agent, tab, nil)
    return
  end
  local has_win = valid_win(win)
  local has_anchor = valid_win(anchor) and api.nvim_win_get_buf(anchor) == agent.history_buf
  if not has_win and not has_anchor then
    set_state(agent, tab, nil)
    return
  end
  -- Closing either window closes both, unless they are all the tab has.
  if not has_win then
    if #tiled(tab) > 1 then
      set_state(agent, tab, nil)
      pcall(api.nvim_win_close, anchor, true)
    else
      M.attach(agent, anchor, false)
    end
    return
  end
  if not has_anchor then
    if taken[anchor] and taken[anchor].agent == agent then
      taken[anchor] = nil
    end
    if valid_win(anchor) or #tiled(tab) > 1 then
      -- The history window shows another buffer now, or closed beside other windows.
      M.close(agent, tab)
    else
      rejoin(agent, tab, state)
    end
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

-- Ordinary windows that show an agent's history or composer buffer outside its pairs, with
-- that agent: { win, agent } items.
local function outsiders()
  local owners, members, result = {}, {}, {}
  for _, agent in ipairs(require("dyadic").list()) do
    owners[agent.history_buf], owners[agent.composer_buf] = agent, agent
  end
  for _, item in ipairs(all()) do
    members[item[3].win], members[item[3].anchor] = true, true
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    local agent = owners[api.nvim_win_get_buf(win)]
    if agent and not members[win] and not is_float(win) then
      result[#result + 1] = { win, agent }
    end
  end
  return result
end

-- The current tab's ordinary windows and their sizes at the end of the last check.
local sizes

local function snapshot()
  sizes = { tab = api.nvim_get_current_tabpage(), wins = tiled(0), cmd = vim.fn.winrestcmd() }
end

-- A split of a pair's window is undone, and the cursor goes back to the window split.
-- Closing the split may hand its space to another window; the sizes from before it come
-- back when the windows are the same again.
local function undo_splits()
  local undone = false
  for _, item in ipairs(outsiders()) do
    local win = item[1]
    if created[win] then
      local buf, tab = api.nvim_win_get_buf(win), api.nvim_win_get_tabpage(win)
      local current = api.nvim_get_current_win() == win
      -- Kept in `created`, so the sidebar knows its width changed from a split.
      pcall(api.nvim_win_close, win, true)
      undone = true
      local state = state_of(item[2], tab)
      if current and state then
        local back = buf == item[2].composer_buf and state.win or state.anchor
        if valid_win(back) then
          api.nvim_set_current_win(back)
        end
      end
    end
  end
  if undone and sizes and sizes.tab == api.nvim_get_current_tabpage() and vim.deep_equal(sizes.wins, tiled(0)) then
    vim.cmd(sizes.cmd)
  end
end

-- A history or composer buffer shown in another window, as with :buffer. With the free
-- placement that window becomes the tab's pair; with the sidebar it gets its own buffer
-- back, and the sidebar shows the agent.
local function adopt_outsiders()
  for _, item in ipairs(outsiders()) do
    local win, agent = item[1], item[2]
    local tab = api.nvim_win_get_tabpage(win)
    local current = api.nvim_get_current_win() == win
    local previous = api.nvim_win_call(win, function()
      return vim.fn.bufnr("#")
    end)
    if previous < 1 or view().agent_of(previous) then
      previous = nil
    end
    if agent.config.placement == "free" then
      M.hide(agent, tab)
      M.take(agent, win, M.taken(win) or previous)
      if api.nvim_win_get_buf(win) ~= agent.history_buf then
        api.nvim_win_set_buf(win, agent.history_buf)
      end
      view().adopt(win)
      M.attach(agent, win, current)
    else
      previous = previous or require("dyadic.files").recent() or api.nvim_create_buf(true, false)
      api.nvim_win_set_buf(win, previous)
      if current and tab == api.nvim_get_current_tabpage() then
        require("dyadic").show(agent)
      end
    end
  end
end

function M.check()
  check_pending = false
  -- A forced buffer switch in the sidebar is undone before it looks like a closed pair.
  require("dyadic.pin").check()
  undo_splits()
  for _, item in ipairs(all()) do
    check_agent(item[1], item[2], item[3])
  end
  adopt_outsiders()
  sidebar().check(created)
  created = {}
  snapshot()
end

function M.schedule_check()
  if not check_pending then
    check_pending = true
    vim.schedule(M.check)
  end
end

function M.dispose(agent)
  local tabs = attached[agent] or {}
  attached[agent], focused[agent] = nil, nil
  for _, state in pairs(tabs) do
    if valid_win(state.win) and #tiled(api.nvim_win_get_tabpage(state.win)) > 1 then
      pcall(api.nvim_win_close, state.win, true)
    end
  end
end

-- `:q` in a pair that is all its tab has: close the other window first, so the quit
-- behaves as if the current one were alone. When quitting Neovim is refused, the other
-- window comes back.
local function quit_pre()
  local current = api.nvim_get_current_win()
  local refused = #api.nvim_list_tabpages() == 1 and require("dyadic.quit_guard").blocks_exit()
  for _, item in ipairs(all()) do
    local agent, tab, state = item[1], item[2], item[3]
    local partner = state.anchor == current and state.win or state.win == current and state.anchor or nil
    if partner and valid_win(partner) then
      local others = vim.tbl_filter(function(win)
        return win ~= current and win ~= partner
      end, tiled(tab))
      if #others == 0 then
        set_state(agent, tab, nil)
        if refused then
          -- Scheduled before the close, so it runs before the checks the close schedules.
          vim.schedule(function()
            if agent.closed or not valid_win(current) then
              return
            end
            local buf = api.nvim_win_get_buf(current)
            if buf == agent.history_buf then
              M.attach(agent, current, false)
            elseif buf == agent.composer_buf then
              local restored = { win = current, anchor = partner }
              set_state(agent, tab, restored)
              rejoin(agent, tab, restored)
            end
          end)
        end
        pcall(api.nvim_win_close, partner, true)
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
    for _, item in ipairs(all()) do
      if item[3].win == win then
        focused[item[1]] = "composer"
      elseif item[3].anchor == win then
        focused[item[1]] = "history"
      end
    end
    sidebar().entered(win)
    M.schedule_check()
  end,
})
api.nvim_create_autocmd({ "WinClosed", "WinResized", "VimResized", "TabEnter", "BufWinEnter" }, {
  group = group,
  callback = function(ev)
    if ev.event == "WinClosed" then
      taken[tonumber(ev.match)] = nil
    end
    M.schedule_check()
  end,
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
