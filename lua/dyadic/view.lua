local M = {}
local api = vim.api
local text = require("dyadic.text")
local Transcript = require("dyadic.transcript")
local Detail = require("dyadic.detail")
local lines_of, one_line, sorted_keys = text.lines_of, text.one_line, text.sorted_keys

local views = {}
local window_states = {}
local owned_options = { "wrap", "linebreak", "number", "relativenumber", "signcolumn", "statusline" }
local rows_ns = api.nvim_create_namespace("dyadic_transcript")
local widgets_ns = api.nvim_create_namespace("dyadic_widgets")
local render_widgets

-- Plugins that resolve the parser from 'filetype' (markdown renderers) find markdown too.
vim.treesitter.language.register("markdown", { "dyadic", "dyadic_input" })

local function define_highlights()
  for name, link in pairs({
    DyadicTitle = "Title",
    DyadicRole = "Title",
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
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
end

-- Action name -> { <Plug> suffix, default key, buffers that get the default key }.
local actions = {
  submit = { "Submit", "<CR>", "draft" },
  follow_up = { "FollowUp", "<M-CR>", "draft" },
  abort = { "Abort", "<Esc>", "draft" },
  dequeue = { "Dequeue", "<M-Up>", "draft" },
  model = { "Model", "<C-l>", "draft" },
  thinking = { "Thinking", nil, "draft" },
  cycle_thinking = { "CycleThinking", "<S-Tab>", "draft" },
  cycle_model = { "CycleModel", nil, "draft" },
  copy = { "Copy", nil, "draft" },
  settings = { "Settings", "<localleader>s", "draft" },
  new = { "New", nil, "draft" },
  resume = { "Resume", nil, "draft" },
  focus_draft = { "FocusDraft", "<localleader>i", "both" },
  focus_transcript = { "FocusTranscript", "<localleader>r", "draft" },
  toggle_activity = { "ToggleActivity", "za", "transcript" },
  details = { "Details", "K", "transcript" },
  next_message = { "NextMessage", "g]", "transcript" },
  prev_message = { "PrevMessage", "g[", "transcript" },
}
M.actions = actions

local transcript_actions = { toggle_activity = true, details = true, next_message = true, prev_message = true }

function M.focus(s, draft)
  local buf = draft and s.draft or s.buf
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == buf then
      api.nvim_set_current_win(win)
      return
    end
  end
  M.show(s)
  if not draft then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == s.buf then
        api.nvim_set_current_win(win)
        return
      end
    end
  end
end

local function row_at_cursor(s)
  if api.nvim_get_current_buf() ~= s.buf or not s._view.model then
    return nil
  end
  return s._view.rows_by_line[api.nvim_win_get_cursor(0)[1] - 1]
end

local function native(keys)
  pcall(vim.cmd, "normal! " .. vim.keycode(keys))
end

local function toggle_group(s, key)
  local group = s._view.model.groups[key]
  if not group then
    return
  end
  s.expanded = s.expanded or {}
  s.expanded[key] = not group.expanded
  M.render(s)
  -- Keep the cursor on the group's first row after it changes size.
  for _, row in ipairs(s._view.model.rows) do
    if row.group == key then
      api.nvim_win_set_cursor(0, { row.line + 1, 0 })
      break
    end
  end
end

local function jump_message(s, forward)
  local cursor = api.nvim_win_get_cursor(0)[1] - 1
  local roles = s._view.model and s._view.model.roles or {}
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

-- Cursor-dependent actions in the transcript. Off a matching row, fall back to native keys.
function M.action(s, name)
  if name == "next_message" or name == "prev_message" then
    jump_message(s, name == "next_message")
    return
  end
  local row = row_at_cursor(s)
  if name == "toggle_activity" then
    if row and row.group then
      toggle_group(s, row.group)
    else
      native("za")
    end
  elseif name == "details" then
    if row and row.kind == "group" then
      toggle_group(s, row.group)
    elseif not (row and row.key and Detail.open(s, row.key)) then
      native("K")
    end
  end
end

function M.bind(s)
  for action, spec in pairs(actions) do
    local scope = spec[3]
    for _, buf in ipairs({ s.buf, s.draft }) do
      local is_draft = buf == s.draft
      local allowed
      if transcript_actions[action] then
        allowed = not is_draft
      else
        allowed = (action ~= "submit" and action ~= "follow_up") or is_draft
      end
      if allowed then
        local plug = "<Plug>(Dyadic" .. spec[1] .. ")"
        vim.keymap.set("n", plug, function()
          if s.closed then
            return
          end
          if action == "submit" then
            s:submit()
          elseif action == "follow_up" then
            s:submit("followUp")
          elseif action == "abort" then
            s:abort()
          elseif action == "dequeue" then
            s:dequeue()
          else
            s:action(action)
          end
        end, { buffer = buf, silent = true, desc = "Dyadic " .. action })
        local key = (s.config.mappings or {})[action]
        if key == nil then
          key = spec[2]
        end
        local in_scope = scope == "both" or (scope == "draft") == is_draft
        if in_scope and type(key) == "string" and key ~= "" then
          vim.keymap.set("n", key, plug, { buffer = buf, remap = true, silent = true, desc = "Dyadic " .. action })
        end
      end
    end
  end
end

local function create_buffer(s, ft, suffix, editable)
  local buf = api.nvim_create_buf(false, true)
  views[buf] = s
  api.nvim_buf_set_name(buf, "dyadic://" .. s.id .. "/" .. suffix)
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
    -- The transcript is only written by the renderer; keep no undo history for it.
    vim.bo[buf].undolevels = -1
  end
  if editable and s.config.completion ~= false then
    vim.bo[buf].omnifunc = "v:lua.require'dyadic.view'.complete"
  end
  return buf
end

function M.new(s)
  s._view = { dialogs = {}, seen_dialogs = {}, details = {}, rows_by_line = {}, disposed = false }
  s.widgets = s.widgets or {}
  s.statuses = s.statuses or {}
  s.buf = create_buffer(s, "dyadic", "transcript", false)
  s.draft = create_buffer(s, "dyadic_input", "draft", true)
  s._view.group = api.nvim_create_augroup("DyadicView" .. s.id, { clear = true })
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = s._view.group,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      if window_states[win] and window_states[win].buf ~= ev.buf then
        restore_window(win)
      end
      if (ev.buf == s.buf or ev.buf == s.draft) and not window_states[win] then
        window_options(win)
      end
      -- Hidden conversations are not rendered; catch up when one is shown again.
      if ev.event == "BufWinEnter" and ev.buf == s.buf and s._view.stale then
        M.render(s)
      end
    end,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = s._view.group,
    callback = function(ev)
      if ev.buf ~= s.buf and ev.buf ~= s.draft then
        return
      end
      local win = api.nvim_get_current_win()
      if window_states[win] and window_states[win].buf == ev.buf then
        restore_window(win)
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = s._view.group,
    callback = function(ev)
      window_states[tonumber(ev.match)] = nil
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = s._view.group,
    callback = function(ev)
      if ev.buf == s.draft and not s.closed then
        render_widgets(s)
      end
    end,
  })
  M.bind(s)
  M.render(s)
  return s.buf, s.draft
