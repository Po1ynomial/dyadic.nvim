local M = {}
local api = vim.api
local views = {}
local window_states = {}
local owned_options = {
  "wrap",
  "linebreak",
  "number",
  "relativenumber",
  "signcolumn",
  "foldmethod",
  "foldexpr",
  "foldtext",
  "foldenable",
  "foldlevel",
  "foldminlines",
  "statusline",
}
local folds_ns = api.nvim_create_namespace("dyadic_transcript")
local widgets_ns = api.nvim_create_namespace("dyadic_widgets")
local render_widgets
local text = require("dyadic.text")
local clean, lines_of, one_line = text.clean, text.lines_of, text.one_line
local describe, sorted_keys, content_text = text.describe, text.sorted_keys, text.content_text

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

local function window_options(win, draft)
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
  if not draft then
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require'dyadic.view'.foldexpr(v:lnum)"
    vim.wo[win].foldtext = "v:lua.require'dyadic.view'.foldtext()"
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 0
    vim.wo[win].foldminlines = 0
  end
end

function M.foldexpr(lnum)
  local s = views[api.nvim_get_current_buf()]
  local entry = s and s._view.folds[lnum]
  if not entry then
    return 0
  end
  if (entry.kind == "thinking" and s.show_thinking) or (entry.kind == "tool" and s.expand_tools) then
    return 0
  end
  return entry.level
end

function M.foldtext()
  return vim.fn.getline(vim.v.foldstart) .. " [" .. (vim.v.foldend - vim.v.foldstart) .. " lines; za to expand]"
end

local actions = {
  submit = { "Submit", "<CR>" },
  follow_up = { "FollowUp", "<M-CR>" },
  abort = { "Abort", "<Esc>" },
  dequeue = { "Dequeue", "<M-Up>" },
  model = { "Model", "<C-l>" },
  thinking = { "Thinking" },
  cycle_thinking = { "CycleThinking", "<S-Tab>" },
  cycle_model = { "CycleModel" },
  copy = { "Copy" },
  toggle_thinking = { "ToggleThinking", "<localleader>t" },
  toggle_tools = { "ToggleTools", "<localleader>o" },
  settings = { "Settings", "<localleader>s" },
  new = { "New" },
  resume = { "Resume" },
  focus_draft = { "FocusDraft", "<localleader>i" },
  focus_transcript = { "FocusTranscript", "<localleader>r" },
}

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

function M.bind(s)
  for action, spec in pairs(actions) do
    for _, buf in ipairs({ s.buf, s.draft }) do
      local allowed = (action ~= "submit" and action ~= "follow_up") or buf == s.draft
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
        if buf ~= s.draft and action ~= "focus_draft" and action ~= "toggle_thinking" and action ~= "toggle_tools" then
          key = nil
        end
        if type(key) == "string" and key ~= "" then
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
  vim.bo[buf].syntax = "markdown"
  vim.bo[buf].modifiable = editable
  if editable and s.config.completion ~= false then
    vim.bo[buf].omnifunc = "v:lua.require'dyadic.view'.complete"
  end
  return buf
end

function M.new(s)
  s._view = { folds = {}, dialogs = {}, seen_dialogs = {}, disposed = false }
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
        window_options(win, ev.buf == s.draft)
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
    window_options(transcript_win, false)
  end
  if not draft_win then
    api.nvim_set_current_win(transcript_win)
    vim.cmd("belowright split")
    draft_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(draft_win, s.draft)
    api.nvim_win_set_height(draft_win, math.max(1, s.config.draft_height or 6))
    window_options(draft_win, true)
  end
  api.nvim_set_current_win(draft_win)
  M.render(s)
end

function M.get_draft(s)
  if not valid_buf(s.draft) then
    return ""
  end
  return table.concat(api.nvim_buf_get_lines(s.draft, 0, -1, false), "\n")
end

