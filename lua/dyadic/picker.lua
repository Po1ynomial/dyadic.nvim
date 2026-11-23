-- The float shared by dyadic's pickers: a one-line search bar above a list with a title,
-- a footer of key hints, and Neovim's manual folds. The cursor line is the selection. The
-- picker closes when focus leaves it, except to a dialog it opened itself.
--
-- A picker is a table `p` that M.open fills in; `spec` gives what differs:
--   name        buffer name prefix, such as "dyadic://1/tree"
--   filetype    of the list buffer
--   title(p)    the list's title
--   footer      key hints under the list
--   on_query(p) the search text, `p.query`, changed
--   on_move(p)  the cursor moved in the list
--   on_close(p) the picker closed
--   foldtext(p, line) chunks for a closed fold starting at `line`
--   bar_keys    Insert-mode keys of the search bar: lhs -> function(p)
local M = {}
local api = vim.api

local ns = api.nvim_create_namespace("dyadic_picker")
local bar_ns = api.nvim_create_namespace("dyadic_picker_bar")
local current -- the open picker, if any

function M.valid_win(win)
  return win and api.nvim_win_is_valid(win)
end
local valid_win = M.valid_win

-- Outer size about 90% of the editor, like the detail float: a search bar on top of the list.
local function geometry()
  local columns, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(10, math.floor(columns * 0.9) - 2)
  local height = math.max(6, math.floor(lines * 0.9) - 2)
  local row = math.floor((lines - height - 2) / 2)
  local col = math.floor((columns - width - 2) / 2)
  return {
    bar = { relative = "editor", width = width, height = 1, row = row, col = col },
    list = { relative = "editor", width = width, height = math.max(1, height - 3), row = row + 3, col = col },
  }
end

-- The selected line: the cursor line, or the first line of the closed fold it is in.
function M.selected_line(p)
  if not valid_win(p.list_win) then
    return nil
  end
  local line = api.nvim_win_get_cursor(p.list_win)[1]
  local start = api.nvim_win_call(p.list_win, function()
    return vim.fn.foldclosed(line)
  end)
  return start ~= -1 and start or line
end

function M.update_title(p)
  if valid_win(p.list_win) then
    api.nvim_win_set_config(p.list_win, { title = p.spec.title(p), title_pos = "left" })
  end
end

-- `keep_focus` leaves the cursor where the user moved it instead of returning to the
-- window the picker was opened from.
function M.close(p, keep_focus)
  if p.closed then
    return
  end
  p.closed = true
  if current == p then
    current = nil
  end
  pcall(api.nvim_del_augroup_by_id, p.group)
  for _, win in ipairs({ p.bar_win, p.list_win }) do
    if valid_win(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ p.bar_buf, p.list_buf }) do
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  if not keep_focus and valid_win(p.previous_win) then
    pcall(api.nvim_set_current_win, p.previous_win)
  end
  if p.spec.on_close then
    p.spec.on_close(p)
  end
end

function M.focus_list(p)
  if not p.closed and valid_win(p.list_win) then
    vim.cmd("stopinsert")
    api.nvim_set_current_win(p.list_win)
  end
end

local function placeholder(p)
  api.nvim_buf_clear_namespace(p.bar_buf, bar_ns, 0, -1)
  if p.query == "" then
    api.nvim_buf_set_extmark(p.bar_buf, bar_ns, 0, 0, {
      virt_text = { { "/ search", "DyadicMeta" } },
      virt_text_pos = "overlay",
    })
  end
end

function M.set_query(p, query)
  if p.query ~= query then
    p.query = query
    p.spec.on_query(p)
  end
  placeholder(p)
end

-- Empty the search bar and the query.
function M.clear_query(p)
  api.nvim_buf_set_lines(p.bar_buf, 0, -1, false, { "" })
  M.set_query(p, "")
end

