local M = {}
local api = vim.api
local text = require("dyadic.text")
local History = require("dyadic.history")
local Detail = require("dyadic.detail")
local Composer = require("dyadic.composer")
local lines_of, one_line, sorted_keys = text.lines_of, text.one_line, text.sorted_keys

local views = {}
local window_states = {}
local owned_options = { "wrap", "linebreak", "number", "relativenumber", "signcolumn", "statusline" }
local rows_ns = api.nvim_create_namespace("dyadic_history")
local widgets_ns = api.nvim_create_namespace("dyadic_widgets")
local render_widgets, statuslines

-- Plugins that resolve the parser from 'filetype' (markdown renderers) find markdown too.
vim.treesitter.language.register("markdown", { "dyadic", "dyadic_composer" })

local function define_highlights()
  for name, link in pairs({
    DyadicTitle = "Title",
    DyadicSpeaker = "Title",
    DyadicMeta = "Comment",
    DyadicActivity = "Comment",
    DyadicTool = "Special",
    DyadicRunning = "DiagnosticWarn",
    DyadicError = "DiagnosticError",
    DyadicQueue = "DiagnosticInfo",
  }) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
end
define_highlights()
-- :colorscheme runs :hi clear, which drops these links.
api.nvim_create_autocmd("ColorScheme", {
  group = api.nvim_create_augroup("DyadicHighlights", { clear = true }),
  callback = define_highlights,
})

local function valid_buf(buf)
  return buf and api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

local function restore_window(win)
  local saved = window_states[win]
  if not saved then
    return
  end
  window_states[win] = nil
  if valid_win(win) then
    for name, value in pairs(saved.options) do
      vim.wo[win][name] = value
    end
  end
end