end

-- Default layout: transcript in the current window, draft in a split below it.
local function split_layout(s)
  local transcript_win, draft_win
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if buf == s.buf then
      transcript_win = win
    end
    if buf == s.draft then
      draft_win = win
    end
  end
  if not transcript_win then
    transcript_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(transcript_win, s.buf)
  end
  if not draft_win then
    draft_win = api.nvim_open_win(s.draft, false, {
      split = "below",
      win = transcript_win,
      height = math.max(1, s.config.draft_height or 6),
    })
  end
  api.nvim_set_current_win(draft_win)
end

function M.show(s)
  if s.closed or not valid_buf(s.buf) then
    return
  end
  if not valid_buf(s.draft) or not api.nvim_buf_is_loaded(s.draft) then
    views[s.draft] = nil
    if valid_buf(s.draft) then
      api.nvim_buf_delete(s.draft, { force = true })
    end
    s.draft = create_buffer(s, "dyadic_input", "draft", true)
    M.bind(s)
  end
  local layout = s.config.layout or split_layout
  layout(s)
  for _, buf in ipairs({ s.buf, s.draft }) do
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if not window_states[win] then
        window_options(win)
      end
    end
  end
  M.render(s)
end

function M.get_draft(s)
  if not valid_buf(s.draft) then
    return ""
  end
  return table.concat(api.nvim_buf_get_lines(s.draft, 0, -1, false), "\n")
end

function M.set_draft(s, value)
  if valid_buf(s.draft) then
    api.nvim_buf_set_lines(s.draft, 0, -1, false, vim.split(value or "", "\n", { plain = true }))
    render_widgets(s)
  end
end

