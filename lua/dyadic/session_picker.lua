-- The session picker: a picker float (lua/dyadic/picker.lua) with pi's saved sessions, as
-- pi's session selector lists them: this directory's or all, threaded by fork, by recency,
-- or by relevance, optionally only named ones. A preview shows the session under the
-- cursor. Details load in worker threads (Sessions.load), so the list fills in as it goes.
local M = {}
local api = vim.api
local uv = vim.uv
local Picker = require("dyadic.picker")
local Sessions = require("dyadic.sessions")

M.default_keys = {
  open = "<CR>",
  search = "/",
  cancel = "<Esc>",
  close = "q",
  fold_or_up = "h",
  unfold_or_down = "l",
  scope = "<Tab>",
  sort = "s",
  named = "n",
  preview = "p",
  delete = "dd",
  copy = "yy",
}

M.sorts = { "threaded", "recent", "relevance" }

local function notify(text, level)
  vim.notify("Dyadic: " .. text, level or vim.log.levels.INFO)
end

local function home(path)
  return vim.fn.fnamemodify(path, ":~")
end

-- Age as pi shows it: now, 5m, 3h, 2d, 1w, 4mo, 1y.
function M.age(seconds, now)
  local diff = math.max(0, (now or os.time()) - seconds)
  local minutes, hours, days = math.floor(diff / 60), math.floor(diff / 3600), math.floor(diff / 86400)
  if minutes < 1 then
    return "now"
  elseif minutes < 60 then
    return minutes .. "m"
  elseif hours < 24 then
    return hours .. "h"
  elseif days < 7 then
    return days .. "d"
  elseif days < 30 then
    return math.floor(days / 7) .. "w"
  elseif days < 365 then
    return math.floor(days / 30) .. "mo"
  end
  return math.floor(days / 365) .. "y"
end

-- An ISO 8601 UTC time such as pi's header timestamp, in local time.
local function local_time(iso)
  local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local utc = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  local offset = os.time() - os.time(os.date("!*t") --[[@as osdateparam]])
  return os.date("%Y-%m-%d %H:%M", utc + offset)
end

-- Cut `text` to `width` display cells, ending in … when cut.
local function fit(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local chars = vim.fn.strchars(text)
  local low, high = 0, chars
  while low < high do
    local mid = math.ceil((low + high) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, mid)) <= width - 1 then
      low = mid
    else
      high = mid - 1
    end
  end
  return vim.fn.strcharpart(text, 0, low) .. "…"
end

local function title_of(details)
  return details.name or details.first or "(no messages)"
end

local function keys_of(config)
  local configured = ((config or {}).sessions or {}).keys or {}
  return vim.tbl_extend("force", M.default_keys, configured)
end

local function norm(path, cwd)
  return Sessions.resolve(path, cwd)
end

-- Words of the search; every one must match. Returns a score, lower is better: a word in
-- the name counts 0, in the first message, ID, or directory 1. Nil when a word misses.
local function score(p, details, words)
  local name = (details.name or ""):lower()
  local text = table.concat({ details.first or "", details.id or "", details.cwd or "" }, " "):lower()
  local total = 0
  for _, word in ipairs(words) do
    if name:find(word, 1, true) then
      total = total + 0
    elseif text:find(word, 1, true) then
      total = total + 1
    elseif p.text_matches and p.text_matches[details.path] then
      total = total + 2
    else
      return nil
    end
  end
  return total
end

local function newest_first(a, b)
  if a.modified == b.modified then
    return a.path > b.path
  end
  return a.modified > b.modified
end

