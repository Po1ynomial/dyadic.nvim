-- The tree picker: a float that shows the session tree (stock `get_tree`) and moves the
-- agent within it through the bridge. The rows follow pi's own tree selector; folds are
-- Neovim's manual folds, and the search bar is a one-line float above the list.
local M = {}
local api = vim.api
local Tree = require("dyadic.tree")
local Bridge = require("dyadic.bridge")

M.default_keys = {
  navigate = "<CR>",
  navigate_without_summary = "<C-CR>",
  cancel = "<Esc>",
  close = "q",
  search = "/",
  fold_or_up = "h",
  unfold_or_down = "l",
  filter_default = "d",
  filter_no_tools = "t",
  filter_user_only = "u",
  filter_labeled_only = "'",
  filter_all = "a",
  filter_next = "<Tab>",
  filter_prev = "<S-Tab>",
  label = "m",
  label_time = "T",
  copy = "yy",
}

local ns = api.nvim_create_namespace("dyadic_tree")
local bar_ns = api.nvim_create_namespace("dyadic_tree_bar")
local current -- the open picker, if any

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

local function keys_of(agent)
  local configured = (agent.config.tree or {}).keys or {}
  return vim.tbl_extend("force", M.default_keys, configured)
end

-- Outer size about 90% of the editor, like the detail float: a search bar on top of the list.
local function geometry()
  local columns, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(10, math.floor(columns * 0.9) - 2)
  local height = math.max(6, math.floor(lines * 0.9) - 2)
  local row = math.floor((lines - height - 2) / 2)
  local col = math.floor((columns - width - 2) / 2)
  return {
    bar = { relative = "editor", width = width, height = 1, row = row, col = col },
    list = { relative = "editor", width = width, height = math.max(1, height - 3), row = row + 3, col = col },
  }
end

local function selected_line(p)
  if not valid_win(p.list_win) then
    return nil
  end
  local line = api.nvim_win_get_cursor(p.list_win)[1]
  local start = api.nvim_win_call(p.list_win, function()
    return vim.fn.foldclosed(line)
  end)
  return start ~= -1 and start or line
end

local function selected(p)
  local line = selected_line(p)
  local row = line and p.view.rows[line]
  return row and row.id, row and row.node
end

