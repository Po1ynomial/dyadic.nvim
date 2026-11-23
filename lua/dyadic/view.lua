local M = {}
local api = vim.api
local text = require("dyadic.text")
local History = require("dyadic.history")
local Detail = require("dyadic.detail")
local Composer = require("dyadic.composer")
local Sidebar = require("dyadic.sidebar")
local Bars = require("dyadic.bars")
local lines_of, one_line, sorted_keys = text.lines_of, text.one_line, text.sorted_keys

local views = {}
local window_states = {}
local owned_options = { "wrap", "linebreak", "number", "relativenumber", "signcolumn", "statusline", "winbar" }
local rows_ns = api.nvim_create_namespace("dyadic_history")
local widgets_ns = api.nvim_create_namespace("dyadic_widgets")
local render_widgets, statuslines

-- Plugins that resolve the parser from 'filetype' (markdown renderers) find markdown too.
vim.treesitter.language.register("markdown", { "dyadic", "dyadic_composer" })

-- How much stronger than its line's tint a changed word's background is.
local WORD_STRENGTH = 2

local function channels(color)
  return { math.floor(color / 65536), math.floor(color / 256) % 256, color % 256 }
end

-- `from` moved `amount` times the way to `to`: 0.3 mixes, 2 goes twice as far.
local function shift(from, to, amount)
  local a, b, out = channels(from), channels(to), 0
  for i = 1, 3 do
    out = out * 256 + math.max(0, math.min(255, math.floor(a[i] + (b[i] - a[i]) * amount + 0.5)))
  end
  return out
end

local function resolved(name)
  return api.nvim_get_hl(0, { name = name, link = false })
end

-- Changed words get their line's tint, stronger: the line's background moved further from
-- the editor's. A line without a background, such as a red-text-only DiffDelete, tints
-- the editor's background with its text colour instead. Without a GUI colour to start
-- from, the words fall back to Vim's diff groups.
local function define_word_highlights()
  local normal = resolved("Normal").bg or (vim.o.background == "light" and 0xffffff or 0x000000)
  for name, side in pairs({
    -- DiffTextAdd is new in Neovim 0.12.
    DyadicReviewAddText = { line = "DyadicReviewAdd", text = "Added", fallback = "DiffTextAdd" },
    DyadicReviewDeleteText = { line = "DyadicReviewDelete", text = "Removed", fallback = "DiffText" },
  }) do
    local line = resolved(side.line)
    local fallback = vim.fn.hlexists(side.fallback) == 1 and side.fallback or "DiffText"
    local tint = line.fg or resolved(side.text).fg
    local bg = line.bg and shift(normal, line.bg, WORD_STRENGTH) or (tint and shift(normal, tint, 0.3))
    if bg then
      api.nvim_set_hl(0, name, { bg = bg, ctermbg = resolved(fallback).ctermbg, default = true })
    else
      api.nvim_set_hl(0, name, { link = fallback, default = true })
    end
  end
end

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
    DyadicSpeakerUser = "Identifier",
    DyadicSpeakerAssistant = "Title",
    DyadicGroupBar = "DiagnosticHint",
    DyadicShellBar = "Comment",
    DyadicCompaction = "Special",
    DyadicBranch = "DiagnosticWarn",
    DyadicFooter = "Comment",
    DyadicSpinner = "DiagnosticInfo",
    DyadicPhase = "Comment",
    DyadicWarn = "DiagnosticWarn",
    DyadicTreeLine = "Comment",
    DyadicTreeActive = "Identifier",
    DyadicTreeLabel = "DiagnosticWarn",
    DyadicSessionNamed = "DiagnosticWarn",
    DyadicSessionDir = "Directory",
    DyadicReviewAdd = "DiffAdd",
    DyadicReviewDelete = "DiffDelete",
    DyadicReviewTitle = "Title",
    DyadicReviewHint = "Comment",
    DyadicReviewKey = "Special",
  }) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
  define_word_highlights()
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

function M.agent_of(buf)
  return views[buf]
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
  settings = { "Settings", nil, "composer" },
  new = { "New", nil, "composer" },
  resume = { "Resume", nil, "composer" },
  tree = { "Tree", nil, "both" },
  fork = { "Fork", nil, "both" },
  toggle_group = { "ToggleGroup", "za", "history" },
  detail = { "Detail", "K", "history" },
  next_message = { "NextMessage", "g]", "history" },
  prev_message = { "PrevMessage", "g[", "history" },
  goto_file = { "GotoFile", "gf", "history" },
  goto_file_line = { "GotoFileLine", "gF", "history" },
  split_file = { "SplitFile", "<C-w>f", "history" },
  insert = { "Insert", "i", "history" },
  append = { "Append", "a", "history" },
  insert_start = { "InsertStart", "I", "history" },
  append_end = { "AppendEnd", "A", "history" },
  open_below = { "OpenBelow", "o", "history" },
  open_above = { "OpenAbove", "O", "history" },
}
M.actions = actions