function M.focus_search(p)
  api.nvim_set_current_win(p.bar_win)
  api.nvim_win_set_cursor(p.bar_win, { 1, #p.query })
  vim.cmd("startinsert!")
end

-- Ask something through vim.ui without the picker closing when a UI plugin's float takes
-- focus. `done` runs after the answer, with the picker focused again when still open.
function M.prompting(p, fn)
  p.prompting = true
  fn(function()
    p.prompting = false
    M.focus_list(p)
  end)
end

-- Show `rows`, each { chunks = { { text, hl }, ... }, fold = last line of its fold },
-- with `empty` shown when there are none, and put the cursor on line `cursor`. All folds
-- start open.
function M.render(p, rows, cursor, empty)
  local lines, spans = {}, {}
  for index, row in ipairs(rows) do
    local line, col = {}, 0
    for _, chunk in ipairs(row.chunks) do
      line[#line + 1] = chunk[1]
      if chunk[2] then
        spans[#spans + 1] = { index - 1, col, col + #chunk[1], chunk[2] }
      end
      col = col + #chunk[1]
    end
    lines[index] = table.concat(line)
  end
  p.row_count = #rows
  if #lines == 0 then
    lines = { "" }
  end
  vim.bo[p.list_buf].modifiable = true
  api.nvim_buf_set_lines(p.list_buf, 0, -1, false, lines)
  vim.bo[p.list_buf].modifiable = false
  api.nvim_buf_clear_namespace(p.list_buf, ns, 0, -1)
  if #rows == 0 then
    api.nvim_buf_set_extmark(p.list_buf, ns, 0, 0, { virt_text = { { empty or "Nothing found", "DyadicMeta" } } })
  end
  for _, span in ipairs(spans) do
    api.nvim_buf_set_extmark(p.list_buf, ns, span[1], span[2], { end_col = span[3], hl_group = span[4] })
  end
  api.nvim_win_call(p.list_win, function()
    vim.cmd("silent! normal! zE")
    -- New folds start closed, and a range inside a closed fold grows to the whole fold, so
    -- create inner folds first: from the last row up, each new fold only encloses others.
    for index = #rows, 1, -1 do
      local last = rows[index].fold
      if last and last > index then
        vim.cmd(string.format("silent! %d,%dfold", index, last))
      end
    end
    vim.cmd("silent! normal! zR")
  end)
  if #rows > 0 then
    api.nvim_win_set_cursor(p.list_win, { math.max(1, math.min(cursor or 1, #rows)), 0 })
  end
  M.update_title(p)
end

-- Whether the fold at `line` is closed and starts there.
function M.closed_at(p, line)
  return api.nvim_win_call(p.list_win, function()
    return vim.fn.foldclosed(line) == line
  end)
end

-- Move the selection by `delta` lines, stepping over closed folds like j and k do.
function M.move(p, delta)
  if (p.row_count or 0) == 0 then
    return
  end
  local line = M.selected_line(p) or 1
  local target = line
  api.nvim_win_call(p.list_win, function()
    api.nvim_win_set_cursor(0, { line, 0 })
    vim.cmd("normal! " .. (delta > 0 and "j" or "k"))
    target = vim.fn.line(".")
  end)
  api.nvim_win_set_cursor(p.list_win, { target, 0 })
  M.update_title(p)
  if p.spec.on_move then
    p.spec.on_move(p)
  end
end

-- Map a list key from configured `keys` by action name.
function M.map(p, keys, name, fn, desc)
  local lhs = keys[name]
  if type(lhs) == "string" and lhs ~= "" then
    vim.keymap.set("n", lhs, fn, { buffer = p.list_buf, nowait = true, silent = true, desc = desc .. " " .. name })
  end
end

local function scratch(name)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  pcall(api.nvim_buf_set_name, buf, name)
  return buf
end

-- Closed folds show their first row with the picker's closed marker.
function M.foldtext()
  local p = current
  local chunks = p and p.spec.foldtext and p.spec.foldtext(p, vim.v.foldstart)
  if not chunks then
    return vim.fn.foldtext()
  end
  local out = {}
  for _, chunk in ipairs(chunks) do
    out[#out + 1] = { chunk[1], chunk[2] or "Normal" }
  end
  return out
end

-- Open the float for picker `p`, closing any other picker. Returns `p`.
function M.open(p, spec)
  if current then
    M.close(current)
  end
  p.spec = spec
  p.query = p.query or ""
  p.previous_win = api.nvim_get_current_win()
  current = p
  local layout = geometry()
  p.bar_buf = scratch(spec.name .. "/search")
  p.list_buf = scratch(spec.name)
  vim.bo[p.list_buf].filetype = spec.filetype
  vim.bo[p.list_buf].modifiable = false
  p.bar_win = api.nvim_open_win(
    p.bar_buf,
    false,
    vim.tbl_extend("force", layout.bar, { border = "rounded", style = "minimal", focusable = true })
  )
  p.list_win = api.nvim_open_win(
    p.list_buf,
    true,
    vim.tbl_extend("force", layout.list, {
      border = "rounded",
      style = "minimal",
      title = " ",
      title_pos = "left",
      footer = spec.footer,
      footer_pos = "left",
    })
  )
  for option, value in pairs({
    wrap = false,
    cursorline = true,
    foldenable = true,
    foldmethod = "manual",
    foldminlines = 0,
    foldcolumn = "0",
    foldtext = "v:lua.require'dyadic.picker'.foldtext()",
    fillchars = "fold: ,eob: ",
  }) do
    vim.wo[p.list_win][option] = value
  end
  vim.wo[p.bar_win].wrap = false
  local Pin = require("dyadic.pin")
  local function lost()
    M.close(p, true)
  end
  Pin.pin(p.list_win, p.list_buf, { lost = lost })
  Pin.pin(p.bar_win, p.bar_buf, { lost = lost })
  placeholder(p)

  -- The search bar: typing filters at once; the list's selection moves from here too.
  local function bar(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = p.bar_buf, silent = true, desc = "Dyadic picker search" })
  end
  for lhs, fn in pairs(spec.bar_keys or {}) do
    bar(lhs, function()
      fn(p)
    end)
  end
  bar("<Esc>", function()
    M.focus_list(p)
  end)
  for lhs, delta in pairs({ ["<C-n>"] = 1, ["<Down>"] = 1, ["<C-p>"] = -1, ["<Up>"] = -1 }) do
    bar(lhs, function()
      M.move(p, delta)
    end)
  end
  vim.keymap.set("n", "<Esc>", function()
    M.focus_list(p)
  end, { buffer = p.bar_buf, silent = true })
  vim.keymap.set("n", "q", function()
    M.close(p)
  end, { buffer = p.bar_buf, silent = true })

  p.group = api.nvim_create_augroup("DyadicPicker", { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = p.group,
    buffer = p.list_buf,
    callback = function()
      M.update_title(p)
      if spec.on_move then
        spec.on_move(p)
      end
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = p.group,
    buffer = p.bar_buf,
    callback = function()
      M.set_query(p, api.nvim_buf_get_lines(p.bar_buf, 0, 1, false)[1] or "")
    end,
  })
  api.nvim_create_autocmd("WinEnter", {
    group = p.group,
    callback = function()
      vim.schedule(function()
        local win = api.nvim_get_current_win()
        if not p.closed and not p.prompting and win ~= p.list_win and win ~= p.bar_win then
          M.close(p, true)
        end
      end)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = p.group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win == p.list_win or win == p.bar_win then
        vim.schedule(function()
          M.close(p)
        end)
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = p.group,
    callback = function()
      local resized = geometry()
      if valid_win(p.bar_win) and valid_win(p.list_win) then
        api.nvim_win_set_config(p.bar_win, resized.bar)
        api.nvim_win_set_config(p.list_win, resized.list)
      end
    end,
  })
  return p
end

-- The open picker, if any.
function M.current()
  return current
end

return M