local function apply_history_options(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
end

local function window_options(win)
  if not window_states[win] then
    local saved = { buf = api.nvim_win_get_buf(win), options = {} }
    for _, name in ipairs(owned_options) do
      saved.options[name] = vim.wo[win][name]
    end
    for other, source in pairs(window_states) do
      if other ~= win and source.buf == saved.buf and valid_win(other) then
        saved.options = vim.deepcopy(source.options)
        break
      end
    end
    window_states[win] = saved
  end
  apply_history_options(win)
end

-- A window dyadic created now shows the history; leaving it restores global defaults.
function M.adopt(win)
  local saved = { buf = api.nvim_win_get_buf(win), options = {} }
  for _, name in ipairs(owned_options) do
    saved.options[name] = api.nvim_get_option_value(name, { scope = "global" })
  end
  window_states[win] = saved
  apply_history_options(win)
  local agent = views[saved.buf]
  if agent then
    M.render(agent)
  end
end

-- Action name -> { <Plug> suffix, default key, buffers that get the default key }.
local actions = {
  submit = { "Submit", "<CR>", "composer" },
  follow_up = { "FollowUp", "<M-CR>", "composer" },
  abort = { "Abort", "<Esc>", "composer" },
  dequeue = { "Dequeue", "<M-Up>", "composer" },
  model = { "Model", "<C-l>", "composer" },
  thinking = { "Thinking", nil, "composer" },
  cycle_thinking = { "CycleThinking", "<S-Tab>", "composer" },
  cycle_model = { "CycleModel", nil, "composer" },
  copy = { "Copy", nil, "composer" },
  settings = { "Settings", "<localleader>s", "composer" },
  new = { "New", nil, "composer" },
  resume = { "Resume", nil, "composer" },
  focus_composer = { "FocusComposer", "<localleader>i", "both" },
  focus_history = { "FocusHistory", "<localleader>r", "composer" },
  toggle_group = { "ToggleGroup", "za", "history" },
  detail = { "Detail", "K", "history" },
  next_message = { "NextMessage", "g]", "history" },
  prev_message = { "PrevMessage", "g[", "history" },
}
M.actions = actions

local history_actions = { toggle_group = true, detail = true, next_message = true, prev_message = true }

-- A window in the current tab that shows the agent's history, preferring the anchor.
local function history_window(agent)
  local anchor = Composer.anchor(agent)
  if anchor and api.nvim_win_get_tabpage(anchor) == api.nvim_get_current_tabpage() then
    return anchor
  end
  if api.nvim_get_current_buf() == agent.history_buf then
    return api.nvim_get_current_win()
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == agent.history_buf and api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

function M.focus(agent, composer)
  local win = history_window(agent)
  if not win then
    M.show(agent)
    win = history_window(agent)
  end
  if not win then
    return
  end
  if composer then
    -- From a history window, the composer opens below that window.
    Composer.attach(agent, win, true)
    render_widgets(agent)
    statuslines(agent)
  else
    api.nvim_set_current_win(win)
  end
end

local function row_at_cursor(agent)
  if api.nvim_get_current_buf() ~= agent.history_buf or not agent._view.model then
    return nil
  end
  return agent._view.rows_by_line[api.nvim_win_get_cursor(0)[1] - 1]
end

local function native(keys)
  pcall(api.nvim_command, "normal! " .. vim.keycode(keys))
end

local function toggle_group(agent, key)
  local group = agent._view.model.groups[key]
  if not group then
    return
  end
  agent.expanded = agent.expanded or {}
  agent.expanded[key] = not group.expanded
  M.render(agent)
  -- Keep the cursor on the group's first row after it changes size.
  for _, row in ipairs(agent._view.model.rows) do
    if row.group == key then
      api.nvim_win_set_cursor(0, { row.line + 1, 0 })
      break
    end
  end
end

local function jump_message(agent, forward)
  local cursor = api.nvim_win_get_cursor(0)[1] - 1
  local roles = agent._view.model and agent._view.model.roles or {}
  local target
  if forward then
    for _, line in ipairs(roles) do
      if line > cursor then
        target = line
        break
      end
    end
  else
    for index = #roles, 1, -1 do
      if roles[index] < cursor then
        target = roles[index]
        break
      end
    end
  end
  if target then
    vim.cmd("normal! m'")
    api.nvim_win_set_cursor(0, { target + 1, 0 })
  end
end

-- Cursor-dependent actions in the history. Off a matching row, fall back to native keys.
function M.action(agent, name)
  if name == "next_message" or name == "prev_message" then
    jump_message(agent, name == "next_message")
    return
  end
  local row = row_at_cursor(agent)
  if name == "toggle_group" then
    if row and row.group then
      toggle_group(agent, row.group)
    else
      native("za")
    end
  elseif name == "detail" then
    if row and row.kind == "group" then
      toggle_group(agent, row.group)
    elseif not (row and row.key and Detail.open(agent, row.key)) then
      native("K")
    end
  end
end

function M.bind(agent)
  for action, spec in pairs(actions) do
    local scope = spec[3]
    for _, buf in ipairs({ agent.history_buf, agent.composer_buf }) do
      local is_composer = buf == agent.composer_buf
      local allowed
      if history_actions[action] then
        allowed = not is_composer
      else
        allowed = (action ~= "submit" and action ~= "follow_up") or is_composer
      end
      if allowed then
        local plug = "<Plug>(Dyadic" .. spec[1] .. ")"
        vim.keymap.set("n", plug, function()
          if agent.closed then
            return
          end
          if action == "submit" then
            agent:submit()
          elseif action == "follow_up" then
            agent:submit("followUp")
          elseif action == "abort" then
            agent:abort()
          elseif action == "dequeue" then
            agent:dequeue()
          else
            agent:action(action)
          end
        end, { buffer = buf, silent = true, desc = "Dyadic " .. action })
        local key = (agent.config.mappings or {})[action]
        if key == nil then
          key = spec[2]
        end
        local in_scope = scope == "both" or (scope == "composer") == is_composer
        if in_scope and type(key) == "string" and key ~= "" then
          vim.keymap.set("n", key, plug, { buffer = buf, remap = true, silent = true, desc = "Dyadic " .. action })
        end
      end
    end
  end
end

local function create_buffer(agent, ft, suffix, editable)
  local buf = api.nvim_create_buf(false, true)
  views[buf] = agent
  api.nvim_buf_set_name(buf, "dyadic://" .. agent.id .. "/" .. suffix)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = ft
  -- Treesitter reparses only changed ranges; regex syntax is the fallback without a parser.
  if not pcall(vim.treesitter.start, buf, "markdown") then
    vim.bo[buf].syntax = "markdown"
  end
  vim.bo[buf].modifiable = editable
  if not editable then
    -- The history is only written by the renderer; keep no undo history for it.
    vim.bo[buf].undolevels = -1
  end
  if editable and agent.config.completion ~= false then
    vim.bo[buf].omnifunc = "v:lua.require'dyadic.view'.complete"
  end
  return buf
end

function M.new(agent)
  agent._view = { dialogs = {}, seen_dialogs = {}, details = {}, rows_by_line = {}, disposed = false }
  agent.widgets = agent.widgets or {}
  agent.statuses = agent.statuses or {}
  agent.history_buf = create_buffer(agent, "dyadic", "history", false)
  agent.composer_buf = create_buffer(agent, "dyadic_composer", "composer", true)
  agent._view.group = api.nvim_create_augroup("DyadicView" .. agent.id, { clear = true })
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = agent._view.group,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      if window_states[win] and window_states[win].buf ~= ev.buf then
        restore_window(win)
      end
      if ev.buf == agent.history_buf and not window_states[win] then
        window_options(win)
      end
      -- Hidden histories are not rendered; catch up when one is shown again.
      if ev.event == "BufWinEnter" and ev.buf == agent.history_buf and agent._view.stale then
        M.render(agent)
      end
    end,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = agent._view.group,
    callback = function(ev)
      if ev.buf ~= agent.history_buf then
        return
      end
      local win = api.nvim_get_current_win()
      if window_states[win] and window_states[win].buf == ev.buf then
        restore_window(win)
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = agent._view.group,
    callback = function(ev)
      window_states[tonumber(ev.match)] = nil
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = agent._view.group,
    callback = function(ev)
      if ev.buf == agent.composer_buf and not agent.closed then
        render_widgets(agent)
        Composer.resize(agent)
      end
    end,
  })
  M.bind(agent)
  M.render(agent)
  return agent.history_buf, agent.composer_buf
