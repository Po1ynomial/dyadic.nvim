-- Completion items for the composer, shared by the omnifunc and the blink.cmp source.
--
-- Two places complete: a slash command and its arguments on the draft's first line, where
-- pi reads commands, and an `@` path reference at the start of a word. Items are neutral
-- tables; each front end turns them into its own items:
--   word   the text that replaces the completed token
--   label  what the menu shows
--   kind   builtin, extension, prompt, skill, setting, value, model, file, or directory
--   menu   the menu's right column
--   doc    documentation, Markdown
--   sort   the order when scores tie
--   path   a file or directory to preview
--   reshow whether arguments follow, so the menu opens again after accepting
local Bridge = require("dyadic.bridge")
local Commands = require("dyadic.commands")

local api = vim.api
local M = {}

-- At most this many paths are listed for `@`.
M.LIMIT = 20000
-- The listers tried in order; without any of them, Neovim walks the directory itself.
M.listers = { "fd", "rg" }
local commands = {
  fd = function(limit)
    local cmd = { "fd", "--type", "f", "--type", "d", "--hidden", "--exclude", ".git" }
    return vim.list_extend(cmd, { "--color", "never", "--max-results", tostring(limit) })
  end,
  rg = function()
    return { "rg", "--files", "--hidden", "--glob", "!.git", "--color", "never" }
  end,
}
-- Lines a file preview shows.
local PREVIEW_LINES = 30
-- At most this much of a file is read for its preview.
local PREVIEW_BYTES = 8192

-- The agent whose composer `buf` is, when completion is on for it.
function M.agent(buf)
  local agent = require("dyadic.view").agent_of(buf)
  if agent and agent.composer_buf == buf and not agent.closed and agent.config.completion ~= false then
    return agent
  end
end

local function at_word_start(text, index)
  return index == 1 or text:sub(index - 1, index - 1):match("%s") ~= nil
end

