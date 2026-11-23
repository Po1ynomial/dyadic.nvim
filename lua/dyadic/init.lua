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
  vim.validate("review", config.review, { "boolean", "table" })
  vim.validate("change_notes", config.change_notes, "boolean")
  local review = config.review
  if type(review) == "table" then
    vim.validate("review.default", review.default, "boolean", true)
    vim.validate("review.paths", review.paths, "table", true)
    vim.validate("review.keys", review.keys, "table", true)
  end
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

function M.open()
  next_id = next_id + 1
  local agent = require("dyadic.agent").new(next_id, vim.deepcopy(config), function(closed)
    agents[closed.id] = nil
    if last == closed then
      last = M.list()[#M.list()]
    end
  end)
  agents[agent.id], last = agent, agent
  local group = vim.api.nvim_create_augroup("DyadicAgent" .. agent.id, { clear = true })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = agent.history_buf,
    once = true,
    callback = function()
      agent:close(true)
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end)
    end,
  })
  require("dyadic.view").show(agent)
  return agent
end

function M.show(agent)
  agent = agent or M.get() or last
  if not agent or agent.closed then
    return M.open()
  end
  last = agent
  require("dyadic.view").show(agent)
  return agent
end

-- Hide or show the last agent: the sidebar of this tab, or its free history window.
function M.toggle()
  local Composer, Sidebar = require("dyadic.composer"), require("dyadic.sidebar")
  if config.placement == "sidebar" then
    if Sidebar.window() then
      if not Sidebar.close() then
        vim.notify("Dyadic: the sidebar is the only window in this tab", vim.log.levels.WARN)
      end
      return
    end
    return M.show()
  end
  local agent = M.get() or last
  if not agent or agent.closed then
    return M.show()
  end
  local wins = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ""
  end, vim.fn.win_findbuf(agent.history_buf))
  local here = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  end, wins)
  if #here == 0 then
    return M.show(agent)
  end
  Composer.close(agent)
  for _, win in ipairs(here) do
    pcall(vim.api.nvim_win_close, win, false)
  end
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

function M.command(text)
  text = vim.trim(text or "")
  if text == "new" then
    M.open()
    return
  end
  if text == "" then
    M.show()
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
  if not vim.tbl_contains(M.complete(""), words[1]) then
    vim.notify("Dyadic: unknown command " .. words[1], vim.log.levels.ERROR)
    return
  end
  local agent = M.get() or last
  if not agent or agent.closed then
    vim.notify("Dyadic: open an agent first with :Dyadic", vim.log.levels.WARN)
    return
  end
  if words[1] == "review" then
    last = agent
    require("dyadic.review").command(agent, vim.list_slice(words, 2))
  elseif text == "composer" then
    last = agent
    require("dyadic.view").focus(agent, true)
  elseif text == "abort" or text == "close" or text == "submit" or text == "follow_up" or text == "dequeue" then
    M.action(text)
  else
    require("dyadic.commands").run(agent, "/" .. text)
  end
end

function M.complete(prefix)
  local items = { "new", "toggle", "agents", "composer", "abort", "close", "submit", "follow_up", "dequeue", "review" }
  vim.list_extend(items, require("dyadic.commands").names)
  -- `close` already ends the agent.
  local result, seen = {}, { quit = true }
  for _, item in ipairs(items) do
    if not seen[item] and item:sub(1, #prefix) == prefix then
      result[#result + 1] = item
      seen[item] = true
    end
  end
  table.sort(result)
  return result
end

function M.shutdown()
  for _, agent in ipairs(M.list()) do
    agent:close(true)
  end
end

return M
