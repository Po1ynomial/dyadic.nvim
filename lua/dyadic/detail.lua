-- Scratch buffers showing one history item in full: a tool call, thinking block, shell
-- command, summary, or error. Each item gets its own buffer, which keeps updating while it
-- is visible and is wiped when hidden.
local M = {}
local api = vim.api
local text = require("dyadic.text")
local History = require("dyadic.history")
local header_ns = api.nvim_create_namespace("dyadic_detail")

local function filetype_for(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return vim.filetype.match({ filename = path }) or ""
end

local function output_of(result)
  if type(result) ~= "table" then
    return ""
  end
  return text.content_text(result.content)
end

local function tool_content(item)
  local live = item.live or {}
  local result = item.result or live.result or live.partialResult
  local args = type(item.args) == "table" and item.args or {}
  local status = History.tool_status(item)
  local header = { (item.name or "tool") .. " · " .. status }
  if live.durationMs then
    header[1] = header[1] .. string.format(" · %dms", live.durationMs)
  end
  local output = output_of(result)
  local details = type(result) == "table" and result.details or nil
  local name = item.name
  if name == "bash" and type(args.command) == "string" then
    for _, line in ipairs(text.lines_of(args.command)) do
      header[#header + 1] = "$ " .. line
    end
    return { header = header, filetype = "", lines = text.lines_of(output ~= "" and output or "(no output)") }
  end
  if name == "edit" and type(details) == "table" and type(details.diff) == "string" then
    header[#header + 1] = tostring(args.path or "")
    return { header = header, filetype = "diff", lines = text.lines_of(details.diff) }
  end
  if name == "read" and output ~= "" then
    header[#header + 1] = tostring(args.path or "")
    return { header = header, filetype = filetype_for(args.path), lines = text.lines_of(output) }
  end
  if name == "write" and type(args.content) == "string" then
    header[#header + 1] = tostring(args.path or "")
    return { header = header, filetype = filetype_for(args.path), lines = text.lines_of(args.content) }
  end
  local lines = { "Arguments:" }
  vim.list_extend(lines, text.lines_of(text.describe(item.args)))
  if output ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Output:"
    vim.list_extend(lines, text.lines_of(output))
  end
  if details ~= nil and details ~= vim.NIL then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Details:"
    vim.list_extend(lines, text.lines_of(text.describe(details)))
  end
  return { header = header, filetype = "", lines = lines }
end

-- Content for an item: header lines (virtual), filetype, and buffer lines.
function M.content(item)
  if item.kind == "tool" then
    return tool_content(item)
  elseif item.kind == "thinking" then
    return {
      header = { "Thinking" },
      filetype = "markdown",
      lines = item.redacted and { "[Redacted]" } or text.lines_of(item.thinking),
    }
  elseif item.kind == "bash" then
    local message = item.message or {}
    local header = {}
    for _, line in ipairs(text.lines_of(message.command or "")) do
      header[#header + 1] = "$ " .. line
    end
    if item.running then
      header[#header + 1] = "running"
    elseif message.exitCode ~= nil and message.exitCode ~= vim.NIL then
      header[#header + 1] = "exit " .. tostring(message.exitCode)
    end
    if message.truncated and message.fullOutputPath then
      header[#header + 1] = "full output: " .. text.clean(message.fullOutputPath)
    end
    local output = message.output or ""
    return { header = header, filetype = "", lines = text.lines_of(output ~= "" and output or "(no output)") }
  elseif item.kind == "summary" then
    return { header = { item.label or "Summary" }, filetype = "markdown", lines = text.lines_of(item.message.summary) }
  elseif item.kind == "error" then
    return { header = { "Error" }, filetype = "", lines = text.lines_of(item.message) }
  end
end

local function visible(buf)
  return #vim.fn.win_findbuf(buf) > 0
end

local function update(agent, key, buf)
  local item = agent._view.model and agent._view.model.items[key]
  if not item then
    return
  end
  local content = M.content(item)
  if not content then
    return
  end
  if vim.bo[buf].filetype ~= content.filetype then
    vim.bo[buf].filetype = content.filetype
  end
  local old = api.nvim_buf_get_lines(buf, 0, -1, false)
  if not vim.deep_equal(old, content.lines) then
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end
  api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
  local virt = {}
  for _, line in ipairs(content.header or {}) do
    virt[#virt + 1] = { { text.one_line(line), "DyadicRole" } }
  end
  if #virt > 0 then
    api.nvim_buf_set_extmark(buf, header_ns, 0, 0, { virt_lines = virt, virt_lines_above = true })
  end
  return #virt
end

-- Refresh every visible detail buffer of an agent.
function M.refresh(agent)
  for key, buf in pairs(agent._view.details) do
    if api.nvim_buf_is_valid(buf) and visible(buf) then
      update(agent, key, buf)
    end
  end
end

function M.any_visible(agent)
  for _, buf in pairs(agent._view.details) do
    if api.nvim_buf_is_valid(buf) and visible(buf) then
      return true
    end
  end
  return false
end

function M.open(agent, key)
  local item = agent._view.model and agent._view.model.items[key]
  if not item or not M.content(item) then
    return false
  end
  local buf = agent._view.details[key]
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    agent._view.details[key] = buf
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].undolevels = -1
    vim.bo[buf].modifiable = false
    api.nvim_buf_set_name(buf, "dyadic://" .. agent.id .. "/detail/" .. key:gsub("[^%w%-_.:]", "_"))
    vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true, desc = "Dyadic close details" })
    api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        if agent._view.details[key] == buf then
          agent._view.details[key] = nil
        end
      end,
    })
  end
  local header = update(agent, key, buf) or 0
  local win = vim.fn.win_findbuf(buf)[1]
  if win then
    api.nvim_set_current_win(win)
  else
    win = api.nvim_open_win(buf, true, { split = "below", win = 0 })
    vim.wo[win].wrap = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    -- Virtual lines above line 1 show only with filler rows at the top of the view.
    vim.fn.winrestview({ topline = 1, topfill = header })
  end
  return true
end

function M.dispose(agent)
  for _, buf in pairs(agent._view.details or {}) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  agent._view.details = {}
end

return M
