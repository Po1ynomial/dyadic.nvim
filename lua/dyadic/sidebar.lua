-- The sidebar placement: one history window per tab in a column at the edge of the tab,
-- showing one agent at a time. Its width keeps a ratio of the editor width within limits,
-- windows split into it move to the main area, it refuses other buffers, and it does not
-- keep a tab or Neovim open on its own.
local M = {}
local api = vim.api

-- tabpage -> { win = history window, width = last width set or seen, columns = editor width then }
local sidebars = {}
-- tabpage -> the window last focused outside the sidebar.
local main = {}
-- Width as a share of the editor; nil until the first sidebar opens.
local ratio
-- The main area keeps at least this many columns while the sidebar has its minimum.
local MAIN_MIN = 40

local function valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function is_float(win)
  return api.nvim_win_get_config(win).relative ~= ""
end

local function options(agent)
  return agent.config.sidebar or {}
end

local function state_of(tab)
  local state = sidebars[tab or api.nvim_get_current_tabpage()]
  if state and valid_win(state.win) then
    return state
  end
end

-- The sidebar history window of a tab, if open.
function M.window(tab)
  local state = state_of(tab)
  return state and state.win or nil
end

-- Whether a window is the sidebar's history window or the composer attached to it.
function M.contains(win)
  for tab, state in pairs(sidebars) do
    if valid_win(state.win) then
      if state.win == win then
        return true
      end
      local agent = require("dyadic.view").agent_of(api.nvim_win_get_buf(state.win))
      if agent and require("dyadic.composer").window(agent, tab) == win then
        return true
      end
    end
  end
  return false
end

local function width_for(agent, columns)
  local config = options(agent)
  local wanted = math.floor((ratio or config.width or 0.35) * columns + 0.5)
  local min, max = config.min_width or 40, config.max_width or 120
  if columns < min + MAIN_MIN + 1 then
    return math.max(1, wanted)
  end
  return math.max(min, math.min(wanted, max, columns - MAIN_MIN - 1))
end

local function apply_width(state, agent)
  local width = width_for(agent, vim.o.columns)
  if api.nvim_win_get_width(state.win) ~= width then
    api.nvim_win_set_config(state.win, { width = width })
  end
  state.width, state.columns = api.nvim_win_get_width(state.win), vim.o.columns
end

-- Show an agent in this tab's sidebar, opening it if needed. Returns the history window.
function M.show(agent)
  local View = require("dyadic.view")
  local tab = api.nvim_get_current_tabpage()
  local state = state_of(tab)
  if state then
    local shown = View.agent_of(api.nvim_win_get_buf(state.win))
    if shown ~= agent then
      if shown and require("dyadic.composer").anchor(shown, tab) == state.win then
        require("dyadic.composer").close(shown, tab)
      end
      require("dyadic.pin").set_buf(state.win, agent.history_buf)
    end
    return state.win
  end
  ratio = ratio or options(agent).width or 0.35
  local current = api.nvim_get_current_win()
  if not is_float(current) then
    main[tab] = current
  end
  local win = api.nvim_open_win(agent.history_buf, false, {
    split = options(agent).side == "left" and "left" or "right",
    win = -1,
    width = width_for(agent, vim.o.columns),
  })
  vim.wo[win].winfixwidth = true
  require("dyadic.pin").pin(win, agent.history_buf)
  View.adopt(win)
  state = { win = win }
  sidebars[tab] = state
  apply_width(state, agent)
  return win
end

-- Close this tab's sidebar. Returns false when it is the only thing in the tab.
function M.close(tab)
  tab = tab or api.nvim_get_current_tabpage()
  local state = state_of(tab)
  if not state then
    return true
  end
  local agent = require("dyadic.view").agent_of(api.nvim_win_get_buf(state.win))
  local Composer = require("dyadic.composer")
  local composer = agent and Composer.anchor(agent, tab) == state.win and Composer.window(agent, tab) or nil
  local tiled = vim.tbl_filter(function(win)
    return not is_float(win) and win ~= state.win and win ~= composer
  end, api.nvim_tabpage_list_wins(tab))
  if #tiled == 0 then
    return false
  end
  if composer then
    Composer.close(agent, tab)
  end
  pcall(api.nvim_win_close, state.win, true)
  sidebars[tab] = nil
  return true
end

-- Windows that belong to dyadic: the sidebar, or a history window with its composer.
local function dyadic_window(win)
  return M.contains(win) or require("dyadic.composer").pair_member(win)
end

-- A new window for the main area of `tab`, across from its sidebar, showing the most
-- recently used file buffer, else a new empty one.
local function open_main(tab)
  local state = state_of(tab)
  local config = { split = "above", win = -1 }
  if state then
    -- A sidebar alone spans the tab, so its side comes from the agent's options.
    local agent = require("dyadic.view").agent_of(api.nvim_win_get_buf(state.win))
    local left
    if agent then
      left = options(agent).side == "left"
    else
      left = api.nvim_win_get_position(state.win)[2] == 0
    end
    config.split = left and "right" or "left"
  end
  local buf = require("dyadic.files").recent() or api.nvim_create_buf(true, false)
  local win
  -- `win = -1` splits the current tab; run in `tab` so another tab works too.
  api.nvim_win_call(api.nvim_tabpage_get_win(tab), function()
    win = api.nvim_open_win(buf, false, config)
  end)
  main[tab] = win
  return win
end

