local M = {}
local defaults = {
  cmd = { "pi" },
  args = {},
  draft_height = 6,
  completion = true,
  mappings = {},
  layout = nil,
}
local config = vim.deepcopy(defaults)
local agents, next_id, last = {}, 0, nil

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  vim.validate("cmd", config.cmd, "table")
  vim.validate("args", config.args, "table")
  vim.validate("draft_height", config.draft_height, "number")
  vim.validate("completion", config.completion, "boolean")
  vim.validate("mappings", config.mappings, "table")
  vim.validate("layout", config.layout, "function", true)
  assert(
    #config.cmd > 0 and config.draft_height >= 1,
    "dyadic: cmd must not be empty and draft_height must be positive"
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

function M.action(name)
  local agent = M.get()
  if not agent then
    vim.notify("Dyadic: this buffer is not a dyadic history or composer", vim.log.levels.WARN)
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
  if text == "" or text == "new" then
    M.open()
    return
  end
  if text == "show" then
    M.show()
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
  local agent = M.get()
  if not agent then
    vim.notify("Dyadic: open an agent first with :Dyadic", vim.log.levels.WARN)
    return
  end
  if text == "composer" then
    local wins = vim.fn.win_findbuf(agent.composer_buf)
    if #wins == 0 then
      M.show(agent)
      wins = vim.fn.win_findbuf(agent.composer_buf)
    end
    if wins[1] then
      vim.api.nvim_set_current_win(wins[1])
    end
  elseif text == "abort" or text == "close" or text == "submit" or text == "follow_up" or text == "dequeue" then
    M.action(text)
  else
    require("dyadic.commands").run(agent, "/" .. text)
  end
end

function M.complete(prefix)
  local items = { "new", "show", "agents", "composer", "abort", "close", "submit", "follow_up", "dequeue" }
  vim.list_extend(items, require("dyadic.commands").names)
  local result, seen = {}, {}
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