local history_actions = {
  toggle_group = true,
  detail = true,
  next_message = true,
  prev_message = true,
  goto_file = true,
  goto_file_line = true,
  split_file = true,
  insert = true,
  append = true,
  insert_start = true,
  append_end = true,
  open_below = true,
  open_above = true,
}
-- Insert keys of the history -> where Insert mode starts in the draft.
local compose_actions = {
  insert = "cursor",
  append = "after",
  insert_start = "start",
  append_end = "end",
  open_below = "below",
  open_above = "above",
}
-- File actions -> { native key, Sidebar.open_file mode }.
local file_actions =
  { goto_file = { "gf", "edit" }, goto_file_line = { "gF", "gF" }, split_file = { "<C-w>f", "split" } }

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

-- Go from the history into its composer in Insert mode: at the draft's cursor, after it,
-- at its start or end, or on a new line below or above it. An empty draft just starts.
local function compose(agent, where)
  M.focus(agent, true)
  local win = Composer.window(agent)
  if not win or api.nvim_get_current_win() ~= win then
    return
  end
  local buf = agent.composer_buf
  local count = api.nvim_buf_line_count(buf)
  local empty = count == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  -- Keys are inserted ahead of typeahead, so they run before what is typed next.
  local function feed(key)
    api.nvim_feedkeys(key, "ni", false)
  end
  if empty or where == "cursor" then
    vim.cmd.startinsert()
  elseif where == "after" then
    feed("a")
  elseif where == "start" then
    api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd.startinsert()
  elseif where == "end" then
    api.nvim_win_set_cursor(win, { count, 0 })
    vim.cmd.startinsert({ bang = true })
  elseif where == "below" then
    api.nvim_win_set_cursor(win, { count, 0 })
    feed("o")
  else
    api.nvim_win_set_cursor(win, { 1, 0 })
    feed("O")
  end
end

-- The session entry shown at the cursor in the history, if the history is current.
function M.entry_at_cursor(agent)
  if api.nvim_get_current_buf() ~= agent.history_buf or not agent._view.model then
    return nil
  end
  local line = api.nvim_win_get_cursor(0)[1] - 1
  local found
  for _, mark in ipairs(agent._view.model.marks or {}) do
    if mark.line > line then
      break
    end
    found = mark.entry
  end
  -- Usage rows belong to the entry that billed them.
  return found and (found:gsub(":usage$", "")) or nil
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
  local roles = agent._view.model and agent._view.model.speakers or {}
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
  if compose_actions[name] then
    compose(agent, compose_actions[name])
    return
  end
  if name == "next_message" or name == "prev_message" then
    jump_message(agent, name == "next_message")
    return
  end
  if file_actions[name] then
    -- The sidebar keeps its buffer; files open in the main area instead.
    if Sidebar.contains(api.nvim_get_current_win()) then
      Sidebar.open_file(agent, file_actions[name][2])
    else
      native(file_actions[name][1])
    end
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
      -- K always shows more: it expands a collapsed group and leaves an open one.
      if not row.open then
        toggle_group(agent, row.group)
      end
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
    require("dyadic.completion").attach(agent, buf)
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

-- Free placement: an existing history window in this tab, else the current window, which
-- gets back what it showed when the pair hides. Another agent's pair passes on what its
-- window showed before. A composer or floating window is not replaced; its tab gets a new
-- split instead.
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
  else
    local shown = api.nvim_win_get_buf(win)
    Composer.take(agent, win, Composer.taken(win) or (not views[shown] and shown or nil))
  end
  api.nvim_win_set_buf(win, agent.history_buf)
  return win
end

function M.show(agent)
  if agent.closed or not valid_buf(agent.history_buf) then
    return
  end
  local anchor = agent.config.placement == "sidebar" and Sidebar.show(agent) or free_placement(agent)
  for _, win in ipairs(vim.fn.win_findbuf(agent.history_buf)) do
    if not window_states[win] then
      window_options(win)
    end
  end
  local win = Composer.attach(agent, anchor, false)
  -- Back to the window of the pair used last, else the history.
  api.nvim_set_current_win(Composer.focused(agent) == "composer" and win or anchor)
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
  -- Order below the draft, as in pi: widgets placed below the editor, then the footer.
  vim.list_extend(below, Bars.footer(agent))
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

local function set_option(win, name, value)
  if vim.wo[win][name] ~= value then
    vim.wo[win][name] = value
  end
end

local function composer_bar(agent)
  local wins = Composer.windows(agent)
  if #wins > 0 then
    local bar = Bars.composer_winbar(agent, agent._view.frame)
    for _, win in ipairs(wins) do
      set_option(win, "winbar", bar)
    end
  end
end

-- While the agent works and is shown, the spinner turns and the run timer in the history
-- counts up once a second.
local function spin(agent)
  local view = agent._view
  local shown = #Composer.windows(agent) > 0 or #vim.fn.win_findbuf(agent.history_buf) > 0
  local wanted = Bars.busy(agent) and shown and not agent.closed
  if wanted and not view.spinner then
    view.frame = 1
    view.spinner = vim.uv.new_timer()
    view.spinner:start(
      100,
      100,
      vim.schedule_wrap(function()
        if view.spinner then
          view.frame = view.frame % #Bars.SPINNER + 1
          composer_bar(agent)
          if view.frame == 1 and agent.active then
            agent:render()
          end
        end
      end)
    )
  elseif not wanted and view.spinner then
    view.spinner:stop()
    view.spinner:close()
    view.spinner = nil
  end
