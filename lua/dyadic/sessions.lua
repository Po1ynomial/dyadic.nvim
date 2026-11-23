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

local function content_text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts, "\n")
end

-- Stream metadata without materializing an entire session or decoding tool output.
-- Oversized lines are skipped; a malformed header never becomes a selectable session.
local function metadata(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local info, first = { path = path, modified = stat and stat.mtime.sec or 0 }, true
  local pending, offset, skipping = "", 0, false
  local function line(text)
    if first then
      first = false
      local header = decode(text:gsub("^\239\187\191", ""))
      if not header or header.type ~= "session" or type(header.id) ~= "string" or type(header.cwd) ~= "string" then
        return false
      end
      info.id, info.cwd, info.timestamp = header.id, header.cwd, header.timestamp
    elseif text:find('"session_info"', 1, true) or (not info.preview and text:find('"user"', 1, true)) then
      local entry = decode(text)
      if entry and entry.type == "session_info" and type(entry.name) == "string" then
        info.name = entry.name
      elseif entry and entry.type == "message" and type(entry.message) == "table" and entry.message.role == "user" then
        local preview = content_text(entry.message.content):gsub("%s+", " ")
        if preview ~= "" then
          info.preview = preview:sub(1, 120)
        end
      end
    end
    return true
  end
  while true do
    local chunk = uv.fs_read(fd, 65536, offset)
    if not chunk or chunk == "" then
      break
    end
    offset = offset + #chunk
    local start = 1
    while start <= #chunk do
      local stop = chunk:find("\n", start, true)
      local fragment = chunk:sub(start, stop and stop - 1 or #chunk)
      if not skipping then
        if #pending + #fragment > 1024 * 1024 then
          pending, skipping = "", true
        else
          pending = pending .. fragment
        end
      end
      if not stop then
        break
      end
      if skipping and first or not skipping and not line(pending) then
        uv.fs_close(fd)
        return nil
      end
      pending, skipping, start = "", false, stop + 1
    end
  end
  if pending ~= "" and not skipping and not line(pending) then
    uv.fs_close(fd)
    return nil
  end
  uv.fs_close(fd)
  return not first and info.id and info or nil
end

-- Session files are append-only, so size and modification time identify a version.
local metadata_cache = {}
function M.info(path)
  local stat = uv.fs_stat(path)
  if not stat then
    metadata_cache[path] = nil
    return nil
  end
  local version = table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
  local hit = metadata_cache[path]
  if not hit or hit.version ~= version then
    hit = { version = version, info = metadata(path) or false }
    metadata_cache[path] = hit
  end
  return hit.info or nil
end

-- Details of `where`'s sessions, or with `all` of every directory's, newest first.
function M.list(where, all)
  local found = {}
  for _, file in ipairs(M.files(where, all)) do
    local item = M.info(file.path)
    if item and (all or same_dir(item.cwd, where.cwd, where.cwd)) then
      found[#found + 1] = item
    end
  end
  return found
end

return M