-- The main area's window: the one last used outside the sidebar and any history/composer
-- pair, else another such window, else a new split.
function M.main_window(tab)
  tab = tab or api.nvim_get_current_tabpage()
  local win = main[tab]
  if valid_win(win) and api.nvim_win_get_tabpage(win) == tab and not dyadic_window(win) then
    return win
  end
  for _, candidate in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if not is_float(candidate) and not dyadic_window(candidate) then
      return candidate
    end
  end
  return open_main(tab)
end

-- gf, gF, and <C-w>f in the sidebar or the detail open in the main area. Paths in tool
-- output are relative to pi's working directory. `before` runs once the file is known.
function M.open_file(agent, how, before)
  local name = vim.fn.expand("<cfile>")
  if name == "" then
    vim.notify("E446: No file name under cursor", vim.log.levels.ERROR)
    return
  end
  local path = vim.fs.normalize(name)
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.joinpath(agent.cwd, path)
  end
  if vim.fn.filereadable(path) == 0 and vim.fn.isdirectory(path) == 0 then
    vim.notify(string.format('E447: Can\'t find file "%s" in path', name), vim.log.levels.ERROR)
    return
  end
  local line = how == "gF" and tonumber(vim.fn.expand("<cWORD>"):match(vim.pesc(name) .. "[:(](%d+)")) or nil
  if before then
    before()
  end
  local win = M.main_window()
  api.nvim_set_current_win(win)
  vim.cmd((how == "split" and "split " or "edit ") .. vim.fn.fnameescape(path))
  if line then
    pcall(api.nvim_win_set_cursor, 0, { line, 0 })
  end
end

-- Parent frame and index of a window in a winlayout() tree.
local function path_to(node, win, trail)
  trail = trail or {}
  if node[1] == "leaf" then
    return node[2] == win and trail or nil
  end
  for i, child in ipairs(node[2]) do
    trail[#trail + 1] = { node, i }
    local found = path_to(child, win, trail)
    if found then
      return found
    end
    trail[#trail] = nil
  end
end

-- The part of the layout that belongs to the sidebar: the child, of the sidebar window's
-- nearest row ancestor, that holds it.
local function region(tab, win)
  local layout = vim.fn.winlayout(api.nvim_tabpage_get_number(tab))
  local trail = path_to(layout, win) or {}
  for i = #trail, 1, -1 do
    local node, index = trail[i][1], trail[i][2]
    if node[1] == "row" then
      return node[2][index]
    end
  end
  return layout
end

local function leaves(node, out)
  out = out or {}
  if node[1] == "leaf" then
    out[node[2]] = true
  else
    for _, child in ipairs(node[2]) do
      leaves(child, out)
    end
  end
  return out
end

-- Called from the composer's layout check with the windows created since the last one.
function M.check(created)
  for tab, state in pairs(sidebars) do
    if not api.nvim_tabpage_is_valid(tab) or not valid_win(state.win) then
      sidebars[tab] = nil
    else
      local agent = require("dyadic.view").agent_of(api.nvim_win_get_buf(state.win))
      if agent then
        local inside = leaves(region(tab, state.win))
        for win in pairs(created) do
          if valid_win(win) and inside[win] and not M.contains(win) and not is_float(win) then
            local Composer = require("dyadic.composer")
            Composer.move_out(win, true)
          end
        end
        -- The sidebar never stands alone, whatever closed the main area's last window.
        local alone = true
        for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
          if not is_float(win) and not M.contains(win) then
            alone = false
            break
          end
        end
        if alone then
          open_main(tab)
          -- Back to the sidebar's width, not taken for a manual resize.
          apply_width(state, agent)
        end
        if tab == api.nvim_get_current_tabpage() then
          if state.columns ~= vim.o.columns then
            apply_width(state, agent)
          elseif api.nvim_win_get_width(state.win) ~= state.width then
            -- A manual resize: remember it as a share of the editor width.
            state.width = api.nvim_win_get_width(state.win)
            ratio = state.width / vim.o.columns
          end
        end
      end
    end
  end
end

-- Track the main area's window.
function M.entered(win)
  if not is_float(win) and not dyadic_window(win) then
    main[api.nvim_get_current_tabpage()] = win
  end
end

-- :q on the last window outside the sidebar closes the sidebar first, so the tab closes or
-- Neovim exits as it would without it. When quitting Neovim is refused, the sidebar comes
-- back.
function M.quit_pre()
  local current = api.nvim_get_current_win()
  local tab = api.nvim_get_current_tabpage()
  local state = state_of(tab)
  if not state or M.contains(current) then
    return
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if win ~= current and not is_float(win) and not M.contains(win) then
      return
    end
  end
  local refused = #api.nvim_list_tabpages() == 1 and require("dyadic.quit_guard").blocks_exit()
  local Composer = require("dyadic.composer")
  local agent = require("dyadic.view").agent_of(api.nvim_win_get_buf(state.win))
  local had_composer = agent and Composer.anchor(agent, tab) == state.win
  if had_composer then
    Composer.close(agent, tab)
  end
  pcall(api.nvim_win_close, state.win, true)
  sidebars[tab] = nil
  if refused and agent then
    -- Scheduled work runs only if Neovim is still here.
    vim.schedule(function()
      if agent.closed or not api.nvim_tabpage_is_valid(tab) or tab ~= api.nvim_get_current_tabpage() then
        return
      end
      local back = api.nvim_get_current_win()
      local win = M.show(agent)
      if had_composer then
        Composer.attach(agent, win, false)
      end
      api.nvim_set_current_win(back)
    end)
  end
end

return M
