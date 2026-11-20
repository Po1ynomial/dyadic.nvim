-- The tree picker's model: pi's session tree (from `get_tree`) as rows, with pi's filters,
-- search, connectors, and branch-segment navigation. It follows pi's own tree selector so
-- both show the same rows; only the row text uses dyadic's history vocabulary.
local M = {}
local clean = require("dyadic.text").clean

M.filters = { "default", "no-tools", "user-only", "labeled-only", "all" }

-- Display text and search text use at most this many characters of an entry's content.
local CONTENT_CHARS = 200

local function value(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

local function parent_of(entry)
  return value(entry.parentId)
end

-- Text blocks only, like pi; `limit` cuts the result to that many characters.
local function content_text(content, limit)
  local result
  if type(content) == "string" then
    result = content
  else
    local parts = {}
    for _, block in ipairs(type(content) == "table" and content or {}) do
      if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      end
    end
    result = table.concat(parts)
  end
  if limit and vim.fn.strchars(result) > limit then
    result = vim.fn.strcharpart(result, 0, limit)
  end
  return result
end
M.content_text = content_text

local function has_text(content)
  return content_text(content):find("%S") ~= nil
end

local function normalize(s)
  return vim.trim((clean(s):gsub("[\n\t]", " ")))
end

-- Build the full model from `get_tree` data. Children that lead to the current leaf come
-- first, as in pi.
function M.new(roots, leaf_id)
  local state = {
    roots = type(roots) == "table" and roots or {},
    leaf = value(leaf_id),
    nodes = {}, -- id -> node
    active = {}, -- ids on the active branch
    tool_calls = {}, -- tool call id -> { name, arguments }
    flat = {}, -- every node in display order
  }
  local contains = {}
  local function mark(node)
    local entry = node.entry or {}
    local has = state.leaf ~= nil and entry.id == state.leaf
    state.nodes[entry.id] = node
    for _, child in ipairs(node.children or {}) do
      if mark(child) then
        has = true
      end
    end
    contains[node] = has
    return has
  end
  for _, root in ipairs(state.roots) do
    mark(root)
  end
  local current = state.leaf
  while current and state.nodes[current] do
    state.active[current] = true
    current = parent_of(state.nodes[current].entry)
  end
  local function ordered(nodes)
    local first, rest = {}, {}
    for _, node in ipairs(nodes or {}) do
      table.insert(contains[node] and first or rest, node)
    end
    vim.list_extend(first, rest)
    return first
  end
  local stack = {}
  local roots_in_order = ordered(state.roots)
  for index = #roots_in_order, 1, -1 do
    stack[#stack + 1] = roots_in_order[index]
  end
  while #stack > 0 do
    local node = table.remove(stack)
    local entry = node.entry or {}
    if entry.type == "message" and type(entry.message) == "table" and entry.message.role == "assistant" then
      for _, block in ipairs(type(entry.message.content) == "table" and entry.message.content or {}) do
        if type(block) == "table" and block.type == "toolCall" and block.id then
          state.tool_calls[block.id] = { name = block.name, arguments = block.arguments }
        end
      end
    end
    state.flat[#state.flat + 1] = node
    local children = ordered(node.children)
    for index = #children, 1, -1 do
      stack[#stack + 1] = children[index]
    end
  end
  return state
end

local settings_types = {
  label = true,
  context_edit = true,
  custom = true,
  model_change = true,
  thinking_level_change = true,
  session_info = true,
}

local function searchable(node)
  local entry = node.entry or {}
  local parts = {}
  if value(node.label) then
    parts[#parts + 1] = node.label
  end
  local kind = entry.type
  if kind == "message" then
    local message = entry.message or {}
    parts[#parts + 1] = message.role
    parts[#parts + 1] = content_text(message.content, CONTENT_CHARS)
    if message.role == "bashExecution" then
      parts[#parts + 1] = message.command
    end
  elseif kind == "custom_message" then
    parts[#parts + 1] = entry.customType
    parts[#parts + 1] = content_text(entry.content, CONTENT_CHARS)
  elseif kind == "compaction" then
    parts[#parts + 1] = "compaction"
  elseif kind == "branch_summary" then
    parts[#parts + 1] = "branch summary"
    parts[#parts + 1] = entry.summary
  elseif kind == "session_info" then
    parts[#parts + 1] = "title"
    parts[#parts + 1] = value(entry.name)
  elseif kind == "model_change" then
    parts[#parts + 1] = "model " .. tostring(entry.modelId)
  elseif kind == "thinking_level_change" then
    parts[#parts + 1] = "thinking " .. tostring(entry.thinkingLevel)
  elseif kind == "custom" then
    parts[#parts + 1] = "custom " .. tostring(entry.customType)
  elseif kind == "context_edit" then
    parts[#parts + 1] = "context edit " .. (value(entry.replacement) == nil and "omit" or "replace")
  elseif kind == "label" then
    parts[#parts + 1] = "label " .. tostring(value(entry.label) or "")
  end
  local strings = {}
  for _, part in pairs(parts) do
    if type(part) == "string" then
      strings[#strings + 1] = part
    end
  end
  return table.concat(strings, " "):lower()
end

local function passes(state, node, filter, tokens)
  local entry = node.entry or {}
  if entry.type == "usage" then
    return false
  end
  -- Assistant messages without text hide unless they failed or are the current leaf.
  if entry.type == "message" and type(entry.message) == "table" and entry.message.role == "assistant" then
    local message = entry.message
    local stop = value(message.stopReason)
    local failed = stop ~= nil and stop ~= "stop" and stop ~= "toolUse"
    if entry.id ~= state.leaf and not has_text(message.content) and not failed then
      return false
    end
  end
  local settings = settings_types[entry.type] == true
  local role = entry.type == "message" and type(entry.message) == "table" and entry.message.role or nil
  local ok
  if filter == "user-only" then
    ok = role == "user"
  elseif filter == "no-tools" then
    ok = not settings and role ~= "toolResult"
  elseif filter == "labeled-only" then
    ok = value(node.label) ~= nil
  elseif filter == "all" then
    ok = true
  else
    ok = not settings
  end
  if not ok then
    return false
  end
  if #tokens > 0 then
    local haystack = searchable(node)
    for _, token in ipairs(tokens) do
      if not haystack:find(token, 1, true) then
        return false
      end
    end
  end
  return true
end

-- The visible rows for a filter and search query, with pi's connector layout: each row
-- hangs under its nearest visible ancestor.
-- Returns { rows, index (id -> row number), parent (id -> visible parent id),
-- children (id or "" -> visible child ids), multiple_roots }.
function M.view(state, filter, query)
  local tokens = {}
  for token in (query or ""):lower():gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  local visible, visible_ids = {}, {}
  for _, node in ipairs(state.flat) do
    if passes(state, node, filter or "default", tokens) then
      visible[#visible + 1] = node
      visible_ids[node.entry.id] = true
    end
  end
  local parent, children = {}, { [""] = {} }
  for _, node in ipairs(visible) do
    local id = node.entry.id
    local ancestor = parent_of(node.entry)
    while ancestor ~= nil and not visible_ids[ancestor] do
      local ancestor_node = state.nodes[ancestor]
      ancestor = ancestor_node and parent_of(ancestor_node.entry) or nil
    end
    parent[id] = ancestor
    local key = ancestor or ""
    children[key] = children[key] or {}
    table.insert(children[key], id)
  end
  local view = {
    rows = {},
    index = {},
    parent = parent,
    children = children,
    multiple_roots = #children[""] > 1,
  }
  local by_id = {}
  for _, node in ipairs(visible) do
    by_id[node.entry.id] = node
  end
  local multiple = view.multiple_roots
  local stack = {}
  local roots = children[""]
  for index = #roots, 1, -1 do
    stack[#stack + 1] = {
      id = roots[index],
      indent = multiple and 1 or 0,
      just_branched = multiple,
      connector = multiple,
      last = index == #roots,
      gutters = {},
      virtual_root_child = multiple,
    }
  end
  while #stack > 0 do
    local item = table.remove(stack)
    local row = {
      node = by_id[item.id],
      id = item.id,
      indent = item.indent,
      connector = item.connector,
      last = item.last,
      gutters = item.gutters,
      virtual_root_child = item.virtual_root_child,
    }
    view.rows[#view.rows + 1] = row
    view.index[item.id] = #view.rows
    local kids = children[item.id] or {}
    local branching = #kids > 1
    local child_indent = item.indent
    if branching or (item.just_branched and item.indent > 0) then
      child_indent = item.indent + 1
    end
    local child_gutters = item.gutters
    if item.connector and not item.virtual_root_child then
      local display = multiple and math.max(0, item.indent - 1) or item.indent
      child_gutters =
        vim.list_extend(vim.deepcopy(item.gutters), { { position = math.max(0, display - 1), show = not item.last } })
    end
    for index = #kids, 1, -1 do
      stack[#stack + 1] = {
        id = kids[index],
        indent = child_indent,
        just_branched = branching,
        connector = branching,
        last = index == #kids,
        gutters = child_gutters,
        virtual_root_child = false,
      }
    end
  end
  return view
end

-- Whether a row can fold: it has visible children and is a root or the first entry of a
-- branch segment.
function M.foldable(view, id)
  local kids = view.children[id]
  if not kids or #kids == 0 then
    return false
  end
  local parent = view.parent[id]
  if parent == nil then
    return true
  end
  return #(view.children[parent] or {}) > 1
end

-- Row number of the last visible descendant of `id`.
function M.subtree_end(view, id)
  local current = id
  while true do
    local kids = view.children[current]
    if not kids or #kids == 0 then
      return view.index[current]
    end
    current = kids[#kids]
  end
end

-- Row of `id`, or of its nearest visible ancestor, or the last row.
function M.nearest(state, view, id)
  local current = id
  while current ~= nil do
    if view.index[current] then
      return view.index[current]
    end
    local node = state.nodes[current]
    current = node and parent_of(node.entry) or nil
  end
  return math.max(1, #view.rows)
end

-- Next branch-segment start from row `index`, as pi's fold-or-up and unfold-or-down move.
-- `closed(id)` tells whether a row's descendants are hidden; walking down stops there.
function M.segment(view, index, direction, closed)
  local row = view.rows[index]
  if not row then
    return index
  end
  local current = row.id
  if direction == "down" then
    while true do
      local kids = view.children[current] or {}
      if #kids == 0 or (closed and closed(current)) then
        return view.index[current] or index
      end
      if #kids > 1 then
        return view.index[kids[1]] or index
      end
      current = kids[1]
    end
  end
  while true do
    local parent = view.parent[current]
    if parent == nil then
      return view.index[current] or index
    end
    if #(view.children[parent] or {}) > 1 then
      local start = view.index[current]
      if start and start < index then
        return start
      end
    end
    current = parent
  end
end

-- Connector prefix for a row, three cells per level. `marker` replaces the horizontal bar
-- of the row's own connector, for fold markers.
function M.prefix(view, row, marker)
  local display = view.multiple_roots and math.max(0, row.indent - 1) or row.indent
  local connector = row.connector and not row.virtual_root_child
  local position = connector and display - 1 or -1
  local cells = {}
  for i = 0, display * 3 - 1 do
    local level, cell = math.floor(i / 3), i % 3
    local gutter
    for _, g in ipairs(row.gutters) do
      if g.position == level then
        gutter = g
        break
      end
    end
    if gutter then
      cells[#cells + 1] = cell == 0 and (gutter.show and "│" or " ") or " "
    elseif connector and level == position then
      if cell == 0 then
        cells[#cells + 1] = row.last and "└" or "├"
      elseif cell == 1 then
        cells[#cells + 1] = marker or "─"
      else
        cells[#cells + 1] = " "
      end
    else
      cells[#cells + 1] = " "
    end
  end
  return table.concat(cells), connector
end

local function shorten(path)
  path = tostring(path or "")
  local home = vim.uv.os_homedir()
  if home and path:sub(1, #home + 1) == home .. "/" then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

local function clip(s, limit)
  if vim.fn.strchars(s) > limit then
    return vim.fn.strcharpart(s, 0, limit) .. "…"
  end
  return s
end

-- One-line summary of a tool call, as pi's tree shows it.
function M.tool_summary(name, args)
  args = type(args) == "table" and args or {}
  local path = shorten(value(args.path) or value(args.file_path) or "")
  if name == "read" then
    local range = ""
    local offset, limit = tonumber(value(args.offset)), tonumber(value(args.limit))
    if offset or limit then
      local start = offset or 1
      range = ":" .. start .. (limit and ("-" .. (start + limit - 1)) or "")
    end
    return "read " .. path .. range
  elseif name == "write" or name == "edit" then
    return name .. " " .. path
  elseif name == "bash" then
    return "bash " .. clip(normalize(value(args.command)), 50)
  elseif name == "grep" then
    return "grep /" .. tostring(value(args.pattern) or "") .. "/ in " .. shorten(value(args.path) or ".")
  elseif name == "find" then
    return "find " .. tostring(value(args.pattern) or "") .. " in " .. shorten(value(args.path) or ".")
  elseif name == "ls" then
    return "ls " .. shorten(value(args.path) or ".")
  end
  local ok, encoded = pcall(vim.json.encode, args)
  return tostring(name or "tool") .. " " .. clip(ok and encoded or "{}", 40)
end

-- Row content as highlighted chunks, in the history's vocabulary.
function M.chunks(state, node)
  local entry = node.entry or {}
  local kind = entry.type
  if kind == "message" then
    local message = entry.message or {}
    local role = message.role
    if role == "user" then
      return { { "You: ", "DyadicSpeakerUser" }, { normalize(content_text(message.content, CONTENT_CHARS)) } }
    elseif role == "assistant" then
      local body = normalize(content_text(message.content, CONTENT_CHARS))
      if body ~= "" then
        return { { "Assistant: ", "DyadicSpeakerAssistant" }, { body } }
      elseif value(message.stopReason) == "aborted" then
        return { { "Assistant: ", "DyadicSpeakerAssistant" }, { "✗ Aborted", "DyadicError" } }
      elseif value(message.errorMessage) then
        return {
          { "Assistant: ", "DyadicSpeakerAssistant" },
          { "✗ " .. clip(normalize(message.errorMessage), 80), "DyadicError" },
        }
      end
      return { { "Assistant: ", "DyadicSpeakerAssistant" }, { "(no content)", "DyadicMeta" } }
    elseif role == "toolResult" then
      local call = state.tool_calls[value(message.toolCallId) or ""]
      local summary = call and M.tool_summary(call.name, call.arguments) or tostring(value(message.toolName) or "tool")
      return { { "◦ " .. summary, "DyadicActivity" } }
    elseif role == "bashExecution" then
      return { { "$ " .. normalize(value(message.command)), "DyadicActivity" } }
    end
    return { { tostring(role or "message"), "DyadicMeta" } }
  elseif kind == "custom_message" then
    return {
      { tostring(value(entry.customType) or "custom") .. ": ", "DyadicSpeaker" },
      { normalize(content_text(entry.content, CONTENT_CHARS)) },
    }
  elseif kind == "compaction" then
    local tokens = math.floor((tonumber(value(entry.tokensBefore)) or 0) / 1000 + 0.5)
    return {
      { "◇ ", "DyadicCompaction" },
      { "Context compacted · " .. tokens .. "k tokens before", "DyadicActivity" },
    }
  elseif kind == "branch_summary" then
    return { { "↳ ", "DyadicBranch" }, { "Branch summary: ", "DyadicActivity" }, { normalize(entry.summary) } }
  elseif kind == "model_change" then
    return { { "model: " .. tostring(value(entry.modelId) or ""), "DyadicMeta" } }
  elseif kind == "thinking_level_change" then
    return { { "thinking: " .. tostring(value(entry.thinkingLevel) or ""), "DyadicMeta" } }
  elseif kind == "custom" then
    return { { "custom: " .. tostring(value(entry.customType) or ""), "DyadicMeta" } }
  elseif kind == "context_edit" then
    local action = value(entry.replacement) == nil and "omit" or "replace"
    return { { "context " .. action .. ": " .. tostring(value(entry.targetId) or ""), "DyadicMeta" } }
  elseif kind == "label" then
    return { { "label: " .. tostring(value(entry.label) or "(cleared)"), "DyadicMeta" } }
  elseif kind == "session_info" then
    return { { "title: " .. tostring(value(entry.name) or "empty"), "DyadicMeta" } }
  end
  return { { "[" .. tostring(kind or "entry") .. "]", "DyadicMeta" } }
end

-- The full text pi copies for an entry, or nil when it has none.
function M.copy_text(node)
  local entry = node.entry or {}
  local result
  if entry.type == "message" then
    local message = entry.message or {}
    if message.role == "bashExecution" then
      result = value(message.command)
    elseif message.content ~= nil then
      result = content_text(message.content)
      if result == "" and message.role == "assistant" then
        result = value(message.errorMessage)
      end
    end
  elseif entry.type == "custom_message" then
    result = content_text(entry.content)
  elseif entry.type == "compaction" or entry.type == "branch_summary" then
    result = value(entry.summary)
  end
  if type(result) == "string" and result:find("%S") then
    return result
  end
end

-- Text pi puts back in the editor when navigating to an entry: a user or custom message's.
function M.editor_text(node)
  local entry = node and node.entry or {}
  if entry.type == "message" and type(entry.message) == "table" and entry.message.role == "user" then
    return content_text(entry.message.content)
  elseif entry.type == "custom_message" then
    return content_text(entry.content)
  end
end

-- Label time as pi shows it: "14:05" today, "3/9 14:05" this year, else "25/3/9 14:05".
function M.label_time(iso)
  local time = require("dyadic.entries").time(iso)
  if not time then
    return nil
  end
  local seconds = math.floor(time / 1000)
  local now = os.date("*t")
  local at = os.date("*t", seconds)
  local clock = string.format("%02d:%02d", at.hour, at.min)
  if at.year == now.year and at.month == now.month and at.day == now.day then
    return clock
  elseif at.year == now.year then
    return string.format("%d/%d %s", at.month, at.day, clock)
  end
  return string.format("%02d/%d/%d %s", at.year % 100, at.month, at.day, clock)
end

return M
