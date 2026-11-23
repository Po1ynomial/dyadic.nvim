-- Saved pi sessions: finding and reading session files without pi.
-- `where` describes whose sessions: { cwd = directory, args = pi arguments,
-- session_file = the active session's file, if any }.
local M = {}
local uv = vim.uv
local windows = vim.fn.has("win32") == 1

function M.resolve(path, cwd)
  if windows and not path:find("\\", 1, true) and path:sub(1, 2) ~= "//" then
    local drive, tail = path:match("^/([a-z])/(.*)$")
    if not drive then
      drive, tail = path:match("^/mnt/([a-z])/(.*)$")
    end
    if not drive then
      drive, tail = path:match("^/cygdrive/([a-z])/(.*)$")
    end
    if not drive then
      drive = path:match("^/([a-z])$") or path:match("^/mnt/([a-z])$") or path:match("^/cygdrive/([a-z])$")
    end
    if drive then
      path = drive:upper() .. ":/" .. (tail or "")
    end
  end
  if path == "~" then
    path = uv.os_homedir()
  elseif path:sub(1, 2) == "~/" or windows and path:sub(1, 2) == "~\\" then
    path = vim.fs.joinpath(uv.os_homedir(), path:sub(3))
  end
  if path:match("^file://") then
    path = vim.uri_to_fname(path)
  end
  local absolute = path:sub(1, 1) == "/" or windows and (path:sub(1, 1) == "\\" or path:match("^%a:[/\\]"))
  if not absolute then
    path = vim.fs.joinpath(cwd, path)
  end
  return vim.fs.normalize(path)
end
local resolve = M.resolve

local function decode(text)
  local ok, value = pcall(vim.json.decode, text)
  if ok and type(value) == "table" then
    return value
  end
end

local function settings(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return {}
  end
  local stat = uv.fs_fstat(fd)
  local text = stat and stat.size <= 1024 * 1024 and uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not text then
    return {}
  end
  return decode(text:gsub("^\239\187\191", "")) or {}
end

-- The header of a session file, its first line, or nil when the file has none yet.
function M.header(path)
  local fd = type(path) == "string" and path ~= "" and uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local text = uv.fs_read(fd, 65536, 0) or ""
  uv.fs_close(fd)
  local header = decode((text:match("^([^\n]*)\n") or text):gsub("^\239\187\191", ""))
  if header and header.type == "session" and type(header.id) == "string" and type(header.cwd) == "string" then
    return header
  end
end

-- The directory of `where`'s sessions, and the root that holds every directory's.
-- Pi resolves all sessionDir values from its process cwd, not the settings file.
-- Its default grouping removes one leading separator and replaces /, \\, and :.
function M.storage(where)
  local cwd = where.cwd
  local agent_env = vim.env.PI_CODING_AGENT_DIR
  local agent_dir = resolve(agent_env and agent_env ~= "" and agent_env or "~/.pi/agent", cwd)
  local args = where.args or {}
  local explicit
  for i, arg in ipairs(args) do
    if arg == "--session-dir" then
      explicit = args[i + 1]
    end
  end
  local configured = explicit or vim.env.PI_CODING_AGENT_SESSION_DIR
  if not configured or configured == "" then
    local project = settings(vim.fs.joinpath(cwd, ".pi", "settings.json"))
    local user = settings(vim.fs.joinpath(agent_dir, "settings.json"))
    configured = project.sessionDir or user.sessionDir
  end
  local root = vim.fs.joinpath(agent_dir, "sessions")
  local grouped = "--" .. resolve(cwd, cwd):gsub("^[/\\]", ""):gsub("[/\\:]", "-") .. "--"
  local directory = configured and configured ~= "" and resolve(configured, cwd) or vim.fs.joinpath(root, grouped)
  local current = where.session_file
  if type(current) == "string" and current ~= "" then
    directory = vim.fs.dirname(resolve(current, cwd))
  end
  return directory, configured and configured ~= "" and directory or root
end

-- Session files of `where`'s directory, or with `all` of every directory, newest first.
function M.files(where, all)
  local directory, root = M.storage(where)
  local found = {}
  local function scan(dir, recursive)
    local handle = uv.fs_scandir(dir)
    if not handle then
      return
    end
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local path = vim.fs.joinpath(dir, name)
      if kind == "link" then
        local stat = uv.fs_stat(path)
        kind = stat and stat.type or kind
      end
      if kind == "directory" and recursive then
        scan(path, false)
      elseif kind == "file" and name:match("%.jsonl$") then
        local stat = uv.fs_stat(path)
        found[#found + 1] = { path = path, modified = stat and stat.mtime.sec or 0 }
      end
    end
  end
  scan(all and root or directory, all)
  table.sort(found, function(a, b)
    if a.modified == b.modified then
      return a.path > b.path
    end
    return a.modified > b.modified
  end)
  return found
end

local function same_dir(a, b, cwd)
  return resolve(a, cwd) == resolve(b, cwd)
end

-- Find a session by full or partial ID as pi's --session does: an exact ID in this
-- directory, a prefix in it, then the same in every directory. Only headers are read.
-- Returns { path, cwd, here }, where `here` is false for another directory's session.
function M.find(id, where)
  local function search(all)
    local headers = {}
    for _, file in ipairs(M.files(where, all)) do
      local header = M.header(file.path)
      if header and (all or same_dir(header.cwd, where.cwd, where.cwd)) then
        headers[#headers + 1] = { path = file.path, cwd = header.cwd, id = header.id }
      end
    end
    for _, item in ipairs(headers) do
      if item.id == id then
        return item
      end
    end
    for _, item in ipairs(headers) do
      if item.id:sub(1, #id) == id then
        return item
      end
    end
  end
  local here = search(false)
  if here then
    return { path = here.path, cwd = here.cwd, here = true }
  end
  local other = search(true)
  if other then
    return { path = other.path, cwd = other.cwd, here = same_dir(other.cwd, where.cwd, where.cwd) }
  end
end

-- Read one session file's details in a worker thread, as pi's session list does
-- (buildSessionInfo in core/session-manager.js). Runs from string.dump, so it may use only
-- its arguments, `vim.uv`, and `vim.json`. Returns the path and the details as JSON, or "".
local function read_details(path, chars)
  local uv, json = vim.uv, vim.json
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return path, ""
  end
  local stat = uv.fs_fstat(fd)
  local info = { path = path, count = 0 }
  local header, activity
  local function text_of(content)
    if type(content) == "string" then
      return content
    end
    local parts = {}
    for _, block in ipairs(type(content) == "table" and content or {}) do
      if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      end
    end
    return table.concat(parts, " ")
  end
  -- Whitespace runs become one space; long text is cut at a character boundary.
  local function cut(text)
    text = text:gsub("%s+", " "):gsub("^ ", "")
    if #text <= chars then
      return text
    end
    local stop = chars
    while stop > 0 and (text:byte(stop + 1) or 0) >= 0x80 and text:byte(stop + 1) < 0xC0 do
      stop = stop - 1
    end
    return text:sub(1, stop)
  end
  local function decode(line)
    local ok, value = pcall(json.decode, line, { luanil = { object = true, array = true } })
    return ok and type(value) == "table" and value or nil
  end
  -- Returns false to stop at a file that is not a session.
  local function line(text)
    if not header then
      header = decode((text:gsub("^\239\187\191", "")))
      if not header or header.type ~= "session" or type(header.id) ~= "string" then
        return false
      end
      return true
    end
    -- Pi writes `type` first, so most lines need no decoding to be skipped.
    local entry
    local kind = text:match('^{"type":"([%w_]+)"')
    if not kind then
      entry = decode(text)
      kind = entry and entry.type
    end
    if kind == "session_info" then
      entry = entry or decode(text)
      local name = entry and type(entry.name) == "string" and entry.name:match("^%s*(.-)%s*$") or ""
      info.name = name ~= "" and name or nil
    elseif kind == "model_change" then
      entry = entry or decode(text)
      if entry and entry.modelId then
        info.model = (entry.provider and entry.provider .. "/" or "") .. entry.modelId
      end
    elseif kind == "thinking_level_change" then
      entry = entry or decode(text)
      info.thinking = entry and entry.thinkingLevel or info.thinking
    end
    if kind ~= "message" then
      return true
    end
    info.count = info.count + 1
    -- Tool results can be large and carry no text the picker shows; count them only.
    local role = not entry and text:sub(1, 400):match('"message":{"role":"(%w+)"')
    if role and role ~= "user" and role ~= "assistant" then
      return true
    end
    entry = entry or decode(text)
    local message = entry and entry.message
    if type(message) ~= "table" or (message.role ~= "user" and message.role ~= "assistant") then
      return true
    end
    local time = type(message.timestamp) == "number" and message.timestamp / 1000 or nil
    if time and time > 0 then
      activity = math.max(activity or 0, time)
    end
    if message.role == "assistant" and type(message.model) == "string" then
      info.model = (type(message.provider) == "string" and message.provider .. "/" or "") .. message.model
    end
    local text_content = text_of(message.content)
    if text_content:find("%S") then
      if message.role == "user" then
        info.first = info.first or cut(text_content)
        info.last_user = cut(text_content)
      else
        info.last_assistant = cut(text_content)
      end
    end
    return true
  end
  local pending, offset, valid = "", 0, true
  while valid do
    local chunk = uv.fs_read(fd, 262144, offset)
    if not chunk or chunk == "" then
      break
    end
    offset = offset + #chunk
    local start = 1
    while valid do
      local stop = chunk:find("\n", start, true)
      if not stop then
        pending = pending .. chunk:sub(start)
        break
      end
      local text = pending .. chunk:sub(start, stop - 1)
      pending, start = "", stop + 1
      if text ~= "" then
        valid = line(text)
      end
    end
  end
  if valid and pending ~= "" then
    valid = line(pending)
  end
  uv.fs_close(fd)
  if not valid or not header then
    return path, ""
  end
  info.id, info.cwd, info.created = header.id, type(header.cwd) == "string" and header.cwd or "", header.timestamp
  info.parent = type(header.parentSession) == "string" and header.parentSession or nil
  info.modified = activity or (stat and stat.mtime.sec or 0)
  return path, json.encode(info)
end

-- Session details by path, kept while a file's size and modification time stay the same;
-- session files are append-only.
local details_cache = {}
local THREADS = 4
local TEXT_CHARS = 500

local function version_of(path)
  local stat = uv.fs_stat(path)
  return stat and table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
end

-- Load the details of `paths` in worker threads. `on_item(details)` runs on the main loop
-- for each session, at once for cached ones; `on_done()` runs after the last. Returns a
-- handle whose :cancel() stops loading files not started yet.
function M.load(paths, on_item, on_done)
  local handle = { cancelled = false }
  function handle:cancel()
    self.cancelled = true
  end
  local queue = {}
  for _, path in ipairs(paths) do
    local version = version_of(path)
    local hit = details_cache[path]
    if version and hit and hit.version == version then
      if hit.details then
        on_item(hit.details)
      end
    elseif version then
      queue[#queue + 1] = { path = path, version = version }
    end
  end
  local next_index, running, versions = 1, 0, {}
  local function finished()
    if running == 0 and (next_index > #queue or handle.cancelled) and not handle.done then
      handle.done = true
      if on_done then
        on_done()
      end
    end
  end
  local start
  local function after(path, result)
    running = running - 1
    local details = result ~= "" and vim.json.decode(result) or false
    if details then
      details.modified = tonumber(details.modified) or 0
    end
    details_cache[path] = { version = versions[path], details = details }
    if details and not handle.cancelled then
      on_item(details)
    end
    start()
    finished()
  end
  -- The after callback runs in a fast event, where most of the API is off limits.
  local work = uv.new_work(read_details, function(path, result)
    vim.schedule(function()
      after(path, result)
    end)
  end)
  start = function()
    while not handle.cancelled and running < THREADS and next_index <= #queue do
      local item = queue[next_index]
      next_index, running = next_index + 1, running + 1
      versions[item.path] = item.version
      work:queue(item.path, TEXT_CHARS)
    end
  end
  start()
  finished()
  return handle
end

return M