end

-- Free placement: an existing history window in this tab, else the current window. A
-- composer or floating window is not replaced; its tab gets a new split instead.
local function free_placement(agent)
  local win = history_window(agent)
  if win then
    return win
  end
  win = api.nvim_get_current_win()
  local other = views[api.nvim_win_get_buf(win)]
  if other and Composer.window(other) == win then
    win = Composer.anchor(other) or win
  end
  if api.nvim_win_get_config(win).relative ~= "" or vim.wo[win].winfixbuf then
    win = api.nvim_open_win(agent.history_buf, true, { split = "above", win = -1 })
  end
  api.nvim_win_set_buf(win, agent.history_buf)
  return win
end

function M.show(agent)
  if agent.closed or not valid_buf(agent.history_buf) then
    return
  end
  if not valid_buf(agent.composer_buf) or not api.nvim_buf_is_loaded(agent.composer_buf) then
    views[agent.composer_buf] = nil
    if valid_buf(agent.composer_buf) then
      api.nvim_buf_delete(agent.composer_buf, { force = true })
    end
    agent.composer_buf = create_buffer(agent, "dyadic_composer", "composer", true)
    M.bind(agent)
  end
  local anchor = free_placement(agent)
  for _, win in ipairs(vim.fn.win_findbuf(agent.history_buf)) do
    if not window_states[win] then
      window_options(win)
    end
  end
  Composer.attach(agent, anchor, true)
  M.render(agent)
end

function M.get_draft(agent)
  if not valid_buf(agent.composer_buf) then
    return ""
  end
  return table.concat(api.nvim_buf_get_lines(agent.composer_buf, 0, -1, false), "\n")
