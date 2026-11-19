-- Builds the history model: real lines for message text, overlay rows for everything else.
--
-- A run is the span from one user message to the next. Inside a run, consecutive tool calls
-- and thinking blocks form an activity group. A group collapses into one summary row once
-- agent text follows it. A trailing group stays expanded while the run is live or after it
-- failed. Finished runs whose messages all carry entry IDs are cached; only the live run is
-- rebuilt on every frame.
local M = {}
local text = require("dyadic.text")
local clean, lines_of, one_line, truncate = text.clean, text.lines_of, text.one_line, text.truncate

local ROW_WIDTH = 200

-- Stable identity for a message across streaming, message_end, and history re-fetches.
local function message_key(message, fallback)
  if message.timestamp ~= nil and message.timestamp ~= vim.NIL then
    return tostring(message.timestamp)
  end
  return message._entry_id or fallback
end

local function has_text(value)
  return type(value) == "string" and value:find("%S") ~= nil
end

local function first_line(value)
  return (clean(value):match("^%s*([^\n]*)") or "")
end

local function plural(count, word)
  return count .. " " .. word .. (count == 1 and "" or "s")
end

-- Short description of a tool call from its arguments.
local function tool_summary(args)
  if type(args) == "string" then
    return one_line(args)
  end
  if type(args) ~= "table" then
    return ""
  end
  for _, name in ipairs({ "command", "path", "file_path", "pattern", "query", "url" }) do
    if type(args[name]) == "string" and args[name] ~= "" then
      return first_line(args[name])
    end
  end
  for _, name in ipairs(text.sorted_keys(args)) do
    if type(args[name]) == "string" then
      return first_line(args[name])
    end
  end
  return ""
end

local function tool_status(item)
  local live, result = item.live or {}, item.result
  if live.running then
    return "running", "DyadicRunning"
  end
  if live.isError or (result and result.isError) then
    return "error", "DyadicError"
  end
  if result or live.result then
    return "done", "DyadicMeta"
  end
  return item.in_live_run and "pending" or "no result", "DyadicMeta"
end
M.tool_status = tool_status