-- Sessions as trees of forks: { details, children, latest }, newest activity first.
local function forest(p, list)
  local by_path, roots = {}, {}
  for _, details in ipairs(list) do
    by_path[norm(details.path, p.cwd)] = { details = details, children = {} }
  end
  for _, details in ipairs(list) do
    local node = by_path[norm(details.path, p.cwd)]
    local parent = details.parent and by_path[norm(details.parent, p.cwd)]
    if parent and parent ~= node then
      table.insert(parent.children, node)
    else
      roots[#roots + 1] = node
    end
  end
  local function latest(node, seen)
    if seen[node] then
      return node.details.modified
    end
    seen[node] = true
    local value = node.details.modified
    for _, child in ipairs(node.children) do
      value = math.max(value, latest(child, seen))
    end
    node.latest = value
    return value
  end
  local function order(nodes)
    table.sort(nodes, function(a, b)
      if a.latest == b.latest then
        return a.details.path > b.details.path
      end
      return a.latest > b.latest
    end)
    for _, node in ipairs(nodes) do
      order(node.children)
    end
  end
  for _, root in ipairs(roots) do
    latest(root, {})
  end
  order(roots)
  return roots
end

-- The sessions the scope, the named filter, and the search let through, in display order,
-- and whether they show as trees.
local function visible(p)
  local state = p.scopes[p.scope]
  local list = {}
  for _, details in pairs(state and state.items or {}) do
    if not p.named or details.name then
      list[#list + 1] = details
    end
  end
  local words = {}
  for word in p.query:lower():gmatch("%S+") do
    words[#words + 1] = word
  end
  if #words == 0 then
    table.sort(list, newest_first)
    return list, p.sort == "threaded"
  end
  local scored = {}
  for _, details in ipairs(list) do
    local value = score(p, details, words)
    if value then
      scored[#scored + 1] = { details = details, score = value }
    end
  end
  -- As in pi: with a search, recent keeps recency and the others sort by relevance.
  table.sort(scored, function(a, b)
    if p.sort ~= "recent" and a.score ~= b.score then
      return a.score < b.score
    end
    return newest_first(a.details, b.details)
  end)
  return vim.tbl_map(function(item)
    return item.details
  end, scored), false
end

-- Rows: { key, kind = "dir" or "session", details, dir, left = chunks, right, parent, fold }.
local function build_rows(p)
  local list, threaded = visible(p)
  local rows = {}
  local function add_tree(roots, indent, parent_line)
    local function walk(node, depth, continues, last, parent)
      local prefix = ""
      if depth > 0 then
        for _, more in ipairs(continues) do
          prefix = prefix .. (more and "│  " or "   ")
        end
        prefix = prefix .. (last and "└─ " or "├─ ")
      end
      local row = { key = node.details.path, kind = "session", details = node.details, prefix = indent .. prefix }
      row.parent = parent
      rows[#rows + 1] = row
      local line = #rows
      for index, child in ipairs(node.children) do
        local child_continues = vim.list_extend(vim.deepcopy(continues), { depth > 0 and not last or false })
        walk(child, depth + 1, child_continues, index == #node.children, line)
      end
      if #rows > line then
        row.fold = #rows
      end
    end
    for index, root in ipairs(roots) do
      walk(root, 0, {}, index == #roots, parent_line)
    end
  end
  if threaded and p.scope == "all" then
    local groups, order = {}, {}
    for _, details in ipairs(list) do
      local dir = norm(details.cwd ~= "" and details.cwd or "/", p.cwd)
      if not groups[dir] then
        groups[dir] = { dir = dir, sessions = {}, latest = 0 }
        order[#order + 1] = groups[dir]
      end
      table.insert(groups[dir].sessions, details)
      groups[dir].latest = math.max(groups[dir].latest, details.modified)
    end
    local here = norm(p.cwd, p.cwd)
    table.sort(order, function(a, b)
      if (a.dir == here) ~= (b.dir == here) then
        return a.dir == here
      end
      if a.latest == b.latest then
        return a.dir < b.dir
      end
      return a.latest > b.latest
    end)
    for _, group in ipairs(order) do
      rows[#rows + 1] = { key = "dir:" .. group.dir, kind = "dir", dir = group.dir, group = group, prefix = "" }
      local line = #rows
      add_tree(forest(p, group.sessions), "  ", line)
      rows[line].fold = #rows > line and #rows or nil
    end
  elseif threaded then
    add_tree(forest(p, list), "", nil)
  else
    for _, details in ipairs(list) do
      rows[#rows + 1] = { key = details.path, kind = "session", details = details, prefix = "", flat = true }
    end
  end
  return rows
end

-- Chunks of `row` fitted to `width`; `closed` shows the closed fold marker.
local function chunks_of(p, row, width, closed)
  local left, right = {}, {}
  local function add(list, text, group)
    list[#list + 1] = { text, group }
  end
  if row.kind == "dir" then
    add(left, (closed and "⊞ " or "⊟ "), "DyadicTreeActive")
    local count = #row.group.sessions
    add(right, count .. (count == 1 and " session  " or " sessions  "), "DyadicMeta")
    add(right, string.format("%4s", M.age(row.group.latest, p.now)), "DyadicMeta")
    local used = 2 + vim.fn.strdisplaywidth(right[1][1]) + vim.fn.strdisplaywidth(right[2][1])
    add(left, fit(home(row.dir), width - used - 2), "DyadicSessionDir")
  else
    local details = row.details
    add(left, row.prefix, "DyadicTreeLine")
    if closed then
      add(left, "⊞ ", "DyadicTreeActive")
    end
    if p.current and norm(details.path, p.cwd) == p.current then
      add(left, "• ", "DyadicTreeActive")
    end
    local agent = p.live[norm(details.path, p.cwd)]
    if agent then
      add(right, "agent " .. agent .. "  ", "DyadicMeta")
    end
    if row.flat and p.scope == "all" then
      local dir = fit(home(details.cwd), p.dir_width)
      add(right, dir .. string.rep(" ", p.dir_width - vim.fn.strdisplaywidth(dir) + 2), "DyadicMeta")
    end
    add(right, string.format("%" .. p.count_width .. "d", details.count or 0) .. "  ", "DyadicMeta")
    add(right, string.format("%4s", M.age(details.modified, p.now)), "DyadicMeta")
    local used = 0
    for _, chunk in ipairs(left) do
      used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    for _, chunk in ipairs(right) do
      used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    local title = title_of(details):gsub("%s+", " ")
    local group
    if details.name then
      group = "DyadicSessionNamed"
    elseif not details.first then
      group = "DyadicMeta"
    end
    add(left, fit(title, width - used - 2), group)
  end
  local used = 0
  for _, chunk in ipairs(left) do
    used = used + vim.fn.strdisplaywidth(chunk[1])
  end
  for _, chunk in ipairs(right) do
    used = used + vim.fn.strdisplaywidth(chunk[1])
  end
  local chunks = vim.list_extend(left, { { string.rep(" ", math.max(1, width - used)) } })
  return vim.list_extend(chunks, right)
end

local function selected_row(p)
  local line = Picker.selected_line(p)
  return line and p.rows and p.rows[line], line
end

local function title(p)
  local parts = { "Sessions", p.scope == "all" and "all" or "current", p.sort }
  if p.named then
    parts[#parts + 1] = "named"
  end
  local state = p.scopes[p.scope]
  local line = Picker.selected_line(p)
  local count = p.rows and #p.rows or 0
  parts[#parts + 1] = (count > 0 and line or 0) .. "/" .. count
  if state and not state.done then
    parts[#parts + 1] = string.format("loading %d/%d", state.loaded, state.total)
  end
  if p.searching then
    parts[#parts + 1] = string.format("searching %d/%d", p.searching.done, p.searching.total)
  end
  return " " .. table.concat(parts, " · ") .. " "
end

local function footer(keys)
  local hints = {}
  for _, item in ipairs({
    { "open", "open" },
    { "scope", "scope" },
    { "sort", "sort" },
    { "search", "search" },
    { "named", "named" },
    { "delete", "delete" },
    { "preview", "preview" },
    { "copy", "copy path" },
    { "close", "close" },
  }) do
    local key = keys[item[1]]
    if type(key) == "string" and key ~= "" then
      hints[#hints + 1] = key .. " " .. item[2]
    end
  end
  return hints
end

-- How long ago: "just now" or "5m ago".
local function ago(seconds, now)
  local age = M.age(seconds, now)
  return age == "now" and "just now" or age .. " ago"
end

-- The preview of the selected row.
local function preview(p)
  if not p.preview_buf then
    return
  end
  local row = selected_row(p)
  local lines, spans = {}, {}
  local function add(text, group)
    lines[#lines + 1] = text
    if group then
      spans[#spans + 1] = { #lines - 1, 0, #text, group }
    end
  end
  local function field(label, value)
    if value and value ~= "" then
      local head = string.format("%-9s ", label)
      lines[#lines + 1] = head .. value
      spans[#spans + 1] = { #lines - 1, 0, #head, "DyadicMeta" }
    end
  end
  if row and row.kind == "dir" then
    add(home(row.dir), "DyadicTitle")
    add("")
    field("Sessions", tostring(#row.group.sessions))
    field("Updated", ago(row.group.latest, p.now))
  elseif row then
    local details = row.details
    local function clean(text)
      return text and (text:gsub("%s+", " ")) or nil
    end
    add(clean(title_of(details)), details.name and "DyadicSessionNamed" or "DyadicTitle")
    add("")
    if details.name and details.first then
      add("> " .. clean(details.first), "DyadicMeta")
      add("")
    end
    -- Where the session left off; wrapped lines keep the text's indent.
    if details.last_user and details.last_user ~= details.first then
      add("Last message", "DyadicMeta")
      add("  " .. clean(details.last_user))
    end
    if details.last_assistant then
      add("Last reply", "DyadicMeta")
      add("  " .. clean(details.last_assistant))
    end
    if details.last_user or details.last_assistant then
      add("")
    end
    field("Folder", home(details.cwd))
    field("Model", details.model and (details.model .. (details.thinking and " · " .. details.thinking or "")))
    field("Messages", tostring(details.count or 0))
    field("Updated", ago(details.modified, p.now))
    field("Created", local_time(details.created))
    field("ID", details.id)
    field("File", home(details.path))
    if details.parent then
      local parent = (p.scopes.all and p.scopes.all.items[details.parent])
        or (p.scopes.current and p.scopes.current.items[details.parent])
      field("Forked", parent and title_of(parent):gsub("%s+", " ") or home(details.parent))
    end
    local agent = p.live[norm(details.path, p.cwd)]
    if agent then
      field("Agent", "agent " .. agent)
    end
  end
  Picker.set_preview(p, lines, spans)
end

-- Remember which folds are closed, by row key.
local function save_folds(p)
  if not p.rows or not Picker.valid_win(p.list_win) then
    return
  end
  for line, row in ipairs(p.rows) do
    if row.fold then
      p.folds[row.key] = Picker.closed_at(p, line)
    end
  end
end

local function render(p, key)
  if p.closed then
    return
  end
  save_folds(p)
  if key == nil then
    local row = selected_row(p)
    key = row and row.key
  end
  p.now = os.time()
  p.rows = build_rows(p)
  local width = api.nvim_win_get_width(p.list_win)
  -- Columns: message counts, and directories in flat rows of the All view.
  p.count_width, p.dir_width = 1, 0
  for _, row in ipairs(p.rows) do
    if row.details then
      p.count_width = math.max(p.count_width, #tostring(row.details.count or 0))
      if row.flat then
        p.dir_width = math.max(p.dir_width, vim.fn.strdisplaywidth(home(row.details.cwd)))
      end
    end
  end
  p.dir_width = math.min(p.dir_width, math.floor(width * 0.3))
  local rows, cursor = {}, 1
  for index, row in ipairs(p.rows) do
    rows[index] = { chunks = chunks_of(p, row, width, false), fold = row.fold }
    if row.key == key then
      cursor = index
    end
  end
  local state = p.scopes[p.scope]
  local empty = state and not state.done and "Loading…"
    or (p.scope == "current" and "No sessions in this folder. " .. (p.keys.scope or "") .. " shows all")
    or "No sessions found"
  Picker.render(p, rows, cursor, empty)
  -- Folds start open; close those that were closed, and in the All view the groups of
  -- other directories. Inner folds first, so closing one never closes its parent.
  local here = "dir:" .. norm(p.cwd, p.cwd)
  api.nvim_win_call(p.list_win, function()
    for index = #p.rows, 1, -1 do
      local row = p.rows[index]
      local closed = p.folds[row.key]
      if closed == nil then
        closed = row.kind == "dir" and row.key ~= here
      end
      if row.fold and closed then
        vim.cmd(string.format("silent! %dfoldclose", index))
      end
    end
  end)
  if #p.rows > 0 then
    api.nvim_win_set_cursor(p.list_win, { Picker.selected_line(p) or cursor, 0 })
  end
  Picker.update_title(p)
  preview(p)
end

-- Render at most every 100 ms while details arrive.
local function render_soon(p)
  if p.render_pending then
    return
  end
  p.render_pending = true
  vim.defer_fn(function()
    p.render_pending = false
    render(p)
  end, 100)
end

local function load(p, scope)
  if p.scopes[scope] then
    return
  end
  local files = Sessions.files(p.where, scope == "all")
  local state = { items = {}, loaded = 0, total = #files, done = false }
  p.scopes[scope] = state
  local here = norm(p.cwd, p.cwd)
  state.handle = Sessions.load(
    vim.tbl_map(function(file)
      return file.path
    end, files),
    function(details)
      state.loaded = state.loaded + 1
      if scope == "all" or norm(details.cwd, p.cwd) == here then
        state.items[details.path] = details
      end
      if p.scope == scope then
        render_soon(p)
      end
    end,
    function()
      state.done = true
      if p.closed then
        return
      end
      if p.scope == scope then
        render_soon(p)
      end
      -- All loads after this directory, so <Tab> finds it ready.
      if scope == "current" then
        load(p, "all")
      end
    end
  )
end

local function toggle_fold(p, line)
  api.nvim_win_call(p.list_win, function()
    vim.cmd(string.format("silent! %dfoldopen", line))
  end)
end

local function fold_or_up(p)
  local row, line = selected_row(p)
  if not row then
    return
  end
  if row.fold and not Picker.closed_at(p, line) then
    api.nvim_win_set_cursor(p.list_win, { line, 0 })
    api.nvim_win_call(p.list_win, function()
      vim.cmd("normal! zc")
    end)
  elseif row.parent then
    api.nvim_win_set_cursor(p.list_win, { row.parent, 0 })
  end
  preview(p)
end

local function unfold_or_down(p)
  local row, line = selected_row(p)
  if not row then
    return
  end
  if Picker.closed_at(p, line) then
    toggle_fold(p, line)
  elseif row.fold then
    api.nvim_win_set_cursor(p.list_win, { line + 1, 0 })
  end
  preview(p)
end

local function choose(p)
  local row, line = selected_row(p)
  if not row then
    return
  end
  if row.kind == "dir" then
    if Picker.closed_at(p, line) then
      toggle_fold(p, line)
    else
      api.nvim_win_call(p.list_win, function()
        vim.cmd(string.format("silent! %dfoldclose", line))
      end)
    end
    return
  end
  local path = row.details.path
  Picker.close(p)
  p.on_choose(path, row.details)
end

-- Move a file to the trash as pi does, with the `trash` command when there is one, else
-- delete it. Returns how, or nil and the error.
local function trash(path)
  if vim.fn.executable("trash") == 1 then
    local result = vim.system({ "trash", path }):wait()
    if result.code == 0 or not uv.fs_stat(path) then
      return "trash"
    end
  end
  local ok, err = uv.fs_unlink(path)
  if ok then
    return "deleted"
  end
  return nil, err
end

local function delete(p)
  local row = selected_row(p)
  if not row or row.kind ~= "session" then
    return
  end
  local details = row.details
  local agent = p.live[norm(details.path, p.cwd)]
  if agent then
    notify("Agent " .. agent .. " shows this session. Close it first", vim.log.levels.WARN)
    return
  end
  local label = fit(title_of(details):gsub("%s+", " "), 60)
  if vim.fn.confirm('Delete session "' .. label .. '"?', "&Delete\n&Cancel", 2) ~= 1 then
    return
  end
  local how, err = trash(details.path)
  if not how then
    notify("Could not delete " .. home(details.path) .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  for _, state in pairs(p.scopes) do
    state.items[details.path] = nil
  end
  notify((how == "trash" and "Moved to the trash: " or "Deleted: ") .. label)
  local next_row = p.rows[(Picker.selected_line(p) or 1) + 1] or p.rows[(Picker.selected_line(p) or 1) - 1]
  render(p, next_row and next_row.key)
end

local function copy(p)
  local row = selected_row(p)
  if not row or row.kind ~= "session" then
    return
  end
  local register = vim.v.register
  vim.fn.setreg(register, row.details.path)
  notify("Copied the session file path to register " .. register)
end

local function bind(p)
  local keys = p.keys
  local function map(name, fn)
    Picker.map(p, keys, name, fn, "Dyadic sessions")
  end
  map("open", function()
    choose(p)
  end)
  map("close", function()
    Picker.close(p)
  end)
  map("cancel", function()
    if p.query ~= "" then
      Picker.clear_query(p)
    else
      Picker.close(p)
    end
  end)
  map("search", function()
    Picker.focus_search(p)
  end)
  map("fold_or_up", function()
    fold_or_up(p)
  end)
  map("unfold_or_down", function()
    unfold_or_down(p)
  end)
  map("scope", function()
    M.set_scope(p, p.scope == "all" and "current" or "all")
  end)
  map("sort", function()
    local index = 1
    for i, name in ipairs(M.sorts) do
      if name == p.sort then
        index = i
      end
    end
    p.sort = M.sorts[index % #M.sorts + 1]
    render(p)
  end)
  map("named", function()
    p.named = not p.named
    render(p)
  end)
  map("preview", function()
    Picker.toggle_preview(p)
  end)
  map("delete", function()
    delete(p)
  end)
  map("copy", function()
    copy(p)
  end)
end

function M.set_scope(p, scope)
  p.scope = scope
  load(p, scope)
  render(p)
end

-- Open the picker. `opts`:
--   where      whose sessions: { cwd, args, session_file } (see lua/dyadic/sessions.lua)
--   config     dyadic's configuration, for `sessions.keys`
--   on_choose  function(path, details) for the session chosen
function M.open(opts)
  -- Defines dyadic's highlight groups when no agent has yet.
  require("dyadic.view")
  local where = opts.where
  local live = {}
  for _, agent in ipairs(require("dyadic").list()) do
    local file = agent.state and agent.state.sessionFile
    if type(file) == "string" and file ~= "" then
      live[norm(file, where.cwd)] = agent.id
    end
  end
  local keys = keys_of(opts.config)
  local bar_keys = {
    ["<CR>"] = function(p)
      vim.cmd("stopinsert")
      vim.schedule(function()
        if not p.closed then
          choose(p)
        end
      end)
    end,
  }
  -- A special key such as <Tab> changes the scope while typing too, as in pi.
  if type(keys.scope) == "string" and keys.scope:match("^<.+>$") then
    bar_keys[keys.scope] = function(p)
      M.set_scope(p, p.scope == "all" and "current" or "all")
    end
  end
  local current = where.session_file and where.session_file ~= "" and norm(where.session_file, where.cwd) or nil
  local p = Picker.open({
    kind = "sessions",
    where = where,
    cwd = where.cwd,
    current = current,
    live = live,
    keys = keys,
    on_choose = opts.on_choose,
    scope = "current",
    sort = "threaded",
    named = false,
    show_preview = true,
    scopes = {},
    folds = {},
  }, {
    name = "dyadic://sessions",
    filetype = "dyadic_sessions",
    title = title,
    footer = footer(keys),
    bar_keys = bar_keys,
    preview = true,
    on_query = function(p)
      render(p)
      if p.on_query then
        p.on_query(p)
      end
    end,
    on_move = preview,
    on_resize = function(p)
      if p.rows then
        render(p)
      end
    end,
    on_close = function(p)
      for _, state in pairs(p.scopes) do
        state.handle:cancel()
      end
    end,
    foldtext = function(p, line)
      local row = p.rows and p.rows[line]
      return row and chunks_of(p, row, api.nvim_win_get_width(p.list_win), true)
    end,
  })
  bind(p)
  load(p, "current")
  render(p, current)
  return p
end

-- The open session picker, for tests.
function M.current()
  local p = Picker.current()
  return p and p.kind == "sessions" and p or nil
end

return M
