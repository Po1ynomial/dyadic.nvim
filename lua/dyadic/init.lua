local M = {}
local defaults = {
  cmd = { "pi" },
  args = {},
  bridge = true,
  placement = "sidebar",
  sidebar = { side = "right", width = 0.35, min_width = 40, max_width = 120 },
  composer = { min_height = 3, max_height = 0.4 },
  statusline = true,
  completion = true,
  mappings = {},
  double_escape = "tree",
  tree = { keys = {} },
  sessions = { keys = {} },
  review = false,
  change_notes = false,
}
local config = vim.deepcopy(defaults)
local agents, next_id, last = {}, 0, nil

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  vim.validate("cmd", config.cmd, "table")
  vim.validate("args", config.args, "table")
  vim.validate("bridge", config.bridge, "boolean")
  vim.validate("placement", config.placement, function(value)
    return value == "sidebar" or value == "free"
  end, '"sidebar" or "free"')
  vim.validate("sidebar", config.sidebar, "table")
  vim.validate("sidebar.side", config.sidebar.side, function(value)
    return value == "left" or value == "right"
  end, '"left" or "right"')
  for _, name in ipairs({ "width", "min_width", "max_width" }) do
    vim.validate("sidebar." .. name, config.sidebar[name], "number")
  end
  vim.validate("composer", config.composer, "table")
  vim.validate("composer.min_height", config.composer.min_height, "number")
  vim.validate("composer.max_height", config.composer.max_height, "number")
  vim.validate("statusline", config.statusline, "boolean")
  vim.validate("completion", config.completion, "boolean")
  vim.validate("mappings", config.mappings, "table")
  vim.validate("double_escape", config.double_escape, function(value)
    return value == "tree" or value == "fork" or value == "none"
  end, '"tree", "fork", or "none"')
  vim.validate("tree", config.tree, "table")
  vim.validate("tree.keys", config.tree.keys, "table")
  vim.validate("sessions", config.sessions, "table")
  vim.validate("sessions.keys", config.sessions.keys, "table")
  vim.validate("review", config.review, { "boolean", "table" })
  vim.validate("change_notes", config.change_notes, "boolean")
  local review = config.review
  if type(review) == "table" then
    vim.validate("review.default", review.default, "boolean", true)
    vim.validate("review.paths", review.paths, "table", true)
    vim.validate("review.keys", review.keys, "table", true)
  end
  local refused = require("dyadic.cli").check(config.args)
  assert(not refused, "dyadic: args: " .. tostring(refused))
  assert(#config.cmd > 0, "dyadic: cmd must not be empty")
  assert(
    config.composer.min_height >= 1 and config.composer.max_height > 0,
    "dyadic: composer heights must be positive"
  )
end

function M.get(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  for _, agent in pairs(agents) do
    if agent.history_buf == buf or agent.composer_buf == buf then
      return agent
    end
  end
end

function M.list()
  local result = {}
  for _, agent in pairs(agents) do
    result[#result + 1] = agent
  end
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

local function spawn(args)
  next_id = next_id + 1
  local agent = require("dyadic.agent").new(next_id, vim.deepcopy(config), function(closed)
    agents[closed.id] = nil
    if last == closed then
      last = M.list()[#M.list()]
    end
  end, args)
  agents[agent.id], last = agent, agent
  -- Unloading the history or composer, as :bd, :bunload, and :bwipeout do, ends the agent:
  -- the buffers are unlisted, so BufDelete never fires, and unloading takes their text. :e
  -- unloads too, but loads the buffer again at once; then the text comes back instead.
  local group = vim.api.nvim_create_augroup("DyadicAgent" .. agent.id, { clear = true })
  for _, buf in ipairs({ agent.history_buf, agent.composer_buf }) do
    vim.api.nvim_create_autocmd("BufUnload", {
      group = group,
      buffer = buf,
      callback = function()
        local draft = buf == agent.composer_buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or nil
        vim.schedule(function()
          if not agent.closed and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
            require("dyadic.view").reloaded(agent, buf, draft)
            return
          end
          agent:close()
          pcall(vim.api.nvim_del_augroup_by_id, group)
        end)
      end,
    })
  end
  require("dyadic.view").show(agent)
  return agent
end

-- Start an agent with pi arguments after `args` from setup(), as `:Dyadic` does. Words
-- that pi reads as messages become the draft. Returns the agent when it started at once;
-- -r and a session ID from another directory ask first.
local function start(words)
  local started
  require("dyadic.cli").prepare(vim.fn.getcwd(), config.args, words or {}, function(args, draft)
    started = spawn(args)
    if draft ~= "" then
      started:set_draft(draft)
    end
  end, { interactive = true, config = config })
  return started
end

-- Open an agent with extra pi arguments, without asking anything: -r and session IDs from
-- other directories are errors here.
function M.open(args)
  local opened
  require("dyadic.cli").prepare(vim.fn.getcwd(), config.args, args or {}, function(final, draft)
    opened = spawn(final)
    if draft ~= "" then
      opened:set_draft(draft)
    end
  end)
  return opened
end

function M.show(agent)
  agent = agent or M.get() or last
  if not agent or agent.closed then
    return start()
  end
  last = agent
  require("dyadic.view").show(agent)
  return agent
end

-- Inside this tab's pair, hide it and go back to the main area's window used last;
-- elsewhere, show the pair of this tab's sidebar or of the last agent, and go into it.
function M.toggle()
  local Composer, Sidebar = require("dyadic.composer"), require("dyadic.sidebar")
  local current = vim.api.nvim_get_current_win()
  if config.placement == "sidebar" then
    local win = Sidebar.window()
    if not win then
      return M.show()
    end
    if not Sidebar.contains(current) then
      return M.show(require("dyadic.view").agent_of(vim.api.nvim_win_get_buf(win)))
    end
    local main = Sidebar.main_window()
    if not Sidebar.close() then
      vim.notify("Dyadic: the sidebar is the only window in this tab", vim.log.levels.WARN)
      return
    end
    pcall(vim.api.nvim_set_current_win, main)
    return
  end
  local agent = M.get() or last
  if not agent or agent.closed then
    return M.show()
  end
  if current ~= Composer.anchor(agent) and current ~= Composer.window(agent) then
    return M.show(agent)
  end
  -- Looked up first: hiding enters the window the pair gives back.
  local back = Sidebar.last_main()
  Composer.hide(agent)
  pcall(vim.api.nvim_set_current_win, back or Sidebar.main_window())
end

function M.action(name)
  local agent = M.get() or last
  if not agent or agent.closed then
    vim.notify("Dyadic: open an agent first with :Dyadic", vim.log.levels.WARN)
    return
  end
  if name == "submit" then
    agent:submit()
  elseif name == "follow_up" then
    agent:submit("followUp")
  elseif name == "abort" then
    agent:abort()
  elseif name == "dequeue" then
    agent:dequeue()
  elseif name == "close" then
    agent:close()
  else
    agent:action(name)
  end
end

-- Why a word is not a :Dyadic command, for the words people may try: pi's commands and
-- the actions.
local function not_a_command(word)
  local View = require("dyadic.view")
  if word == "new" then
    return "Dyadic: :Dyadic opens another agent; /new in the composer starts a new session"
  end
  if vim.tbl_contains(require("dyadic.commands").names, word) then
    local hint = View.actions[word] and string.format(", or map the `%s` action", word) or ""
    return string.format("Dyadic: %s is a pi command; type /%s in the composer%s", word, word, hint)
  end
  if View.actions[word] or word == "close" then
    return string.format('Dyadic: %s is an action; map it, or call require("dyadic").action("%s")', word, word)
  end
  return "Dyadic: unknown command " .. word
end

-- :Dyadic [pi arguments], or one of dyadic's own commands.
function M.command(text)
  text = vim.trim(text or "")
  if text == "" or text:sub(1, 1) == "-" then
    local words, err = require("dyadic.cli").split(text)
    if not words then
      vim.notify("Dyadic: " .. err, vim.log.levels.ERROR)
      return
    end
    start(words)
    return
  end
  if text == "toggle" then
    M.toggle()
    return
  end
  if text == "agents" then
    vim.ui.select(M.list(), {
      prompt = "Dyadic agents",
      format_item = function(agent)
        return string.format(
          "%s | %s | %s",
          agent.state.sessionName or agent.state.sessionId or ("pi " .. agent.id),
          agent.cwd,
          agent.phase
        )
      end,
    }, function(agent)
      if agent and not agent.closed then
        M.show(agent)
      end
    end)
    return
  end
  local words = vim.split(text, "%s+", { trimempty = true })
  if words[1] ~= "review" then
    vim.notify(not_a_command(words[1]), vim.log.levels.ERROR)
    return
  end
  local agent = M.get() or last
  if not agent or agent.closed then
    vim.notify("Dyadic: open an agent first with :Dyadic", vim.log.levels.WARN)
    return
  end
  last = agent
  require("dyadic.review").command(agent, vim.list_slice(words, 2))
end

-- Complete `prefix`, the word being typed; `before` are the words before it.
function M.complete(prefix, before)
  before = before or {}
  if (before[1] or prefix):sub(1, 1) == "-" then
    return require("dyadic.cli").complete(prefix, before)
  end
  if #before > 0 then
    return {}
  end
  return vim.tbl_filter(function(item)
    return item:sub(1, #prefix) == prefix
  end, { "agents", "review", "toggle" })
end

function M.shutdown()
  for _, agent in ipairs(M.list()) do
    agent:close(true)
  end
end

return M