function M.set_draft(s, text)
  if valid_buf(s.draft) then
    api.nvim_buf_set_lines(s.draft, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
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

local function footer(s)
  local state, stats = s.state or {}, s.stats or {}
  local model = state.model or {}
  local parts = { one_line(s.status or "Idle") }
  if model.id then
    parts[#parts + 1] = one_line((model.provider or "") .. "/" .. model.id)
  end
  if state.thinkingLevel then
    parts[#parts + 1] = "thinking " .. one_line(state.thinkingLevel)
  end
  local usage = stats.contextUsage
  if type(usage) == "table" then
    local tokens = type(usage.tokens) == "number" and tostring(usage.tokens) or "?"
    local percent = type(usage.percent) == "number" and string.format(" %.1f%%", usage.percent) or ""
    parts[#parts + 1] = "ctx " .. tokens .. "/" .. tostring(usage.contextWindow or "?") .. percent
  end
  if type(stats.tokens) == "table" then
    parts[#parts + 1] = "tokens " .. tostring(stats.tokens.total or 0)
  end
  if type(stats.cost) == "number" then
    parts[#parts + 1] = string.format("$%.4f", stats.cost)
  end
  for _, key in ipairs(sorted_keys(s.statuses)) do
    parts[#parts + 1] = one_line(s.statuses[key])
  end
  return table.concat(parts, " | ")
end

render_widgets = function(s)
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
    for _, text in ipairs(widget.lines or {}) do
      for _, line in ipairs(lines_of(text)) do
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

function M.render(s)
  if s.closed or not s._view or s._view.disposed or not valid_buf(s.buf) then
    return
  end
  local lines, folds, highlights = {}, {}, {}
  local function append(text)
    for _, line in ipairs(lines_of(text)) do
      lines[#lines + 1] = line
    end
  end
  local function heading(text, hl)
    append(text)
    highlights[#highlights + 1] = { #lines - 1, hl or "Title" }
  end
  local function detail(kind, label, text)
    local start = #lines + 1
    append(label)
    append(text)
    if #lines == start then
      append("")
    end
    for n = start, #lines do
      folds[n] = { kind = kind, level = n == start and ">1" or (n == #lines and "<1" or 1) }
    end
  end
  heading("# " .. one_line(s.title or (s.state or {}).sessionName or "Dyadic"))
  append(s.cwd)
  append("")
  local results, calls, rendered = {}, {}, {}
  local messages = {}
  for _, message in ipairs(s.messages or {}) do
    messages[#messages + 1] = message
  end
  if s.partial then
    messages[#messages + 1] = s.partial
  end
  for _, message in ipairs(messages) do
    if message.role == "toolResult" and message.toolCallId then
      results[message.toolCallId] = message
    end
    if message.role == "assistant" then
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "toolCall" and block.id then
          calls[block.id] = true
        end
      end
    end
  end
  local function tool(id, name, args)
    if id and rendered[id] then
      return
    end
    if id then
      rendered[id] = true
    end
    local live = (s.tools or {})[id] or {}
    local result = results[id] or live.result or live.partialResult
    local error_result = live.isError or (result and result.isError)
    local status = live.running and "running" or (error_result and "error" or (result and "done" or "pending"))
    local output = type(result) == "table" and content_text(result.content) or describe(result)
    local label = "Tool " .. one_line(name or live.toolName or "unknown") .. " [" .. status .. "]"
    if live.durationMs then
      label = label .. string.format(" %dms", live.durationMs)
    end
    if live.running and output ~= "" then
      label = label .. ": " .. one_line(output:match("([^\n]+)\n*$") or output)
    end
    local body = {}
    if args ~= nil or live.args ~= nil then
      body[#body + 1] = "Arguments:\n" .. describe(args or live.args)
    end
    if output ~= "" then
      body[#body + 1] = "Output:\n" .. output
    end
    if type(result) == "table" and result.details ~= nil and result.details ~= vim.NIL then
      body[#body + 1] = "Details:\n" .. describe(result.details)
    end
    if type(result) == "table" and result.nestedCalls then
      body[#body + 1] = "Nested calls:\n" .. describe(result.nestedCalls)
    end
    local row = #lines
    detail("tool", label, table.concat(body, "\n"))
    highlights[#highlights + 1] = { row, error_result and "DiagnosticError" or "Special" }
  end
  local function bash(message, live)
    heading("## Bash: " .. one_line(message.command), "Special")
    append(message.output or "")
    if message.exitCode ~= nil then
      append("Exit code: " .. tostring(message.exitCode))
    end
    if message.cancelled then
      append("[Cancelled]")
    end
    if message.truncated then
      append("[Truncated; full output: " .. clean(message.fullOutputPath or "unavailable") .. "]")
    end
    if message.excludeFromContext then
      append("[Excluded from model context]")
    end
    if live then
      append("[Running]")
    end
    append("")
  end
  for _, message in ipairs(messages) do
    local role = message.role
    if role == "assistant" then
      heading("## Assistant" .. (message == s.partial and " [streaming]" or ""))
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "text" then
          append(block.text)
        elseif block.type == "thinking" then
          detail("thinking", "Thinking", block.redacted and "[Redacted]" or (block.thinking or ""))
        elseif block.type == "toolCall" then
          tool(block.id, block.name, block.raw or block.arguments)
        elseif block.type == "image" then
          append("[Image: " .. one_line(block.mimeType) .. "]")
        end
      end
      if type(message.content) == "string" then
        append(message.content)
      end
      if message.errorMessage then
        heading("[Error] " .. clean(message.errorMessage), "DiagnosticError")
      end
      if message.stopReason == "aborted" then
        append("[Aborted]")
      end
      append("")
    elseif role == "toolResult" then
      if not calls[message.toolCallId] then
        tool(message.toolCallId, message.toolName)
        append("")
      end
    elseif role == "bashExecution" then
      bash(message)
    elseif role == "usage" then
      heading("[usage] " .. one_line(message.content), "Comment")
      append("")
    elseif role == "compactionSummary" or role == "branchSummary" then
      heading(role == "compactionSummary" and "## Compaction summary" or "## Branch summary")
      if message.tokensBefore then
        append("Tokens before compaction: " .. tostring(message.tokensBefore))
      end
      append(message.summary)
      append("")
    elseif role ~= "system" and (role ~= "custom" or message.display ~= false) then
      heading("## " .. one_line(role == "user" and "You" or (message.customType or role or "Message")))
      append(content_text(message.content))
      append("")
    end
  end
  for _, id in ipairs(sorted_keys(s.tools)) do
    if not rendered[id] then
      tool(id, s.tools[id].toolName, s.tools[id].args)
      append("")
    end
  end
  if s.bash and s.bash.running then
    bash(s.bash, true)
  end
  for _, kind in ipairs({ "steering", "followUp" }) do
    local queue = {}
    for _, text in ipairs((s.queue or {})[kind] or {}) do
      queue[#queue + 1] = text
    end
    for _, pending in ipairs(s.compaction_queue or {}) do
      if (pending.mode == "followUp" and kind == "followUp") or (pending.mode ~= "followUp" and kind == "steering") then
        queue[#queue + 1] = "[Waiting for compaction] " .. clean(pending.text)
      end
    end
    if #queue > 0 then
      heading("## Queued " .. (kind == "steering" and "steering" or "follow-up"))
      for index, text in ipairs(queue) do
        append(tostring(index) .. ". " .. clean(text))
      end
      append("")
    end
  end
  append("")
  local status = footer(s)
  local old_count = api.nvim_buf_line_count(s.buf)
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
    if valid_win(win) then
      api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        snapshots[#snapshots + 1] = { win = win, view = view, bottom = view.lnum >= old_count }
      end)
    end
  end
  s._view.folds = folds
  local fold_changed = s._view.show_thinking ~= s.show_thinking or s._view.expand_tools ~= s.expand_tools
  s._view.show_thinking, s._view.expand_tools = s.show_thinking, s.expand_tools
  local old_lines = api.nvim_buf_get_lines(s.buf, 0, -1, false)
  local first = 1
  while first <= #old_lines and first <= #lines and old_lines[first] == lines[first] do
    first = first + 1
  end
  if first <= #old_lines or first <= #lines then
    local last_old, last_new = #old_lines, #lines
    while last_old >= first and last_new >= first and old_lines[last_old] == lines[last_new] do
      last_old, last_new = last_old - 1, last_new - 1
    end
    vim.bo[s.buf].modifiable = true
    api.nvim_buf_set_lines(s.buf, first - 1, last_old, false, vim.list_slice(lines, first, last_new))
    vim.bo[s.buf].modifiable = false
    vim.bo[s.buf].modified = false
  end
  api.nvim_buf_clear_namespace(s.buf, folds_ns, 0, -1)
  for _, mark in ipairs(highlights) do
    api.nvim_buf_set_extmark(s.buf, folds_ns, mark[1], 0, { line_hl_group = mark[2] })
  end
  local title = one_line(s.title or (s.state or {}).sessionName or "Dyadic")
  for _, win in ipairs(vim.fn.win_findbuf(s.buf)) do
    if valid_win(win) then
      vim.wo[win].statusline = (" " .. title .. " | " .. one_line((s.state or {}).sessionId or "starting")):gsub(
        "%%",
        "%%%%"
      )
    end
  end
  if valid_buf(s.draft) then
    render_widgets(s)
    for _, win in ipairs(vim.fn.win_findbuf(s.draft)) do
      if valid_win(win) then
        vim.wo[win].statusline = (" Draft | " .. status):gsub("%%", "%%%%")
      end
    end
  end
  for _, snapshot in ipairs(snapshots) do
    if valid_win(snapshot.win) then
      api.nvim_win_call(snapshot.win, function()
        if fold_changed then
          vim.cmd("normal! zx")
        end
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

function M.dispose(s)
  if not s._view or s._view.disposed then
    return
  end
  s._view.disposed = true
  require("dyadic.extension_ui").dispose_dialogs(s)
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
