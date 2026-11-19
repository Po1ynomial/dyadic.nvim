-- Text of the window bars, the composer's footer, and the statuslines.
--   history winbar:  title, with pi's working directory right-aligned
--   composer winbar: spinner and phase, or "ready"; queued message counts right-aligned
--   footer:          context use and cost; model and thinking level; extension statuses
--   statusline:      which buffer this is and pi's session ID
local M = {}
local text = require("dyadic.text")
local one_line = text.one_line

M.SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function escape(value)
  return (one_line(value):gsub("%%", "%%%%"))
end

local function hl(group, value)
  return "%#" .. group .. "#" .. escape(value)
end

-- Compact token counts the way pi's footer writes them.
function M.tokens(count)
  if count < 1000 then
    return tostring(count)
  elseif count < 10000 then
    return string.format("%.1fk", count / 1000)
  elseif count < 1000000 then
    return string.format("%dk", math.floor(count / 1000 + 0.5))
  elseif count < 10000000 then
    return string.format("%.1fM", count / 1000000)
  end
  return string.format("%dM", math.floor(count / 1000000 + 0.5))
end

function M.history_winbar(agent)
  local state = agent.state or {}
  local title = agent.title or state.sessionName or ""
  local cwd = vim.fn.fnamemodify(agent.cwd or "", ":~")
  return " " .. hl("DyadicTitle", title) .. "%=%<" .. hl("DyadicMeta", cwd) .. " "
end

local function busy(agent)
  return agent.active or (agent.bash and agent.bash.running) or false
end
M.busy = busy

function M.composer_winbar(agent, frame)
  local phase = agent.phase or "Idle"
  local left
  if busy(agent) then
    local label = phase == "Idle" and "working" or phase:sub(1, 1):lower() .. phase:sub(2)
    left = hl("DyadicSpinner", M.SPINNER[frame or 1] .. " ") .. hl("DyadicPhase", label)
  elseif phase == "Idle" then
    left = hl("DyadicMeta", "ready")
  else
    left = hl("DyadicPhase", phase:sub(1, 1):lower() .. phase:sub(2))
  end
  local counts = {}
  local queue = agent.queue or {}
  local function count(label, list)
    if list and #list > 0 then
      counts[#counts + 1] = label .. " " .. #list
    end
  end
  count("steer", queue.steering)
  count("follow-up", queue.followUp)
  count("after compaction", agent.compaction_queue)
  local right = #counts > 0 and hl("DyadicQueue", table.concat(counts, " · ")) or ""
  return " " .. left .. "%=" .. right .. " "
end

-- Footer lines as virtual line chunks.
function M.footer(agent)
  local state, stats = agent.state or {}, agent.stats or {}
  local model = type(state.model) == "table" and state.model or {}
  local usage = type(stats.contextUsage) == "table" and stats.contextUsage or {}
  local lines = {}

  local first = {}
  local window = type(usage.contextWindow) == "number" and usage.contextWindow
    or (type(model.contextWindow) == "number" and model.contextWindow)
    or nil
  if window then
    local percent = type(usage.percent) == "number" and usage.percent or nil
    local group = "DyadicFooter"
    if percent and percent > 90 then
      group = "DyadicError"
    elseif percent and percent > 70 then
      group = "DyadicWarn"
    end
    local value = (percent and string.format("%d%%", math.floor(percent + 0.5)) or "?") .. "/" .. M.tokens(window)
    first[#first + 1] = { "ctx ", "DyadicFooter" }
    first[#first + 1] = { value, group }
    if state.autoCompactionEnabled then
      first[#first + 1] = { " (auto)", "DyadicFooter" }
    end
  end
  if type(stats.cost) == "number" and stats.cost > 0 then
    first[#first + 1] = { (#first > 0 and " · " or "") .. string.format("$%.3f", stats.cost), "DyadicFooter" }
  end
  if #first > 0 then
    lines[#lines + 1] = first
  end

  if model.id then
    local value = one_line(model.id)
    if model.reasoning then
      local level = state.thinkingLevel or "off"
      value = value .. " · " .. (level == "off" and "thinking off" or one_line(level))
    end
    lines[#lines + 1] = { { value, "DyadicFooter" } }
  end

  local statuses = {}
  for _, key in ipairs(text.sorted_keys(agent.statuses or {})) do
    statuses[#statuses + 1] = one_line(agent.statuses[key])
  end
  if #statuses > 0 then
    lines[#lines + 1] = { { table.concat(statuses, " · "), "DyadicFooter" } }
  end
  return lines
end

function M.statusline(agent, label)
  local id = (agent.state or {}).sessionId
  return " " .. escape(label) .. (id and (" · " .. escape(id)) or "")
end

return M
