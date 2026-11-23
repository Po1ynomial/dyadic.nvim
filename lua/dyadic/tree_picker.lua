-- The tree picker: a picker float (lua/dyadic/picker.lua) that shows the session tree
-- (stock `get_tree`) and moves the agent within it through the bridge. The rows follow
-- pi's own tree selector; folds are Neovim's manual folds.
local M = {}
local api = vim.api
local Tree = require("dyadic.tree")
local Bridge = require("dyadic.bridge")
local Picker = require("dyadic.picker")

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

local function keys_of(agent)
  local configured = (agent.config.tree or {}).keys or {}
  return vim.tbl_extend("force", M.default_keys, configured)
end

local function selected(p)
  local line = Picker.selected_line(p)
  local row = line and p.view.rows[line]
  return row and row.id, row and row.node
end

local function title(p)
  local parts = { "Tree", p.filter }
  if p.show_times then
    parts[#parts + 1] = "label times"
  end
  local line = Picker.selected_line(p)
  parts[#parts + 1] = (#p.view.rows > 0 and line or 0) .. "/" .. #p.view.rows
  return " " .. table.concat(parts, " · ") .. " "
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
  return hints
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

-- For tests: the chunks of the closed fold being drawn.
M.foldtext = Picker.foldtext

-- Rebuild the rows for the current filter and search, keeping the selection on `id` or
-- its nearest visible ancestor. Like pi, any change of filter or search opens all folds.
local function render(p, id)
  p.view = Tree.view(p.tree, p.filter, p.query)
  p.parts = {}
  local rows = {}
  for index, row in ipairs(p.view.rows) do
    local parts = row_parts(p, row)
    p.parts[index] = parts
    rows[index] = {
      chunks = chunks_of(parts, false),
      fold = parts.foldable and Tree.subtree_end(p.view, row.id) or nil,
    }
  end
  Picker.render(p, rows, #rows > 0 and Tree.nearest(p.tree, p.view, id) or nil, "No entries found")
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
    -- What the agent saw belongs to the branch it left.
    require("dyadic.change_notes").forget(agent)
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
    Picker.close(p)
    agent:notice("Already at this point")
    return
  end
  if agent.active then
    agent:notice("Wait for the agent to finish before moving in the tree", "warning")
    return
  end
  if not summary_prompt then
    Picker.close(p)
    M.navigate(agent, id, node, false)
    return
  end
  Picker.prompting(p, function(done)
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
              Picker.close(p)
              M.navigate(agent, id, node, true, input)
            end)
          else
            Picker.close(p)
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
  Picker.prompting(p, function(done)
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
  local line = Picker.selected_line(p)
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
  local line = Picker.selected_line(p)
  if not line or not p.view.rows[line] then
    return
  end
  if Picker.closed_at(p, line) then
    api.nvim_win_call(p.list_win, function()
      vim.cmd("normal! zo")
    end)
    return
  end
  local target = Tree.segment(p.view, line, "down", function(id)
    return Picker.closed_at(p, p.view.index[id])
  end)
  api.nvim_win_set_cursor(p.list_win, { target, 0 })
end

local function bind(p, keys)
  local function map(name, fn)
    Picker.map(p, keys, name, fn, "Dyadic tree")
  end
  map("navigate", function()
    go(p, true)
  end)
  map("navigate_without_summary", function()
    go(p, false)
  end)
  map("close", function()
    Picker.close(p)
  end)
  map("cancel", function()
    if p.query ~= "" then
      Picker.clear_query(p)
    else
      Picker.close(p)
    end
  end)
  map("search", function()
    Picker.focus_search(p)
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
end

-- Leave Insert mode before going, so dialogs and the next window start in Normal mode.
local function go_from_bar(summary_prompt)
  return function(p)
    vim.cmd("stopinsert")
    vim.schedule(function()
      if not p.closed then
        go(p, summary_prompt)
      end
    end)
  end
end

local function show(agent, data, initial)
  local keys = keys_of(agent)
  local bar_keys = { ["<CR>"] = go_from_bar(true) }
  if type(keys.navigate_without_summary) == "string" and keys.navigate_without_summary ~= "" then
    bar_keys[keys.navigate_without_summary] = go_from_bar(false)
  end
  local p = Picker.open({
    kind = "tree",
    agent = agent,
    tree = Tree.new(data.tree, data.leafId),
    filter = "default",
    show_times = false,
    parts = {},
    view = { rows = {} },
  }, {
    name = "dyadic://" .. agent.id .. "/tree",
    filetype = "dyadic_tree",
    title = title,
    footer = footer(keys),
    bar_keys = bar_keys,
    on_query = function(p)
      render(p, (selected(p)))
    end,
    foldtext = function(p, line)
      return p.parts[line] and chunks_of(p.parts[line], true)
    end,
  })
  bind(p, keys)
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

-- The open tree picker, for tests.
function M.current()
  local p = Picker.current()
  return p and p.kind == "tree" and p or nil
end

function M.close()
  local p = M.current()
  if p then
    Picker.close(p)
  end
end

return M
