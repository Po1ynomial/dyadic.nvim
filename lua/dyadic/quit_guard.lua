-- The quit guard: while any agent has work in progress, quitting Neovim is refused like
-- quitting with unsaved changes. QuitPre cannot cancel a quit, so a hidden 'acwrite' buffer
-- that never gets written stays modified while work is in progress; :qa! still quits.
local M = {}
local api = vim.api

local NAME = "dyadic://agent-working"
local buf

local function busy_agents()
  local busy = {}
  for _, agent in ipairs(require("dyadic").list()) do
    if not agent.closed and (agent.active or (agent.bash and agent.bash.running) or agent.state.isCompacting) then
      busy[#busy + 1] = agent
    end
  end
  return busy
end

local function guard_buffer()
  if buf and api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  api.nvim_buf_set_name(buf, NAME)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "An agent is working. Wait, or :qa! to quit anyway." })
  vim.bo[buf].modifiable = false
  -- "Writing" changes nothing, so :wqa and :xa are refused too.
  api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = function() end })
  return buf
end

function M.update()
  local active = #busy_agents() > 0
  if active then
    vim.bo[guard_buffer()].modified = true
  elseif buf and api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modified = false
  end
end

-- Whether quitting Neovim now would be refused for unsaved changes, including the guard's.
function M.blocks_exit()
  for _, info in ipairs(vim.fn.getbufinfo({ bufmodified = 1 })) do
    local buftype = vim.bo[info.bufnr].buftype
    if buftype == "" or buftype == "acwrite" then
      return true
    end
  end
  return false
end

-- Explain the refusal when a :q would exit Neovim. `others` counts the windows that would
-- stay open after the quit.
function M.explain(others)
  if others > 0 or #api.nvim_list_tabpages() > 1 then
    return
  end
  local busy = busy_agents()
  if #busy == 0 then
    return
  end
  local names = vim.tbl_map(function(agent)
    return tostring(agent.id)
  end, busy)
  vim.notify(
    string.format("Dyadic: pi is working in agent %s; wait, or :qa! to quit anyway", table.concat(names, ", ")),
    vim.log.levels.WARN
  )
end

return M