local function item_chunks(item)
  if item.kind == "thinking" then
    local count = #lines_of(item.thinking or "")
    return {
      { "  ◦ thinking", "DyadicActivity" },
      { item.redacted and " · redacted" or (" · " .. plural(count, "line")), "DyadicMeta" },
    }
  end
  local status, hl = tool_status(item)
  local chunks = { { "  ◦ ", "DyadicActivity" }, { one_line(item.name or "tool"), "DyadicTool" } }
  local summary = tool_summary(item.args)
  if summary ~= "" then
    chunks[#chunks + 1] = { " " .. truncate(summary, ROW_WIDTH), "DyadicActivity" }
  end
  local meta = " · " .. status
  if item.live and item.live.durationMs then
    meta = meta .. string.format(" %dms", item.live.durationMs)
  end
  chunks[#chunks + 1] = { meta, hl }
  return chunks
end

local function summary_chunks(group)
  local thinking, tools, errors, running = 0, 0, 0, 0
  for _, item in ipairs(group.items) do
    if item.kind == "thinking" then
      thinking = thinking + 1
    else
      tools = tools + 1
      local status = tool_status(item)
      errors = errors + (status == "error" and 1 or 0)
      running = running + (status == "running" and 1 or 0)
    end
  end
  local parts = {}
  if thinking > 0 then
    parts[#parts + 1] = thinking == 1 and "thinking" or (thinking .. "× thinking")
  end
  if tools > 0 then
    parts[#parts + 1] = plural(tools, "tool")
  end
  local chunks = { { "▸ " .. table.concat(parts, " · "), "DyadicActivity" } }
  if errors > 0 then
    chunks[#chunks + 1] = { " · " .. plural(errors, "error"), "DyadicError" }
  end
  if running > 0 then
    chunks[#chunks + 1] = { " · " .. running .. " running", "DyadicRunning" }
  end
  return chunks
end

local function bash_chunks(message, running)
  local chunks = { { "$ ", "DyadicTool" }, { truncate(one_line(message.command), ROW_WIDTH), "DyadicActivity" } }
  local meta = {}
  if running then
    meta[#meta + 1] = "running"
  elseif message.cancelled then
    meta[#meta + 1] = "cancelled"
  elseif message.exitCode ~= nil and message.exitCode ~= vim.NIL then
    meta[#meta + 1] = "exit " .. tostring(message.exitCode)
  end
  if message.truncated then
    meta[#meta + 1] = "truncated"
  end
  if message.excludeFromContext then
    meta[#meta + 1] = "excluded from context"
  end
  if #meta > 0 then
    chunks[#chunks + 1] = { " · " .. table.concat(meta, " · "), "DyadicMeta" }
  end
  return chunks
end

-- Convert one run's messages into an ordered list of pieces.
local function pieces_of(messages, ctx)
  local pieces, calls, results = {}, {}, {}
  for _, message in ipairs(messages) do
    if message.role == "toolResult" and message.toolCallId then
      results[message.toolCallId] = message
    elseif message.role == "assistant" and type(message.content) == "table" then
      for _, block in ipairs(message.content) do
        if block.type == "toolCall" and block.id then
          calls[block.id] = true
        end
      end
    end
  end
  local assistant_seen = false
  local function role(label, meta)
    local chunks = { { "── " .. one_line(label), "DyadicSpeaker" } }
    if meta and meta ~= "" then
      chunks[#chunks + 1] = { " · " .. one_line(meta), "DyadicMeta" }
    end
    pieces[#pieces + 1] = { type = "role", chunks = chunks }
  end
  local function add_text(value)
    if has_text(value) then
      pieces[#pieces + 1] = { type = "text", text = value }
    end
  end
  local function add_tool(id, name, args, key)
    pieces[#pieces + 1] = {
      type = "item",
      item = {
        kind = "tool",
        key = id or key,
        id = id,
        name = name or (ctx.tools[id] or {}).toolName,
        args = args,
        result = id and results[id] or nil,
        live = ctx.live and id and ctx.tools[id] or nil,
        in_live_run = ctx.live,
      },
    }
  end
  for index, message in ipairs(messages) do
    local role_name = message.role
    local mkey = message_key(message, ctx.prefix .. index)
    if role_name == "user" then
      role("You")
      add_text(text.content_text(message.content))
    elseif role_name == "assistant" then
      if not assistant_seen then
        assistant_seen = true
        role("Assistant", type(message.model) == "string" and message.model or nil)
      end
      if type(message.content) == "string" then
        add_text(message.content)
      end
      for block_index, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "text" then
          add_text(block.text)
        elseif block.type == "thinking" then
          pieces[#pieces + 1] = {
            type = "item",
            item = {
              kind = "thinking",
              key = "thinking:" .. mkey .. ":" .. block_index,
              thinking = block.thinking or "",
              redacted = block.redacted,
            },
          }
        elseif block.type == "toolCall" then
          local args = block.arguments
          if (type(args) ~= "table" or next(args) == nil) and has_text(block.raw) then
            args = block.raw
          end
          add_tool(block.id, block.name, args, "tool:" .. mkey .. ":" .. block_index)
        elseif block.type == "image" then
          add_text("[Image: " .. one_line(block.mimeType or "unknown format") .. "]")
        end
      end
      if has_text(message.errorMessage) then
        pieces[#pieces + 1] = {
          type = "row",
          kind = "error",
          key = "error:" .. mkey,
          message = message.errorMessage,
          chunks = { { "✗ " .. truncate(one_line(message.errorMessage), ROW_WIDTH), "DyadicError" } },
        }
      elseif message.stopReason == "aborted" then
        pieces[#pieces + 1] = { type = "row", kind = "aborted", chunks = { { "✗ Aborted", "DyadicError" } } }
      end
    elseif role_name == "toolResult" then
      if not calls[message.toolCallId] then
        add_tool(message.toolCallId, message.toolName, nil, "tool:" .. mkey)
      end
    elseif role_name == "bashExecution" then
      pieces[#pieces + 1] = {
        type = "row",
        kind = "bash",
        key = "bash:" .. mkey,
        message = message,
        chunks = bash_chunks(message, false),
      }
    elseif role_name == "compactionSummary" or role_name == "branchSummary" then
      local label = role_name == "compactionSummary" and "Context compacted" or "Branch summary"
      local meta = message.tokensBefore and (" · " .. tostring(message.tokensBefore) .. " tokens before") or ""
      pieces[#pieces + 1] = {
        type = "row",
        kind = "summary",
        key = "summary:" .. mkey,
        message = message,
        label = label,
        chunks = { { "▸ " .. label, "DyadicActivity" }, { meta, "DyadicMeta" } },
      }
    elseif role_name == "usage" then
      pieces[#pieces + 1] = {
        type = "row",
        kind = "usage",
        chunks = { { "  usage · " .. one_line(message.content), "DyadicMeta" } },
      }
    elseif role_name == "custom" then
      if message.display ~= false then
        role(message.customType or "Extension")
        add_text(text.content_text(message.content))
      end
    elseif role_name ~= "system" then
      role(role_name or "Message")
      add_text(text.content_text(message.content))
    end
  end
  -- Tools pi reports before their call reaches the message list.
  if ctx.live then
    local seen = {}
    for _, piece in ipairs(pieces) do
      if piece.type == "item" and piece.item.id then
        seen[piece.item.id] = true
      end
    end
    for _, id in ipairs(text.sorted_keys(ctx.tools)) do
      if not seen[id] then
        add_tool(id, ctx.tools[id].toolName, ctx.tools[id].args)
      end
    end
  end
  return pieces
end

-- Group consecutive activity items and decide their default collapse state.
local function group_pieces(pieces, ctx)
  local out, groups = {}, {}
  local current
  for _, piece in ipairs(pieces) do
    if piece.type == "item" then
      if not current then
        current = { type = "group", items = {} }
        out[#out + 1] = current
        groups[#groups + 1] = current
      end
      current.items[#current.items + 1] = piece.item
    else
      current = nil
      out[#out + 1] = piece
      if piece.type == "text" then
        for _, group in ipairs(groups) do
          group.followed = true
        end
      end
    end
  end
  for _, group in ipairs(groups) do
    group.key = "group:" .. group.items[1].key
    if group.followed then
      group.default = false
    else
      group.default = ctx.live or ctx.failed or false
    end
  end
  return out, groups
end

-- Render grouped pieces into relative lines and rows.
local function emit(grouped, expanded)
  local lines, rows, items, groups, roles = {}, {}, {}, {}, {}
  local previous
  local function row(entry)
    entry.line = #lines
    lines[#lines + 1] = ""
    rows[#rows + 1] = entry
    previous = "row"
  end
  for _, piece in ipairs(grouped) do
    if piece.type == "role" then
      -- A blank line before each speaker keeps messages visually apart.
      lines[#lines + 1] = ""
      roles[#roles + 1] = #lines
      row({ kind = "role", chunks = piece.chunks })
    elseif piece.type == "text" then
      if previous == "text" then
        lines[#lines + 1] = ""
      end
      vim.list_extend(lines, lines_of(piece.text))
      previous = "text"
    elseif piece.type == "group" then
      local open = expanded[piece.key]
      if open == nil then
        open = piece.default
      end
      groups[piece.key] = { expanded = open, items = piece.items }
      if open then
        for _, item in ipairs(piece.items) do
          items[item.key] = item
          row({ kind = "item", key = item.key, group = piece.key, chunks = item_chunks(item) })
        end
      else
        for _, item in ipairs(piece.items) do
          items[item.key] = item
        end
        row({ kind = "group", group = piece.key, chunks = summary_chunks(piece) })
      end
    else
      if piece.key then
        items[piece.key] = { kind = piece.kind, key = piece.key, message = piece.message, label = piece.label }
      end
      row({ kind = piece.kind, key = piece.key, chunks = piece.chunks })
    end
  end
  return { lines = lines, rows = rows, items = items, groups = groups, roles = roles }
end

local function render_run(messages, ctx, expanded)
  local grouped, groups = group_pieces(pieces_of(messages, ctx), ctx)
  return emit(grouped, expanded), groups
end

local function cache_base(messages, failed)
  local ids = {}
  for _, message in ipairs(messages) do
    if not message._entry_id then
      return nil
    end
    ids[#ids + 1] = message._entry_id
  end
  return table.concat(ids, ",") .. (failed and "|failed" or "")
end

local function split_runs(messages)
  local runs, current = {}, nil
  for _, message in ipairs(messages) do
    if message.role == "user" or not current then
      current = {}
      runs[#runs + 1] = current
    end
    current[#current + 1] = message
  end
  return runs
end

local function signature(group_keys, expanded)
  local parts = {}
  for _, key in ipairs(group_keys) do
    local value = expanded[key]
    parts[#parts + 1] = value == nil and "-" or (value and "1" or "0")
  end
  return table.concat(parts)
end

-- Build the whole history. `opts.cache = false` forces a fresh render of every run.
function M.build(agent, opts)
  opts = opts or {}
  local use_cache = opts.cache ~= false
  local messages = {}
  for _, message in ipairs(agent.messages or {}) do
    messages[#messages + 1] = message
  end
  if agent.partial then
    messages[#messages + 1] = agent.partial
  end
  local expanded = agent.expanded or {}
  local old_cache, new_cache = agent._render_cache or {}, {}
  local model = { lines = {}, rows = {}, items = {}, groups = {}, roles = {} }
  local function append(part)
    local offset = #model.lines
    for _, line in ipairs(part.lines) do
      model.lines[#model.lines + 1] = line
    end
    for _, entry in ipairs(part.rows) do
      local copy = setmetatable({ line = entry.line + offset }, { __index = entry })
      model.rows[#model.rows + 1] = copy
    end
    for _, line in ipairs(part.roles or {}) do
      model.roles[#model.roles + 1] = line + offset
    end
    for key, item in pairs(part.items or {}) do
      model.items[key] = item
    end
    for key, group in pairs(part.groups or {}) do
      model.groups[key] = group
    end
  end

  local title = agent.title or (agent.state or {}).sessionName or "Dyadic"
  append({
    lines = { "" },
    rows = {
      {
        line = 0,
        kind = "title",
        chunks = {
          { "── " .. one_line(title), "DyadicTitle" },
          { " · " .. one_line(agent.cwd or ""), "DyadicMeta" },
        },
      },
    },
  })

  local runs = split_runs(messages)
  for index, run in ipairs(runs) do
    local last = index == #runs
    local live = last and (agent.active or agent.partial ~= nil) or false
    local ctx = {
      live = live,
      failed = last and agent.run_failed or false,
      tools = live and (agent.tools or {}) or {},
      prefix = "run" .. index .. ":",
    }
    local base = not live and use_cache and cache_base(run, ctx.failed) or nil
    local entry = base and old_cache[base]
    local part
    if entry then
      local sig = signature(entry.group_keys, expanded)
      part = entry.variants[sig]
      if not part then
        part = render_run(run, ctx, expanded)
        entry.variants[sig] = part
      end
    else
      local groups
      part, groups = render_run(run, ctx, expanded)
      if base then
        local keys = {}
        for _, group in ipairs(groups) do
          keys[#keys + 1] = group.key
        end
        entry = { group_keys = keys, variants = { [signature(keys, expanded)] = part } }
      end
    end
    if base then
      new_cache[base] = entry
    end
    append(part)
  end

  local tail = { lines = {}, rows = {} }
  local function tail_row(entry)
    entry.line = #tail.lines
    tail.lines[#tail.lines + 1] = ""
    tail.rows[#tail.rows + 1] = entry
  end
  if agent.bash and agent.bash.running then
    tail_row({ kind = "bash", key = "bash:live", chunks = bash_chunks(agent.bash, true) })
    model.items["bash:live"] = { kind = "bash", key = "bash:live", message = agent.bash, running = true }
  end
  local function queued(label, value)
    tail_row({
      kind = "queue",
      chunks = { { "⧗ " .. label .. " · ", "DyadicQueue" }, { truncate(one_line(value), ROW_WIDTH), "DyadicMeta" } },
    })
  end
  for _, value in ipairs((agent.queue or {}).steering or {}) do
    queued("steer", value)
  end
  for _, value in ipairs((agent.queue or {}).followUp or {}) do
    queued("follow-up", value)
  end
  for _, pending in ipairs(agent.compaction_queue or {}) do
    queued("after compaction", pending.text)
  end
  if #tail.lines > 0 then
    table.insert(tail.lines, 1, "")
    for _, entry in ipairs(tail.rows) do
      entry.line = entry.line + 1
    end
  end
  append(tail)

  agent._render_cache = use_cache and new_cache or old_cache
  return model
end

return M
