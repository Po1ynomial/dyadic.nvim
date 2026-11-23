-- Builds the history model: real lines for message text, overlay rows for everything else
-- (see docs/adr/0001-history-holds-only-message-text.md).
--
-- A run is the span from one user message to the next. Inside a run, consecutive tool calls
-- and thinking blocks form a group. A group collapses into one row once agent text follows
-- it. A trailing group stays expanded while the run is live or after it failed. Blocks
-- (speaker rows, text, groups, other rows) are separated by one blank line.
--
-- Finished runs whose messages all carry entry IDs are cached; only the live run is rebuilt
-- on every frame.
local M = {}
local text = require("dyadic.text")
local clean, lines_of, one_line, truncate = text.clean, text.lines_of, text.one_line, text.truncate

local ROW_WIDTH = 200
local BAR = "▎ "

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

-- Message text without leading or trailing blank lines.
local function text_lines(value)
  local lines = lines_of(value)
  while #lines > 0 and not lines[1]:find("%S") do
    table.remove(lines, 1)
  end
  while #lines > 0 and not lines[#lines]:find("%S") do
    table.remove(lines)
  end
  return lines
end

-- "0.4s", "12s", "1m 5s", "2h 3m".
function M.duration(ms)
  local seconds = ms / 1000
  if seconds < 10 then
    return string.format("%.1fs", seconds)
  elseif seconds < 60 then
    return string.format("%ds", math.floor(seconds))
  elseif seconds < 3600 then
    return string.format("%dm %ds", math.floor(seconds / 60), math.floor(seconds % 60))
  end
  return string.format("%dh %dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

local function now_ms()
  local seconds, microseconds = vim.uv.gettimeofday()
  return seconds * 1000 + math.floor(microseconds / 1000)
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
  local chunks = { { BAR, "DyadicGroupBar" }, { "  ◦ ", "DyadicActivity" } }
  if item.kind == "thinking" then
    local count = #lines_of(item.thinking or "")
    chunks[#chunks + 1] = { "thinking", "DyadicActivity" }
    chunks[#chunks + 1] = { item.redacted and " · redacted" or (" · " .. plural(count, "line")), "DyadicMeta" }
    return chunks
  end
  local status, hl = tool_status(item)
  chunks[#chunks + 1] = { one_line(item.name or "tool"), "DyadicTool" }
  local summary = tool_summary(item.args)
  if summary ~= "" then
    chunks[#chunks + 1] = { " " .. truncate(summary, ROW_WIDTH), "DyadicActivity" }
  end
  local meta = " · " .. status
  -- Only pi's live report is exact; reopened history has no tool durations.
  if item.live and item.live.durationMs then
    meta = meta .. " " .. M.duration(item.live.durationMs)
  end
  chunks[#chunks + 1] = { meta, hl }
  return chunks
end

local function group_chunks(group, open)
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
  local chunks = {
    { BAR, "DyadicGroupBar" },
    { (open and "▾ " or "▸ ") .. table.concat(parts, " · "), "DyadicActivity" },
  }
  if errors > 0 then
    chunks[#chunks + 1] = { " · " .. plural(errors, "error"), "DyadicError" }
  end
  if running > 0 then
    chunks[#chunks + 1] = { " · " .. running .. " running", "DyadicRunning" }
  end
  return chunks
end

local function bash_chunks(message, running)
  local chunks = {
    { "▌ ", "DyadicShellBar" },
    { "$ ", "DyadicTool" },
    { truncate(one_line(message.command), ROW_WIDTH), "DyadicActivity" },
  }
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

-- When a run started and, if it is over, ended: from the user message's timestamp to the
-- time pi saved the run's last entry.
local function run_span(messages, live)
  local first = messages[1]
  local start = first and first.role == "user" and tonumber(first.timestamp) or nil
  if not start then
    return nil
  end
  if live then
    return start, now_ms()
  end
  local last = 0
  for _, message in ipairs(messages) do
    local at = tonumber(message._entry_time) or tonumber(message.timestamp) or 0
    last = math.max(last, at)
  end
  return start, last
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
  local function speaker(label, group, right)
    pieces[#pieces + 1] = {
      type = "speaker",
      chunks = { { "▍ ", group }, { one_line(label), group } },
      right = right,
    }
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
    local first_piece = #pieces + 1
    local role_name = message.role
    local mkey = message_key(message, ctx.prefix .. index)
    if role_name == "user" then
      speaker("You", "DyadicSpeakerUser")
      add_text(text.content_text(message.content))
    elseif role_name == "assistant" then
      if not assistant_seen then
        assistant_seen = true
        local meta = {}
        if type(message.model) == "string" then
          meta[#meta + 1] = one_line(message.model)
        end
        local start, finish = run_span(messages, ctx.live)
        if start and finish and finish >= start then
          meta[#meta + 1] = M.duration(finish - start)
        end
        speaker(
          "Assistant",
          "DyadicSpeakerAssistant",
          #meta > 0 and { { table.concat(meta, " · "), "DyadicMeta" } } or nil
        )
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
      local compaction = role_name == "compactionSummary"
      local label = compaction and "Context compacted" or "Branch summary"
      local meta = message.tokensBefore and (" · " .. tostring(message.tokensBefore) .. " tokens before") or ""
      pieces[#pieces + 1] = {
        type = "row",
        kind = "summary",
        key = "summary:" .. mkey,
        message = message,
        label = label,
        chunks = {
          { compaction and "◇ " or "↳ ", compaction and "DyadicCompaction" or "DyadicBranch" },
          { label, "DyadicActivity" },
          { meta, "DyadicMeta" },
        },
      }
    elseif role_name == "usage" then
      pieces[#pieces + 1] = {
        type = "row",
        kind = "usage",
        chunks = { { "usage · " .. one_line(message.content), "DyadicMeta" } },
      }
    elseif role_name == "custom" and message.customType == "dyadic-changes" then
      -- A change note dyadic gave the agent: one line, the note itself in the detail.
      local files = type(message.details) == "table"
          and type(message.details.files) == "table"
          and message.details.files
        or {}
      local label = "told the agent: " .. table.concat(files, ", ") .. " changed"
      pieces[#pieces + 1] = {
        type = "row",
        kind = "note",
        key = "note:" .. mkey,
        message = message,
        label = "Change note",
        chunks = { { "↳ ", "DyadicBranch" }, { truncate(one_line(label), ROW_WIDTH), "DyadicActivity" } },
      }
    elseif role_name == "custom" then
      if message.display ~= false then
        speaker(message.customType or "Extension", "DyadicSpeaker")
        add_text(text.content_text(message.content))
      end
    elseif role_name ~= "system" then
      speaker(role_name or "Message", "DyadicSpeaker")
      add_text(text.content_text(message.content))
    end
    -- Remember which session entry each piece shows, for actions at the cursor.
    for i = first_piece, #pieces do
      local target = pieces[i].item or pieces[i]
      target.entry = target.entry or message._entry_id
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

-- Group consecutive activities and decide their default collapse state.
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

-- Render grouped pieces into relative lines and rows, one blank line between blocks.
local function emit(grouped, expanded)
  local lines, rows, items, groups, speakers, marks = {}, {}, {}, {}, {}, {}
  local function block()
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
  end
  -- Marks: the session entry shown from a line on, ascending by line.
  local function mark(entry)
    if entry then
      marks[#marks + 1] = { line = #lines, entry = entry }
    end
  end
  local function row(entry)
    entry.line = #lines
    lines[#lines + 1] = ""
    rows[#rows + 1] = entry
  end
  for _, piece in ipairs(grouped) do
    block()
    mark(piece.entry or (piece.items and piece.items[1].entry))
    if piece.type == "speaker" then
      speakers[#speakers + 1] = #lines
      row({ kind = "speaker", chunks = piece.chunks, right = piece.right })
    elseif piece.type == "text" then
      vim.list_extend(lines, text_lines(piece.text))
    elseif piece.type == "group" then
      local open = expanded[piece.key]
      if open == nil then
        open = piece.default
      end
      groups[piece.key] = { expanded = open, items = piece.items }
      row({ kind = "group", group = piece.key, open = open, chunks = group_chunks(piece, open) })
      for _, item in ipairs(piece.items) do
        items[item.key] = item
        if open then
          mark(item.entry)
          row({ kind = "item", key = item.key, group = piece.key, chunks = item_chunks(item) })
        end
      end
    else
      if piece.key then
        items[piece.key] = { kind = piece.kind, key = piece.key, message = piece.message, label = piece.label }
      end
      row({ kind = piece.kind, key = piece.key, chunks = piece.chunks })
    end
  end
  return { lines = lines, rows = rows, items = items, groups = groups, speakers = speakers, marks = marks }
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
  local model = { lines = {}, rows = {}, items = {}, groups = {}, speakers = {}, marks = {} }
  local function append(part)
    if #part.lines == 0 then
      return
    end
    if #model.lines > 0 then
      model.lines[#model.lines + 1] = ""
    end
    local offset = #model.lines
    for _, line in ipairs(part.lines) do
      model.lines[#model.lines + 1] = line
    end
    for _, entry in ipairs(part.rows) do
      local copy = setmetatable({ line = entry.line + offset }, { __index = entry })
      model.rows[#model.rows + 1] = copy
    end
    for _, line in ipairs(part.speakers or {}) do
      model.speakers[#model.speakers + 1] = line + offset
    end
    for _, item in ipairs(part.marks or {}) do
      model.marks[#model.marks + 1] = { line = item.line + offset, entry = item.entry }
    end
    for key, item in pairs(part.items or {}) do
      model.items[key] = item
    end
    for key, group in pairs(part.groups or {}) do
      model.groups[key] = group
    end
  end

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
  append(tail)
  -- Queued messages stay pinned to the end as one block.
  local queue = { lines = {}, rows = {} }
  local function queued(label, value)
    queue.rows[#queue.rows + 1] = {
      line = #queue.lines,
      kind = "queue",
      chunks = { { "⧗ " .. label .. " · ", "DyadicQueue" }, { truncate(one_line(value), ROW_WIDTH), "DyadicMeta" } },
    }
    queue.lines[#queue.lines + 1] = ""
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
  append(queue)
  -- A buffer always has a line.
  if #model.lines == 0 then
    model.lines[1] = ""
  end

  agent._render_cache = use_cache and new_cache or old_cache
  return model
end

return M