local function title(p)
  local parts = { "Tree", p.filter }
  if p.show_times then
    parts[#parts + 1] = "label times"
  end
  local line = selected_line(p)
  parts[#parts + 1] = (#p.view.rows > 0 and line or 0) .. "/" .. #p.view.rows
  return " " .. table.concat(parts, " · ") .. " "
end

local function update_title(p)
  if valid_win(p.list_win) then
    api.nvim_win_set_config(p.list_win, { title = title(p), title_pos = "left" })
  end
end

local function footer(keys)
  local hints = {}
  local function add(key, label)
    if type(key) == "string" and key ~= "" then
      hints[#hints + 1] = key .. " " .. label
    end
  end
  add(keys.navigate, "go")
  add(keys.navigate_without_summary, "go, no summary")
  add(keys.search, "search")
  local filters = {}
  for _, name in ipairs({ "filter_default", "filter_no_tools", "filter_user_only", "filter_labeled_only", "filter_all" }) do
    if type(keys[name]) == "string" and keys[name] ~= "" then
      filters[#filters + 1] = keys[name]
    end
  end
  if #filters > 0 then
    hints[#hints + 1] = table.concat(filters, " ") .. " filter"
  end
  add(keys.label, "label")
  add(keys.copy, "copy")
  add(keys.close, "close")
  return " " .. table.concat(hints, " · ") .. " "
end

-- Row chunks without the fold marker state; foldtext swaps in the closed marker.
local function row_parts(p, row)
  local foldable = Tree.foldable(p.view, row.id)
  local prefix, connector = Tree.prefix(p.view, row, foldable and "⊟" or nil)
  local rest = {}
  if p.tree.active[row.id] then
    rest[#rest + 1] = { "• ", "DyadicTreeActive" }
  end
  local label = row.node.label
  if type(label) == "string" then
    rest[#rest + 1] = { "[" .. label .. "] ", "DyadicTreeLabel" }
    local time = p.show_times and Tree.label_time(row.node.labelTimestamp)
    if time then
      rest[#rest + 1] = { time .. " ", "DyadicMeta" }
    end
  end
  vim.list_extend(rest, Tree.chunks(p.tree, row.node))
  return { prefix = prefix, connector = connector, foldable = foldable, rest = rest }
end

local function chunks_of(parts, closed)
  local chunks = {}
  local prefix = parts.prefix
  if closed and parts.connector then
    prefix = prefix:gsub("⊟", "⊞")
  end
  chunks[1] = { prefix, "DyadicTreeLine" }
  if closed and not parts.connector then
    chunks[#chunks + 1] = { "⊞ ", "DyadicTreeActive" }
  end
  vim.list_extend(chunks, parts.rest)
  return chunks
end

-- Closed folds show their first row with a closed marker.
function M.foldtext()
  local p = current
  local parts = p and p.parts[vim.v.foldstart]
  if not parts then
    return vim.fn.foldtext()
  end
  local chunks = {}
  for _, chunk in ipairs(chunks_of(parts, true)) do
    chunks[#chunks + 1] = { chunk[1], chunk[2] or "Normal" }
  end
  return chunks
end

-- Rebuild the rows for the current filter and search, keeping the selection on `id` or
-- its nearest visible ancestor. Like pi, any change of filter or search opens all folds.
local function render(p, id)
  p.view = Tree.view(p.tree, p.filter, p.query)
  p.parts = {}
  local lines, spans = {}, {}
  for index, row in ipairs(p.view.rows) do
    local parts = row_parts(p, row)
    p.parts[index] = parts
    local line, col = {}, 0
    for _, chunk in ipairs(chunks_of(parts, false)) do
      line[#line + 1] = chunk[1]
      if chunk[2] then
        spans[#spans + 1] = { index - 1, col, col + #chunk[1], chunk[2] }
      end
      col = col + #chunk[1]
    end
    lines[index] = table.concat(line)
  end
  if #lines == 0 then
    lines = { "" }
  end
  vim.bo[p.list_buf].modifiable = true
  api.nvim_buf_set_lines(p.list_buf, 0, -1, false, lines)
  vim.bo[p.list_buf].modifiable = false
  api.nvim_buf_clear_namespace(p.list_buf, ns, 0, -1)
  if #p.view.rows == 0 then
    api.nvim_buf_set_extmark(p.list_buf, ns, 0, 0, { virt_text = { { "No entries found", "DyadicMeta" } } })
  end
  for _, span in ipairs(spans) do
    api.nvim_buf_set_extmark(p.list_buf, ns, span[1], span[2], { end_col = span[3], hl_group = span[4] })
  end
  api.nvim_win_call(p.list_win, function()
    vim.cmd("silent! normal! zE")
    -- New folds start closed, and a range inside a closed fold grows to the whole fold, so
    -- create inner folds first: from the last row up, each new fold only encloses others.
    for index = #p.view.rows, 1, -1 do
      local row = p.view.rows[index]
      if p.parts[index].foldable then
        local last = Tree.subtree_end(p.view, row.id)
        if last and last > index then
          vim.cmd(string.format("silent! %d,%dfold", index, last))
        end
      end
    end
    vim.cmd("silent! normal! zR")
  end)
  if #p.view.rows > 0 then
    api.nvim_win_set_cursor(p.list_win, { Tree.nearest(p.tree, p.view, id), 0 })
  end
  update_title(p)
end

-- `keep_focus` leaves the cursor where the user moved it instead of returning to the
-- window the picker was opened from.
local function close(p, keep_focus)
  if p.closed then
    return
  end
  p.closed = true
  if current == p then
    current = nil
  end
  pcall(api.nvim_del_augroup_by_id, p.group)
  for _, win in ipairs({ p.bar_win, p.list_win }) do
    if valid_win(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ p.bar_buf, p.list_buf }) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  if not keep_focus and valid_win(p.previous_win) then
    pcall(api.nvim_set_current_win, p.previous_win)
  end
end

local function focus_list(p)
  if not p.closed and valid_win(p.list_win) then
    vim.cmd("stopinsert")
    api.nvim_set_current_win(p.list_win)
  end
end

local function set_query(p, query)
  if p.query == query then
    return
  end
  local id = selected(p)
  p.query = query
  render(p, id)
end

local function placeholder(p)
  api.nvim_buf_clear_namespace(p.bar_buf, bar_ns, 0, -1)
  if p.query == "" then
    api.nvim_buf_set_extmark(p.bar_buf, bar_ns, 0, 0, {
      virt_text = { { "/ search", "DyadicMeta" } },
      virt_text_pos = "overlay",
    })
  end
end

-- Ask something through vim.ui without the picker closing when a UI plugin's float takes
-- focus. `done` runs after the answer, with the picker focused again when still open.
local function prompting(p, fn)
  p.prompting = true
  fn(function()
    p.prompting = false
    focus_list(p)
  end)
end

local function draft_append(agent, value)
  if type(value) ~= "string" or value == "" then
    return
  end
  local draft = agent:get_draft()
  agent:set_draft(draft == "" and value or draft .. "\n\n" .. value)
end

-- Move the agent to entry `id`. `node` gives the text pi puts back in the editor.
function M.navigate(agent, id, node, summarize, instructions)
  if summarize then
    agent.active, agent.phase = true, "Summarizing branch"
    agent:render()
  end
  local args = { id = id, summarize = summarize == true, instructions = instructions }
  Bridge.run(agent, "tree", args, "/tree", function(err, outcome)
    if agent.closed then
      return
    end
    outcome = outcome or {}
    if err or outcome.error or outcome.cancelled then
      if outcome.error then
        agent:notice(outcome.error, "error")
      elseif outcome.cancelled then
        agent:notice(summarize and "Branch summarization cancelled" or "Navigation cancelled")
      end
      agent:refresh(function()
        -- As in pi, a cancelled summary returns to the tree at the same entry.
        if outcome.cancelled and summarize then
          M.open(agent, { initial = id })
        end
      end)
      return
    end
    agent.history_version = agent.history_version + 1
    agent.partial, agent.tools, agent.bash = nil, {}, nil
    draft_append(agent, Tree.editor_text(node))
    agent:refresh()
  end)
end

local function go(p, summary_prompt)
  local id, node = selected(p)
  if not id then
    return
  end
  local agent = p.agent
  if id == p.tree.leaf then
    close(p)
    agent:notice("Already at this point")
    return
  end
  if agent.active then
    agent:notice("Wait for the agent to finish before moving in the tree", "warning")
    return
  end
  if not summary_prompt then
    close(p)
    M.navigate(agent, id, node, false)
    return
  end
  prompting(p, function(done)
    local function ask()
      vim.ui.select(
        { "No summary", "Summarize", "Summarize with instructions" },
        { prompt = "Summarize the branch you leave?" },
        function(choice)
          if choice == nil then
            done()
          elseif choice == "Summarize with instructions" then
            vim.ui.input({ prompt = "Summary instructions: " }, function(input)
              if input == nil then
                -- Back to the summary question, as in pi.
                vim.schedule(ask)
                return
              end
              close(p)
              M.navigate(agent, id, node, true, input)
            end)
          else
            close(p)
            M.navigate(agent, id, node, choice == "Summarize")
          end
        end
      )
    end
    ask()
  end)
end

local function reload(p, id)
  p.agent:request("get_tree", {}, function(err, data)
    if err or p.closed then
      return
    end
    p.tree = Tree.new(data.tree, data.leafId)
    render(p, id)
  end)
end

local function edit_label(p)
  local id, node = selected(p)
  if not id or not node then
    return
  end
  prompting(p, function(done)
    vim.ui.input(
      { prompt = "Label (empty to remove): ", default = type(node.label) == "string" and node.label or "" },
      function(input)
        done()
        if input == nil then
          return
        end
        Bridge.run(p.agent, "label", { id = id, label = input }, "Labels", function(err, outcome)
          if outcome and outcome.error then
            p.agent:notice(outcome.error, "error")
          end
          if not err then
            reload(p, id)
          end
        end)
      end
    )
  end)
end

local function copy(p)
  local _, node = selected(p)
  local value = node and Tree.copy_text(node)
  if not value then
    p.agent:notice("The selected entry has no text to copy", "warning")
    return
  end
  local register = vim.v.register
  vim.fn.setreg(register, value)
  p.agent:notice("Copied the entry text to register " .. register)
end

local function set_filter(p, filter)
  local id = selected(p)
  p.filter = filter
  render(p, id)
end

-- pi's filter keys toggle: the active filter's key returns to the default view.
local function toggle_filter(p, filter)
  set_filter(p, p.filter == filter and "default" or filter)
end

local function cycle_filter(p, delta)
  local index = 1
  for i, name in ipairs(Tree.filters) do
    if name == p.filter then
      index = i
    end
  end
  set_filter(p, Tree.filters[(index - 1 + delta) % #Tree.filters + 1])
end

local function fold_or_up(p)
  local line = selected_line(p)
  if not line or not p.view.rows[line] then
    return
  end
  local closed = api.nvim_win_call(p.list_win, function()
    return vim.fn.foldclosed(line) ~= -1
  end)
  if p.parts[line].foldable and not closed then
    api.nvim_win_set_cursor(p.list_win, { line, 0 })
    api.nvim_win_call(p.list_win, function()
      vim.cmd("normal! zc")
    end)
  else
    api.nvim_win_set_cursor(p.list_win, { Tree.segment(p.view, line, "up"), 0 })
  end
end

local function unfold_or_down(p)
  local line = selected_line(p)
  if not line or not p.view.rows[line] then
    return
  end
  local function closed_at(l)
    return api.nvim_win_call(p.list_win, function()
      return vim.fn.foldclosed(l) == l
    end)
  end
  if closed_at(line) then
    api.nvim_win_call(p.list_win, function()
      vim.cmd("normal! zo")
    end)
    return
  end
  local target = Tree.segment(p.view, line, "down", function(id)
    return closed_at(p.view.index[id])
  end)
  api.nvim_win_set_cursor(p.list_win, { target, 0 })
end

local function bind(p)
  local keys = keys_of(p.agent)
  local function map(name, fn)
    local lhs = keys[name]
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = p.list_buf, nowait = true, silent = true, desc = "Dyadic tree " .. name })
    end
  end
  map("navigate", function()
    go(p, true)
  end)
  map("navigate_without_summary", function()
    go(p, false)
  end)
  map("close", function()
    close(p)
  end)
  map("cancel", function()
    if p.query ~= "" then
      api.nvim_buf_set_lines(p.bar_buf, 0, -1, false, { "" })
      set_query(p, "")
      placeholder(p)
    else
      close(p)
    end
  end)
  map("search", function()
    api.nvim_set_current_win(p.bar_win)
    api.nvim_win_set_cursor(p.bar_win, { 1, #p.query })
    vim.cmd("startinsert!")
  end)
  map("fold_or_up", function()
    fold_or_up(p)
  end)
  map("unfold_or_down", function()
    unfold_or_down(p)
  end)
  for name, filter in pairs({
    filter_no_tools = "no-tools",
    filter_user_only = "user-only",
    filter_labeled_only = "labeled-only",
    filter_all = "all",
  }) do
    map(name, function()
      toggle_filter(p, filter)
    end)
  end
  map("filter_default", function()
    set_filter(p, "default")
  end)
  map("filter_next", function()
    cycle_filter(p, 1)
  end)
  map("filter_prev", function()
    cycle_filter(p, -1)
  end)
  map("label", function()
    edit_label(p)
  end)
  map("label_time", function()
    p.show_times = not p.show_times
    render(p, (selected(p)))
  end)
  map("copy", function()
    copy(p)
  end)

  -- The search bar: typing filters at once; the list's selection moves from here too.
  local function bar(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = p.bar_buf, silent = true, desc = "Dyadic tree search" })
  end
  local function move(delta)
    return function()
      local count = #p.view.rows
      if count == 0 then
        return
      end
      local line = selected_line(p) or 1
      local target = math.max(1, math.min(count, line + delta))
      -- Step over closed folds like j and k do.
      api.nvim_win_call(p.list_win, function()
        api.nvim_win_set_cursor(0, { line, 0 })
        vim.cmd("normal! " .. (delta > 0 and "j" or "k"))
        target = vim.fn.line(".")
      end)
      api.nvim_win_set_cursor(p.list_win, { target, 0 })
      update_title(p)
    end
  end
  -- Leave Insert mode before going, so dialogs and the next window start in Normal mode.
  local function go_from_bar(summary_prompt)
    return function()
      vim.cmd("stopinsert")
      vim.schedule(function()
        if not p.closed then
          go(p, summary_prompt)
        end
      end)
    end
  end
  bar("<CR>", go_from_bar(true))
  if type(keys.navigate_without_summary) == "string" and keys.navigate_without_summary ~= "" then
    bar(keys.navigate_without_summary, go_from_bar(false))
  end
  bar("<Esc>", function()
    focus_list(p)
  end)
  bar("<C-n>", move(1))
  bar("<Down>", move(1))
  bar("<C-p>", move(-1))
  bar("<Up>", move(-1))
  vim.keymap.set("n", "<Esc>", function()
    focus_list(p)
  end, { buffer = p.bar_buf, silent = true })
  vim.keymap.set("n", "q", function()
    close(p)
  end, { buffer = p.bar_buf, silent = true })
end

local function scratch(name)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  pcall(api.nvim_buf_set_name, buf, name)
  return buf
end

local function show(agent, data, initial)
  if current then
    close(current)
  end
  local p = {
    agent = agent,
    tree = Tree.new(data.tree, data.leafId),
    filter = "default",
    query = "",
    show_times = false,
    previous_win = api.nvim_get_current_win(),
    parts = {},
  }
  current = p
  local layout = geometry()
  p.bar_buf = scratch("dyadic://" .. agent.id .. "/tree/search")
  p.list_buf = scratch("dyadic://" .. agent.id .. "/tree")
  vim.bo[p.list_buf].filetype = "dyadic_tree"
  vim.bo[p.list_buf].modifiable = false
  p.bar_win = api.nvim_open_win(
    p.bar_buf,
    false,
    vim.tbl_extend("force", layout.bar, { border = "rounded", style = "minimal", focusable = true })
  )
  p.list_win = api.nvim_open_win(
    p.list_buf,
    true,
    vim.tbl_extend("force", layout.list, {
      border = "rounded",
      style = "minimal",
      title = " Tree ",
      title_pos = "left",
      footer = footer(keys_of(agent)),
      footer_pos = "left",
    })
  )
  for option, value in pairs({
    wrap = false,
    cursorline = true,
    foldenable = true,
    foldmethod = "manual",
    foldminlines = 0,
    foldcolumn = "0",
    foldtext = "v:lua.require'dyadic.tree_picker'.foldtext()",
    fillchars = "fold: ,eob: ",
  }) do
    vim.wo[p.list_win][option] = value
  end
  vim.wo[p.bar_win].wrap = false
  local Pin = require("dyadic.pin")
  local function lost()
    close(p, true)
  end
  Pin.pin(p.list_win, p.list_buf, { lost = lost })
  Pin.pin(p.bar_win, p.bar_buf, { lost = lost })
  placeholder(p)
  bind(p)
  p.group = api.nvim_create_augroup("DyadicTree", { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = p.group,
    buffer = p.list_buf,
    callback = function()
      update_title(p)
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = p.group,
    buffer = p.bar_buf,
    callback = function()
      local line = api.nvim_buf_get_lines(p.bar_buf, 0, 1, false)[1] or ""
      set_query(p, line)
      placeholder(p)
    end,
  })
  -- The picker closes when focus leaves it, except to a dialog it opened itself.
  api.nvim_create_autocmd("WinEnter", {
    group = p.group,
    callback = function()
      vim.schedule(function()
        local win = api.nvim_get_current_win()
        if not p.closed and not p.prompting and win ~= p.list_win and win ~= p.bar_win then
          close(p, true)
        end
      end)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = p.group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win == p.list_win or win == p.bar_win then
        vim.schedule(function()
          close(p)
        end)
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = p.group,
    callback = function()
      local resized = geometry()
      if valid_win(p.bar_win) and valid_win(p.list_win) then
        api.nvim_win_set_config(p.bar_win, resized.bar)
        api.nvim_win_set_config(p.list_win, resized.list)
      end
    end,
  })
  render(p, initial or p.tree.leaf)
  return p
end

-- Open the picker for `agent`; `opts.initial` is the entry to select, else the current one.
-- Returns false when the picker cannot open now.
function M.open(agent, opts)
  opts = opts or {}
  if not Bridge.available(agent) then
    agent:notice("/tree needs the bridge, which is not loaded. See :help dyadic-bridge", "error")
    return false
  end
  if agent.active then
    agent:notice("Wait for the agent to finish before opening the tree", "warning")
    return false
  end
  agent:request("get_tree", {}, function(err, data)
    if err or agent.closed then
      return
    end
    if type(data) ~= "table" or type(data.tree) ~= "table" or #data.tree == 0 then
      agent:notice("No entries in this session", "warning")
      return
    end
    show(agent, data, opts.initial)
  end)
  return true
end

-- The open picker, for tests.
function M.current()
  return current
end

function M.close()
  if current then
    close(current)
  end
end

return M