-- Slash commands are only recognized at the start of the draft line; elsewhere, a
-- leading slash is an absolute path. Pass the decision from findstart to the match call.
local complete_command = false

function M.complete(findstart, base)
  local buf = api.nvim_get_current_buf()
  local s = views[buf]
  if not s or buf ~= s.draft then
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
    return require("dyadic.commands").complete(s, base)
  end
  local reference = base:sub(1, 1) == "@"
  if reference then
    base = base:sub(2)
  end
  local absolute = base:sub(1, 1) == "/" or base:sub(1, 1) == "~"
  local prefix = absolute and vim.fn.expand(base) or (s.cwd .. "/" .. base)
  local matches = vim.fn.glob(vim.fn.escape(prefix, "*?[]{}") .. "*", false, true)
  for _, path in ipairs(matches) do
    local word = absolute and path or path:sub(#s.cwd + 2)
    if vim.fn.isdirectory(path) == 1 then
      word = word .. "/"
    end
    result[#result + 1] = (reference and "@" or "") .. word
  end
  return result
end

-- Status shown on the transcript window, built from session:status().
local function footer(s)
  local status = s:status()
  local parts = { one_line(status.title), one_line(status.status) }
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

render_widgets = function(s)
  if not valid_buf(s.draft) then
    return
  end
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(s.draft)) do
    if valid_win(win) then
      api.nvim_win_call(win, function()
        snapshots[win] = vim.fn.winsaveview()
      end)
    end
  end
  api.nvim_buf_clear_namespace(s.draft, widgets_ns, 0, -1)
  local above, below = {}, {}
  for _, key in ipairs(sorted_keys(s.widgets)) do
    local widget = s.widgets[key]
    local target = widget.placement == "belowEditor" and below or above
    for _, value in ipairs(widget.lines or {}) do
      for _, line in ipairs(lines_of(value)) do
        target[#target + 1] = { { line, "Comment" } }
      end
    end
  end
  if #above > 0 then
    api.nvim_buf_set_extmark(
      s.draft,
      widgets_ns,
      0,
      0,
      { virt_lines = above, virt_lines_above = true, right_gravity = false }
    )
  end
  if #below > 0 then
    api.nvim_buf_set_extmark(s.draft, widgets_ns, api.nvim_buf_line_count(s.draft) - 1, 0, { virt_lines = below })
  end
  for win, saved in pairs(snapshots) do
    if saved.topline == 1 then
      saved.topfill = math.min(#above, math.max(0, api.nvim_win_get_height(win) - saved.lnum))
      api.nvim_win_call(win, function()
        vim.fn.winrestview(saved)
      end)
    end
  end
end

local function statuslines(s)
  local status = (" " .. footer(s)):gsub("%%", "%%%%")
  for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
    if valid_win(win) then
      vim.wo[win].statusline = status
    end
  end
  if valid_buf(s.draft) then
    for _, win in ipairs(vim.fn.win_findbuf(s.draft)) do
      if valid_win(win) then
        vim.wo[win].statusline = " Draft"
      end
    end
  end
end

-- Write only the changed line range, then re-apply overlay rows.
local function write(s, model)
  local buf = s.buf
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
  s._view.rows_by_line = by_line
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

function M.render(s, opts)
  if s.closed or not s._view or s._view.disposed or not valid_buf(s.buf) then
    return
  end
  if valid_buf(s.draft) and #vim.fn.win_findbuf(s.draft) > 0 then
    render_widgets(s)
    statuslines(s)
  end
  local shown = #vim.fn.win_findbuf(s.buf) > 0
  if not shown and not Detail.any_visible(s) and not (opts and opts.force) then
    s._view.stale = true
    return
  end
  s._view.stale = false
  local model = Transcript.build(s, opts)
  s._view.model = model
  write(s, model)
  statuslines(s)
  Detail.refresh(s)
end

function M.dispose(s)
  if not s._view or s._view.disposed then
    return
  end
  s._view.disposed = true
  require("dyadic.extension_ui").dispose_dialogs(s)
  Detail.dispose(s)
  views[s.buf], views[s.draft] = nil, nil
  for win, saved in pairs(window_states) do
    if saved.buf == s.buf or saved.buf == s.draft then
      restore_window(win)
    end
  end
  if s._view.group then
    pcall(api.nvim_del_augroup_by_id, s._view.group)
  end
  if valid_buf(s.draft) then
    pcall(api.nvim_buf_delete, s.draft, { force = true })
  end
end

return M