-- What the text before the cursor completes, or nil. `row` is 1-based and `col` is the
-- cursor's 0-based byte column. `start` is the 0-based column the completed token starts at.
function M.context(line, row, col)
  local before = line:sub(1, col)
  if row == 1 and before:sub(1, 1) == "/" then
    if before:match("^/%S*$") then
      return { kind = "command", start = 0, query = before }
    end
    local command, rest = before:match("^/(%S+)%s+(.*)$")
    if command == "settings" then
      local name = rest:match("^%S*$")
      if name then
        return { kind = "setting", start = col - #name, query = name }
      end
      local key, value = rest:match("^(%S+)%s+(%S*)$")
      if key then
        return { kind = "value", setting = key, start = col - #value, query = value }
      end
    elseif command == "thinking" or command == "model" then
      local argument = rest:match("^%S*$")
      if argument then
        return { kind = command, start = col - #argument, query = argument }
      end
    end
  end
  local at, quoted = before:match('()@"([^"]*)$')
  if at and at_word_start(before, at) then
    return { kind = "path", start = at - 1, query = quoted, quoted = true }
  end
  local query
  at, query = before:match("()@(%S*)$")
  if at and at_word_start(before, at) then
    return { kind = "path", start = at - 1, query = query }
  end
end

local function command_items(agent)
  local items, seen = {}, {}
  for _, command in ipairs(Commands.builtins) do
    seen[command.name] = true
    items[#items + 1] = {
      word = "/" .. command.name .. (command.hint and " " or ""),
      label = "/" .. command.name,
      kind = "builtin",
      menu = command.hint,
      doc = command.description,
      sort = "1 " .. command.name,
      reshow = command.name == "model" or command.name == "thinking" or command.name == "settings",
    }
  end
  local order = { extension = 2, prompt = 3, skill = 4 }
  for _, command in ipairs(agent.commands or {}) do
    local name = type(command) == "table" and command.name or command
    if type(name) == "string" then
      name = name:gsub("^/", "")
    end
    if type(name) == "string" and name ~= Bridge.command_name and not seen[name] then
      seen[name] = true
      local source = type(command) == "table" and command.source or nil
      local doc = type(command) == "table" and type(command.description) == "string" and command.description or nil
      local info = type(command) == "table" and type(command.sourceInfo) == "table" and command.sourceInfo or {}
      if type(info.path) == "string" and info.path ~= "" then
        doc = (doc and doc .. "\n\n" or "") .. "`" .. vim.fn.fnamemodify(info.path, ":~") .. "`"
      end
      items[#items + 1] = {
        word = "/" .. name,
        label = "/" .. name,
        kind = order[source] and source or "extension",
        menu = source,
        doc = doc,
        sort = (order[source] or 2) .. " " .. name,
      }
    end
  end
  return items
end

local function setting_items(agent)
  local items = {}
  for index, name in ipairs(Commands.settings.names) do
    local current = Commands.settings.current(agent, name)
    items[#items + 1] = {
      word = name .. " ",
      label = name,
      kind = "setting",
      menu = current,
      doc = Commands.settings.descriptions[name],
      sort = string.format("%02d", index),
      reshow = true,
    }
  end
  return items
end

local function value_items(agent, setting)
  local items = {}
  local current = Commands.settings.current(agent, setting)
  for index, value in ipairs(Commands.settings.values(setting) or {}) do
    items[#items + 1] = {
      word = value,
      label = value,
      kind = "value",
      menu = value == current and "current" or nil,
      sort = string.format("%02d", index),
    }
  end
  return items
end

local function level_items(agent, levels)
  local items = {}
  local current = (agent.state or {}).thinkingLevel
  for index, level in ipairs(levels) do
    items[#items + 1] = {
      word = level,
      label = level,
      kind = "value",
      menu = level == current and "current" or nil,
      sort = string.format("%02d", index),
    }
  end
  return items
end

local function count(value)
  if type(value) ~= "number" then
    return nil
  end
  if value >= 1000000 then
    return (string.format("%.1f", value / 1000000):gsub("%.0$", "")) .. "M"
  elseif value >= 1000 then
    return (string.format("%.1f", value / 1000):gsub("%.0$", "")) .. "k"
  end
  return tostring(value)
end

local function model_items(agent, models)
  local items = {}
  local current = (agent.state or {}).model or {}
  for _, model in ipairs(models) do
    if type(model) == "table" and model.provider and model.id then
      local lines = {}
      if type(model.name) == "string" then
        lines[#lines + 1] = "**" .. model.name .. "**"
        lines[#lines + 1] = ""
      end
      if count(model.contextWindow) then
        lines[#lines + 1] = "- Context window: " .. count(model.contextWindow) .. " tokens"
      end
      if count(model.maxTokens) then
        lines[#lines + 1] = "- Maximum output: " .. count(model.maxTokens) .. " tokens"
      end
      if model.reasoning ~= nil then
        lines[#lines + 1] = "- Reasoning: " .. (model.reasoning == true and "yes" or "no")
      end
      if type(model.input) == "table" then
        lines[#lines + 1] = "- Images: " .. (vim.tbl_contains(model.input, "image") and "yes" or "no")
      end
      local key = model.provider .. "/" .. model.id
      local is_current = current.provider == model.provider and current.id == model.id
      items[#items + 1] = {
        word = key,
        label = key,
        kind = "model",
        menu = type(model.name) == "string" and model.name or nil,
        doc = #lines > 0 and table.concat(lines, "\n") or nil,
        sort = (is_current and "0 " or "1 ") .. key,
      }
    end
  end
  return items
end

-- Paths below `cwd`, relative, with a trailing slash on directories.
local function walk(cwd, limit)
  local paths = {}
  local ok = pcall(function()
    for name, type in
      vim.fs.dir(cwd, {
        depth = math.huge,
        skip = function(dir)
          return vim.fs.basename(dir) ~= ".git"
        end,
      })
    do
      if #paths >= limit then
        break
      end
      if vim.fs.basename(name) ~= ".git" then
        paths[#paths + 1] = type == "directory" and name .. "/" or name
      end
    end
  end)
  return ok and paths or {}
end

local function parse(stdout, limit)
  local paths = {}
  for line in vim.gsplit(stdout or "", "\n", { plain = true, trimempty = true }) do
    if #paths >= limit then
      break
    end
    paths[#paths + 1] = (line:gsub("^%./", ""))
  end
  return paths
end

local function available_listers()
  return vim.tbl_filter(function(name)
    return commands[name] and vim.fn.executable(name) == 1
  end, M.listers)
end

-- List the paths below `cwd`; `callback` runs on the main loop. Synchronously when `sync`.
local function list(cwd, sync, callback)
  local listers = available_listers()
  local function try(index)
    local name = listers[index]
    if not name then
      callback(walk(cwd, M.LIMIT))
      return
    end
    local ok, process =
      pcall(vim.system, commands[name](M.LIMIT), { cwd = cwd, text = true }, not sync and function(result)
        vim.schedule(function()
          if result.code == 0 then
            callback(parse(result.stdout, M.LIMIT))
          else
            try(index + 1)
          end
        end)
      end or nil)
    if not ok then
      try(index + 1)
    elseif sync then
      local result = process:wait(5000)
      if result.code == 0 then
        callback(parse(result.stdout, M.LIMIT))
      else
        try(index + 1)
      end
    end
  end
  try(1)
end

-- The listing for `agent`'s cwd, kept until the composer leaves Insert mode.
local function files(agent, sync, callback)
  local cache = agent._completion_files
  if cache and cache.cwd == agent.cwd then
    if cache.paths then
      callback(cache.paths)
      return
    elseif not sync then
      table.insert(cache.waiting, callback)
      return
    end
  end
  if sync then
    list(agent.cwd, true, function(paths)
      agent._completion_files = { cwd = agent.cwd, paths = paths, waiting = {} }
      callback(paths)
    end)
    return
  end
  cache = { cwd = agent.cwd, waiting = { callback } }
  agent._completion_files = cache
  list(agent.cwd, false, function(paths)
    if agent._completion_files == cache then
      cache.paths = paths
    end
    for _, waiting in ipairs(cache.waiting) do
      waiting(paths)
    end
    cache.waiting = {}
  end)
end

-- Forget the listing, so the next `@` sees new files.
function M.forget(agent)
  agent._completion_files = nil
end

local function quote(path, quoted)
  if quoted or path:find("%s") then
    return '@"' .. path .. '"'
  end
  return "@" .. path
end

local function path_items(agent, paths, ctx, limit)
  local matches = paths
  if ctx.query ~= "" then
    matches = limit and vim.fn.matchfuzzy(paths, ctx.query, { limit = limit }) or vim.fn.matchfuzzy(paths, ctx.query)
  elseif limit and #paths > limit then
    matches = vim.list_slice(paths, 1, limit)
  end
  local items = {}
  for _, path in ipairs(matches) do
    local directory = path:sub(-1) == "/"
    -- After accepting a directory, blink.cmp opens the menu again on its `/`; the
    -- directory itself is no choice then.
    if path ~= ctx.query then
      items[#items + 1] = {
        word = quote(path, ctx.quoted),
        label = path,
        kind = directory and "directory" or "file",
        sort = (directory and "0 " or "1 ") .. path,
        path = vim.fs.joinpath(agent.cwd, path),
      }
    end
  end
  return items
end

local function by_sort(a, b)
  return a.sort < b.sort
end

-- Narrow `items` to the typed `query`: by prefix for the omnifunc, as Vim's completion
-- expects, or fuzzily for blink.cmp, which then ranks the rest itself.
local function narrow(items, query, match)
  if query == "" then
    return items
  end
  if match == "fuzzy" then
    return vim.fn.matchfuzzy(items, query, { key = "label" })
  end
  return vim.tbl_filter(function(item)
    return item.label:sub(1, #query) == query
  end, items)
end

-- Collect the items for `ctx` and pass them to `callback`, sorted by `sort`.
-- opts.sync: answer now, from what dyadic already has; skip what needs a request to pi.
-- opts.match: "prefix" or "fuzzy".
-- opts.limit: at most this many paths.
function M.items(agent, ctx, opts, callback)
  local function done(items)
    items = narrow(items, ctx.kind == "path" and "" or ctx.query, opts.match)
    table.sort(items, by_sort)
    callback(items)
  end
  if ctx.kind == "command" then
    done(command_items(agent))
  elseif ctx.kind == "setting" then
    done(setting_items(agent))
  elseif ctx.kind == "value" then
    done(value_items(agent, ctx.setting))
  elseif ctx.kind == "thinking" then
    if opts.sync then
      -- The levels depend on the model; offer only levels pi reported.
      done(level_items(agent, agent.available_thinking_levels or {}))
      return
    end
    agent:request("get_available_thinking_levels", {}, function(err, data)
      if not err and type(data) == "table" and type(data.levels) == "table" then
        agent.available_thinking_levels = data.levels
      end
      done(level_items(agent, agent.available_thinking_levels or {}))
    end)
  elseif ctx.kind == "model" then
    if opts.sync then
      done({})
      return
    end
    agent:request("get_available_models", {}, function(err, data)
      done(model_items(agent, not err and type(data) == "table" and data.models or {}))
    end)
  elseif ctx.kind == "path" then
    files(agent, opts.sync, function(paths)
      done(path_items(agent, paths, ctx, opts.limit))
    end)
  else
    callback({})
  end
end

-- Markdown previewing `path`: the start of a file, or a directory's size.
function M.preview(path)
  if vim.fn.isdirectory(path) == 1 then
    local entries = 0
    for _ in vim.fs.dir(path) do
      entries = entries + 1
    end
    return string.format("%d %s", entries, entries == 1 and "entry" or "entries")
  end
  local file = io.open(path, "rb")
  if not file then
    return "`" .. vim.fn.fnamemodify(path, ":~") .. "` cannot be read"
  end
  local head = file:read(PREVIEW_BYTES) or ""
  file:close()
  if head:find("\0", 1, true) then
    return "Binary file"
  end
  local lines = vim.split(head, "\r?\n")
  if #lines > PREVIEW_LINES or (#lines > 1 and #head == PREVIEW_BYTES) then
    -- Drop the line the read may have cut.
    lines = vim.list_slice(lines, 1, math.min(PREVIEW_LINES, #lines - 1))
  elseif lines[#lines] == "" then
    lines[#lines] = nil
  end
  local text = table.concat(lines, "\n")
  -- A fence longer than any backtick run in the text.
  local fence = "```"
  for run in text:gmatch("`+") do
    if #run >= #fence then
      fence = string.rep("`", #run + 1)
    end
  end
  local filetype = vim.filetype.match({ filename = path }) or ""
  return fence .. filetype .. "\n" .. text .. "\n" .. fence
end

-- 'omnifunc' of the composer. Paths match fuzzily, so Vim must not filter them by prefix.
local pending

function M.omnifunc(findstart, base)
  local agent = M.agent(api.nvim_get_current_buf())
  if not agent then
    return findstart == 1 and -3 or {}
  end
  if findstart == 1 then
    local cursor = api.nvim_win_get_cursor(0)
    pending = M.context(api.nvim_get_current_line(), cursor[1], cursor[2])
    return pending and pending.start or -3
  end
  local ctx = pending
  pending = nil
  if not ctx then
    return {}
  end
  if ctx.kind ~= "path" then
    ctx.query = base
  end
  local result = {}
  M.items(agent, ctx, { sync = true, match = "prefix", limit = 200 }, function(items)
    for _, item in ipairs(items) do
      local doc = item.doc
      if item.path then
        doc = vim.fn.fnamemodify(item.path, ":~")
      end
      result[#result + 1] = {
        word = item.word,
        abbr = item.label,
        menu = item.menu,
        info = doc,
        equal = item.path and 1 or nil,
      }
    end
  end)
  return result
end

local registered = false

-- Register the blink.cmp source for composers, once, when blink.cmp is available.
function M.register()
  if registered then
    return
  end
  registered = true
  local ok, blink = pcall(require, "blink.cmp")
  if not ok or type(blink) ~= "table" or not blink.add_source_provider or not blink.add_filetype_source then
    return
  end
  pcall(function()
    -- A source configured by hand keeps its id.
    local id
    for name, provider in pairs(require("blink.cmp.config").sources.providers) do
      if provider.module == "dyadic.completion.blink" then
        id = name
      end
    end
    if not id then
      id = "dyadic"
      blink.add_source_provider(id, { name = "Dyadic", module = "dyadic.completion.blink" })
    end
    blink.add_filetype_source("dyadic_composer", id)
  end)
end

local group = api.nvim_create_augroup("DyadicCompletion", { clear = true })

-- Set up completion in `agent`'s composer buffer `buf`.
function M.attach(agent, buf)
  vim.bo[buf].omnifunc = "v:lua.require'dyadic.completion'.omnifunc"
  api.nvim_create_autocmd("InsertEnter", { group = group, buffer = buf, callback = M.register })
  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = buf,
    callback = function()
      M.forget(agent)
    end,
  })
end

return M