end

-- Window bars and statuslines of the agent's windows.
statuslines = function(agent)
  local statusline = agent.config.statusline ~= false
  local history_bar = Bars.history_winbar(agent)
  for _, win in ipairs(vim.fn.win_findbuf(agent.history_buf)) do
    if valid_win(win) then
      set_option(win, "winbar", history_bar)
      if statusline then
        set_option(win, "statusline", Bars.statusline(agent, "history"))
      end
    end
  end
  if statusline then
    for _, win in ipairs(Composer.windows(agent)) do
      set_option(win, "statusline", Bars.statusline(agent, "composer"))
    end
  end
  composer_bar(agent)
  spin(agent)
end

local function set_row(buf, row)
  api.nvim_buf_set_extmark(buf, rows_ns, row.line, 0, {
    virt_text = row.chunks,
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
  if row.right then
    api.nvim_buf_set_extmark(buf, rows_ns, row.line, 0, {
      virt_text = row.right,
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
  end
end

-- Write only the changed line range, then re-apply the overlay rows from the first one that
-- changed. Rows of cached runs keep their chunk tables, so unchanged rows are found by
-- identity.
local function write(agent, model, previous)
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
  -- The buffer is written only here, so the last written lines are its content.
  local old_lines = agent._view.lines
  if not old_lines or #old_lines ~= old_count then
    old_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  end
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
  agent._view.lines = lines
  -- Rows before the first changed line or row keep their extmarks.
  local changed = first - 1
  local old_rows = previous and previous.rows or {}
  local index = 1
  while index <= #model.rows and index <= #old_rows do
    local new, old = model.rows[index], old_rows[index]
    if new.line ~= old.line or new.line >= changed or new.chunks ~= old.chunks or new.right ~= old.right then
      break
    end
    index = index + 1
  end
  local from = changed
  if model.rows[index] then
    from = math.min(from, model.rows[index].line)
  end
  if old_rows[index] then
    from = math.min(from, old_rows[index].line)
  end
  api.nvim_buf_clear_namespace(buf, rows_ns, from, -1)
  local by_line = {}
  for position, row in ipairs(model.rows) do
    by_line[row.line] = row
    if position >= index then
      set_row(buf, row)
    end
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

-- Double Esc, as in pi: while the agent is idle, <Esc><Esc> runs the `double_escape` action
-- (from the composer only with an empty draft); while it works, the composer's <Esc> aborts.
-- The maps are swapped when work starts and ends, so an abort never waits for 'timeoutlen'.
local function sync_escape(agent)
  local action = agent.config.double_escape or "tree"
  local working = agent.active == true
  if action == "none" or agent._view.escape_working == working then
    return
  end
  agent._view.escape_working = working
  local abort_key = (agent.config.mappings or {}).abort
  if abort_key == nil then
    abort_key = actions.abort[2]
  end
  for _, buf in ipairs({ agent.history_buf, agent.composer_buf }) do
    if valid_buf(buf) then
      local composer = buf == agent.composer_buf
      pcall(vim.keymap.del, "n", "<Esc><Esc>", { buffer = buf })
      if composer and abort_key == "<Esc>" then
        if working then
          vim.keymap.set(
            "n",
            "<Esc>",
            "<Plug>(DyadicAbort)",
            { buffer = buf, remap = true, silent = true, desc = "Dyadic abort" }
          )
        else
          pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
        end
      end
      if not working then
        vim.keymap.set("n", "<Esc><Esc>", function()
          if agent.closed or (composer and agent:get_draft():find("%S")) then
            return
          end
          require("dyadic.commands").run(agent, "/" .. action)
        end, { buffer = buf, silent = true, desc = "Dyadic " .. action })
      end
    end
  end
end

function M.render(agent, opts)
  if agent.closed or not agent._view or agent._view.disposed or not valid_buf(agent.history_buf) then
    return
  end
  sync_escape(agent)
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
  local previous = agent._view.model
  agent._view.model = model
  write(agent, model, previous)
  statuslines(agent)
  Detail.refresh(agent)
end

-- A buffer reloaded with :e lost its text and marks: the composer gets back the draft it had
-- when unloaded, and the history is written again in full.
function M.reloaded(agent, buf, draft)
  if agent.closed or not agent._view or agent._view.disposed then
    return
  end
  api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  if not pcall(vim.treesitter.start, buf, "markdown") then
    vim.bo[buf].syntax = "markdown"
  end
  if buf == agent.composer_buf then
    api.nvim_buf_set_lines(buf, 0, -1, false, draft or { "" })
    vim.bo[buf].modified = false
  else
    agent._view.lines, agent._view.model = nil, nil
  end
  M.render(agent, { force = true })
end

function M.dispose(agent)
  if not agent._view or agent._view.disposed then
    return
  end
  agent._view.disposed = true
  if agent._view.spinner then
    agent._view.spinner:stop()
    agent._view.spinner:close()
    agent._view.spinner = nil
  end
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
