local M = {}
local defaults = {
  cmd = { "pi" },
  args = {},
  draft_height = 6,
  completion = true,
  mappings = {},
}
local config = vim.deepcopy(defaults)
local sessions, next_id, last = {}, 0, nil

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  vim.validate("cmd", config.cmd, "table")
  vim.validate("args", config.args, "table")
  vim.validate("draft_height", config.draft_height, "number")
  vim.validate("completion", config.completion, "boolean")
  vim.validate("mappings", config.mappings, "table")
  assert(
    #config.cmd > 0 and config.draft_height >= 1,
    "dyadic: cmd must not be empty and draft_height must be positive"
  )
end

function M.get(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  for _, session in pairs(sessions) do
    if session.buf == buf or session.draft == buf then
      return session
    end
  end
end

function M.list()
  local result = {}
  for _, session in pairs(sessions) do
    result[#result + 1] = session
  end
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

function M.open()
  next_id = next_id + 1
  local session = require("dyadic.session").new(next_id, vim.deepcopy(config), function(closed)
    sessions[closed.id] = nil
    if last == closed then
      last = M.list()[#M.list()]
    end
  end)
  sessions[session.id], last = session, session
  local group = vim.api.nvim_create_augroup("DyadicSession" .. session.id, { clear = true })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = session.buf,
    once = true,
    callback = function()
      session:close(true)
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end)
    end,
  })
  require("dyadic.view").show(session)
  return session
end

function M.show(session)
  session = session or M.get() or last
  if not session or session.closed then
    return M.open()
  end
  last = session
  require("dyadic.view").show(session)
  return session
end

function M.action(name)
  local session = M.get()
  if not session then
    vim.notify("Dyadic: this buffer is not a pi conversation or draft", vim.log.levels.WARN)
    return
  end
  if name == "submit" then
    session:submit()
  elseif name == "follow_up" then
    session:submit("followUp")
  elseif name == "abort" then
    session:abort()
  elseif name == "dequeue" then
    session:dequeue()
  elseif name == "close" then
    session:close()
  else
    session:action(name)
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
  if text == "sessions" then
    vim.ui.select(M.list(), {
      prompt = "Pi buffers",
      format_item = function(s)
        return string.format(
          "%s | %s | %s",
          s.state.sessionName or s.state.sessionId or ("pi " .. s.id),
          s.cwd,
          s.status
        )
      end,
    }, function(s)
      if s and not s.closed then
        M.show(s)
      end
    end)
    return
  end
  local session = M.get()
  if not session then
    vim.notify("Dyadic: open a conversation first with :Dyadic", vim.log.levels.WARN)
    return
  end
  if text == "input" then
    local wins = vim.fn.win_findbuf(session.draft)
    if #wins == 0 then
      M.show(session)
      wins = vim.fn.win_findbuf(session.draft)
    end
    if wins[1] then
      vim.api.nvim_set_current_win(wins[1])
    end
  elseif text == "abort" or text == "close" or text == "submit" or text == "follow_up" or text == "dequeue" then
    M.action(text)
  else
    require("dyadic.commands").run(session, "/" .. text)
  end
end

function M.complete(prefix)
  local items = { "new", "show", "sessions", "input", "abort", "close", "submit", "follow_up", "dequeue" }
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
  for _, session in ipairs(M.list()) do
    session:close(true)
  end
end

return M
