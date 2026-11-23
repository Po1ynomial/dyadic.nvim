-- Highlights of the composer's special tokens, drawn at redraw for the visible lines:
--   DyadicCommand    a command pi or dyadic runs, at the start of the draft
--   DyadicShell      the ! or !! of a shell command at the start of the draft
--   DyadicReference  an @path that exists
-- Only what will mean something is highlighted: /foo that is no command and @paths that
-- name nothing stay prose, and so do tokens inside Markdown code.
local Bridge = require("dyadic.bridge")
local Commands = require("dyadic.commands")

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("dyadic_tokens")
-- Above treesitter's highlights, which are 100.
local PRIORITY = 150
-- How long an answer to "does this path exist" is kept, in milliseconds.
local EXISTS_TTL = 2000
-- Punctuation that ends a sentence rather than a path: "see @a.lua."
local TRAILING = "[%.,;:!%?%)%]}'\"]$"

local function known_command(agent, name)
  if name == Bridge.command_name then
    return false
  end
  if vim.tbl_contains(Commands.names, name) then
    return true
  end
  return Commands.listed(agent, name)
end

-- Where the draft starts: pi and dyadic read commands from the trimmed draft.
local function draft_start(buf)
  local count = api.nvim_buf_line_count(buf)
  for row = 0, count - 1 do
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local col = line:find("%S")
    if col then
      return row, col - 1, line
    end
  end
end

-- The span of the command or shell marker that starts the draft, as { row, start, end,
-- group } with 0-based, end-exclusive columns; nil when the draft starts with neither.
function M.lead(agent, buf)
  local row, col, line = draft_start(buf)
  if not row then
    return nil
  end
  local rest = line:sub(col + 1)
  local name = rest:match("^/([^%s]+)")
  if name then
    if known_command(agent, name) then
      return { row, col, col + 1 + #name, "DyadicCommand" }
    end
    return nil
  end
  local marker = rest:match("^!!") or rest:match("^!")
  if marker then
    -- An empty shell command does not run.
    local text = table.concat(api.nvim_buf_get_lines(buf, row, -1, false), "\n"):sub(col + 1 + #marker)
    if text:find("%S") then
      return { row, col, col + #marker, "DyadicShell" }
    end
  end
end

local function resolve(agent, path)
  if path:sub(1, 1) == "~" then
    return vim.fn.expand(path)
  elseif path:sub(1, 1) == "/" then
    return path
  end
  return vim.fs.joinpath(agent.cwd or vim.fn.getcwd(), path)
end

local function exists(agent, path)
  local cache = agent._token_paths
  if not cache then
    cache = {}
    agent._token_paths = cache
  end
  local now = vim.uv.now()
  local known = cache[path]
  if known and now - known.time < EXISTS_TTL then
    return known.exists
  end
  local found = vim.uv.fs_stat(resolve(agent, path)) ~= nil
  cache[path] = { exists = found, time = now }
  return found
end

local function at_word_start(line, index)
  return index == 1 or line:sub(index - 1, index - 1):match("%s") ~= nil
end

-- Spans of the @paths in `line` that name something, as { start, end } with 0-based,
-- end-exclusive columns.
function M.references(agent, line)
  local spans = {}
  local index = 1
  while true do
    local at = line:find("@", index, true)
    if not at then
      break
    end
    index = at + 1
    if at_word_start(line, at) then
      local quoted = line:match('^@"([^"]+)"', at)
      if quoted then
        if exists(agent, quoted) then
          spans[#spans + 1] = { at - 1, at + #quoted + 2 }
        end
        index = at + #quoted + 3
      else
        local path = line:match("^@(%S+)", at) or ""
        index = at + 1 + #path
        while path ~= "" and not exists(agent, path) and path:find(TRAILING) do
          path = path:sub(1, -2)
        end
        if path ~= "" and exists(agent, path) then
          spans[#spans + 1] = { at - 1, at + #path }
        end
      end
    end
  end
  return spans
end

local CODE = {
  code_span = true,
  fenced_code_block = true,
  indented_code_block = true,
}

-- Whether (row, col) is inside Markdown code, as far as the parsed tree knows.
local function in_code(buf, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col }, ignore_injections = false })
  while ok and node do
    if CODE[node:type()] then
      return true
    end
    node = node:parent()
  end
  return false
end

local current = {}

local function mark(buf, row, start, finish, group)
  if in_code(buf, row, start) then
    return
  end
  api.nvim_buf_set_extmark(buf, ns, row, start, {
    end_col = finish,
    hl_group = group,
    priority = PRIORITY,
    ephemeral = true,
  })
end

api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf, toprow, botrow)
    local agent = require("dyadic.view").agent_of(buf)
    if not agent or agent.composer_buf ~= buf or agent.closed then
      return false
    end
    -- Tokens inside code are skipped; parse the visible range, inline code included.
    pcall(function()
      vim.treesitter.get_parser(buf):parse({ toprow, botrow + 1 })
    end)
    current = { agent = agent, lead = M.lead(agent, buf) }
  end,
  on_line = function(_, _, buf, row)
    local agent = current.agent
    if not agent then
      return
    end
    local lead = current.lead
    if lead and lead[1] == row then
      mark(buf, row, lead[2], lead[3], lead[4])
    end
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    if line:find("@", 1, true) then
      for _, span in ipairs(M.references(agent, line)) do
        mark(buf, row, span[1], span[2], "DyadicReference")
      end
    end
  end,
})

return M