end

function M.set_draft(agent, value)
  if valid_buf(agent.composer_buf) then
    api.nvim_buf_set_lines(agent.composer_buf, 0, -1, false, vim.split(value or "", "\n", { plain = true }))
    render_widgets(agent)
  end
end

-- Slash commands are only recognized at the start of the composer line; elsewhere, a
-- leading slash is an absolute path. Pass the decision from findstart to the match call.
local complete_command = false

function M.complete(findstart, base)
  local buf = api.nvim_get_current_buf()
  local agent = views[buf]
  if not agent or buf ~= agent.composer_buf then
    return findstart == 1 and -3 or {}
  end
  if findstart == 1 then
    local line = api.nvim_get_current_line():sub(1, api.nvim_win_get_cursor(0)[2])
    complete_command = line:sub(1, 1) == "/"
    if complete_command then
      return 0
    end
    local token = line:match("%S*$") or ""
    return #line - #token
  end
  local result = {}
  if complete_command then
    return require("dyadic.commands").complete(agent, base)
  end
  local reference = base:sub(1, 1) == "@"
  if reference then
    base = base:sub(2)
  end
  local absolute = base:sub(1, 1) == "/" or base:sub(1, 1) == "~"
  local prefix = absolute and vim.fn.expand(base) or (agent.cwd .. "/" .. base)
  local matches = vim.fn.glob(vim.fn.escape(prefix, "*?[]{}") .. "*", false, true)
  for _, path in ipairs(matches) do
    local word = absolute and path or path:sub(#agent.cwd + 2)
    if vim.fn.isdirectory(path) == 1 then
      word = word .. "/"
    end
    result[#result + 1] = (reference and "@" or "") .. word
  end
  return result
end

-- Status shown on the history window, built from agent:status().
local function footer(agent)
  local status = agent:status()
  local parts = { one_line(status.title), one_line(status.phase) }
  if status.model then
    parts[#parts + 1] = one_line(status.model)
  end
  if status.thinking then
    parts[#parts + 1] = "thinking " .. one_line(status.thinking)
  end
  local context = status.context
  if context then
    local tokens = context.tokens and tostring(context.tokens) or "?"
    local percent = context.percent and string.format(" %.1f%%", context.percent) or ""
    parts[#parts + 1] = "ctx " .. tokens .. "/" .. tostring(context.window or "?") .. percent
  end
  if status.tokens then
    parts[#parts + 1] = "tokens " .. tostring(status.tokens)
  end
  if status.cost then
    parts[#parts + 1] = string.format("$%.4f", status.cost)
  end
  for _, value in ipairs(status.extensions) do
    parts[#parts + 1] = one_line(value)
  end
  return table.concat(parts, " | ")
end

render_widgets = function(agent)
  if not valid_buf(agent.composer_buf) then
    return
  end
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(agent.composer_buf)) do
    if valid_win(win) then
      api.nvim_win_call(win, function()
        snapshots[win] = vim.fn.winsaveview()
      end)
    end
  end
  api.nvim_buf_clear_namespace(agent.composer_buf, widgets_ns, 0, -1)
  local above, below = {}, {}
  for _, key in ipairs(sorted_keys(agent.widgets)) do
    local widget = agent.widgets[key]
    local target = widget.placement == "belowEditor" and below or above
    for _, value in ipairs(widget.lines or {}) do
      for _, line in ipairs(lines_of(value)) do
        target[#target + 1] = { { line, "Comment" } }
      end
    end
  end
  if #above > 0 then
    api.nvim_buf_set_extmark(
      agent.composer_buf,
      widgets_ns,
      0,
      0,
      { virt_lines = above, virt_lines_above = true, right_gravity = false }
    )
  end
  if #below > 0 then
    api.nvim_buf_set_extmark(
      agent.composer_buf,
      widgets_ns,
      api.nvim_buf_line_count(agent.composer_buf) - 1,
      0,
      { virt_lines = below }
    )
  end
  Composer.resize(agent)
  for win, saved in pairs(snapshots) do
    if saved.topline == 1 then
      saved.topfill = math.min(#above, math.max(0, api.nvim_win_get_height(win) - saved.lnum))
      api.nvim_win_call(win, function()
        vim.fn.winrestview(saved)
      end)
    end
  end
end

statuslines = function(agent)
  local status = (" " .. footer(agent)):gsub("%%", "%%%%")
  for _, win in ipairs(vim.fn.win_findbuf(agent.history_buf)) do
    if valid_win(win) then
      vim.wo[win].statusline = status
    end
  end
  if valid_buf(agent.composer_buf) then
    for _, win in ipairs(vim.fn.win_findbuf(agent.composer_buf)) do
      if valid_win(win) then
        vim.wo[win].statusline = " Composer"
      end
    end
  end
end

-- Write only the changed line range, then re-apply overlay rows.
local function write(agent, model)
  local buf = agent.history_buf
  local lines = model.lines
  local old_count = api.nvim_buf_line_count(buf)
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if valid_win(win) then
      api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        snapshots[#snapshots + 1] = { win = win, view = view, bottom = view.lnum >= old_count }
      end)
    end
  end
  local old_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local first = 1
  while first <= #old_lines and first <= #lines and old_lines[first] == lines[first] do
    first = first + 1
  end
  if first <= #old_lines or first <= #lines then
    local last_old, last_new = #old_lines, #lines
    while last_old >= first and last_new >= first and old_lines[last_old] == lines[last_new] do
      last_old, last_new = last_old - 1, last_new - 1
    end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, first - 1, last_old, false, vim.list_slice(lines, first, last_new))
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end
  api.nvim_buf_clear_namespace(buf, rows_ns, 0, -1)
  local by_line = {}
  for _, row in ipairs(model.rows) do
    by_line[row.line] = row
    api.nvim_buf_set_extmark(buf, rows_ns, row.line, 0, {
      virt_text = row.chunks,
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end
  agent._view.rows_by_line = by_line
  -- Follow output only in windows whose cursor was on the last line.
  for _, snapshot in ipairs(snapshots) do
    if valid_win(snapshot.win) then
      api.nvim_win_call(snapshot.win, function()
        if snapshot.bottom then
          api.nvim_win_set_cursor(snapshot.win, { #lines, 0 })
          vim.cmd("normal! zb")
        else
          snapshot.view.lnum = math.min(snapshot.view.lnum, #lines)
          vim.fn.winrestview(snapshot.view)
        end
      end)
    end
  end
end

function M.render(agent, opts)
  if agent.closed or not agent._view or agent._view.disposed or not valid_buf(agent.history_buf) then
    return
  end
  if valid_buf(agent.composer_buf) and #vim.fn.win_findbuf(agent.composer_buf) > 0 then
    render_widgets(agent)
    statuslines(agent)
  end
  local shown = #vim.fn.win_findbuf(agent.history_buf) > 0
  if not shown and not Detail.any_visible(agent) and not (opts and opts.force) then
    agent._view.stale = true
    return
  end
  agent._view.stale = false
  local model = History.build(agent, opts)
  agent._view.model = model
  write(agent, model)
  statuslines(agent)
  Detail.refresh(agent)
end

function M.dispose(agent)
  if not agent._view or agent._view.disposed then
    return
  end
  agent._view.disposed = true
  require("dyadic.extension_ui").dispose_dialogs(agent)
  Detail.dispose(agent)
  Composer.dispose(agent)
  views[agent.history_buf], views[agent.composer_buf] = nil, nil
  for win, saved in pairs(window_states) do
    if saved.buf == agent.history_buf or saved.buf == agent.composer_buf then
      restore_window(win)
    end
  end
  if agent._view.group then
    pcall(api.nvim_del_augroup_by_id, agent._view.group)
  end
  if valid_buf(agent.composer_buf) then
    pcall(api.nvim_buf_delete, agent.composer_buf, { force = true })
  end
end

return M
