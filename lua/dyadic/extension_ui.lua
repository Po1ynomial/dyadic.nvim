-- Extension UI requests from pi: fire-and-forget updates and serialized native dialogs.
local M = {}
local api = vim.api
local text = require("dyadic.text")
local clean, one_line = text.clean, text.one_line
local dialog_queue = {}
local active_dialog
local builtin_busy
local pump_dialogs

local function valid_buf(buf)
  return buf and api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

local function respond(s, id, fields)
  if not s.rpc then
    return
  end
  fields.type, fields.id = "extension_ui_response", id
  local ok, sent, err = pcall(s.rpc.send, s.rpc, fields)
  if (not ok or not sent) and not s.closed then
    s:notice("Extension response failed: " .. tostring(ok and err or sent), "error")
  end
end

local function finish_dialog(dialog, fields)
  if dialog.done then
    return
  end
  dialog.done = true
  local owns_builtin = active_dialog == dialog and dialog.builtin
  if owns_builtin and (not fields or fields.cancelled) then
    local mode = api.nvim_get_mode().mode
    if mode:match("^[cr]") then
      api.nvim_input("<C-c>")
    end
  end
  if dialog.timer then
    dialog.timer:stop()
    dialog.timer:close()
    dialog.timer = nil
  end
  if dialog.s._view then
    dialog.s._view.dialogs[dialog.id] = nil
    dialog.s._view.seen_dialogs[dialog.id] = true
  end
  if active_dialog == dialog then
    active_dialog = nil
  end
  respond(dialog.s, dialog.id, fields or { cancelled = true })
  for _, win in ipairs(dialog.windows or {}) do
    if valid_win(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  if valid_buf(dialog.buf) then
    pcall(api.nvim_buf_delete, dialog.buf, { force = true })
  end
  if dialog.group then
    pcall(api.nvim_del_augroup_by_id, dialog.group)
  end
  vim.schedule(pump_dialogs)
end

local function native_editor(dialog)
  local record = dialog.record
  local buf = api.nvim_create_buf(false, true)
  dialog.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(record.prefill or "", "\n", { plain = true }))
  local width = math.max(1, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(20, vim.o.lines - 6))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. one_line(record.title or "Extension editor") .. " ",
    footer = " Normal: g<CR> accept, q / Esc cancel ",
    footer_pos = "center",
  })
  dialog.windows = { win }
  vim.wo[win].wrap = true
  local function accept()
    if dialog.done then
      return
    end
    finish_dialog(dialog, { value = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") })
  end
  local function cancel()
    finish_dialog(dialog, { cancelled = true })
  end
  vim.keymap.set("n", "g<CR>", accept, { buffer = buf, silent = true, desc = "Accept extension editor" })
  vim.keymap.set("n", "<Plug>(DyadicEditorAccept)", accept, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Plug>(DyadicEditorCancel)", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
  dialog.group = api.nvim_create_augroup("DyadicDialog" .. buf, { clear = true })
  api.nvim_create_autocmd({ "BufWipeout", "BufHidden" }, { group = dialog.group, buffer = buf, callback = cancel })
  api.nvim_create_autocmd("WinClosed", { group = dialog.group, pattern = tostring(win), callback = cancel })
end

pump_dialogs = function()
  if active_dialog or builtin_busy then
    return
  end
  local dialog
  while #dialog_queue > 0 do
    local candidate = table.remove(dialog_queue, 1)
    if not candidate.done then
      dialog = candidate
      break
    end
  end
  if not dialog then
    return
  end
  if dialog.s.closed or dialog.s._view.disposed then
    finish_dialog(dialog)
    return
  end
  active_dialog = dialog
  local record = dialog.record
  local before = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    before[win] = true
  end
  local ui = record.method == "input" and vim.ui.input or vim.ui.select
  local source = debug.getinfo(ui, "S").source
  dialog.builtin = record.method ~= "editor" and source:match("/vim/ui%.lua$") ~= nil
  if dialog.builtin then
    builtin_busy = dialog
  end
  local ok, err = pcall(function()
    if record.method == "editor" then
      native_editor(dialog)
    elseif record.method == "select" then
      vim.ui.select(record.options or {}, {
        prompt = one_line(record.title or "Select"),
        format_item = one_line,
      }, function(value)
        finish_dialog(dialog, value == nil and { cancelled = true } or { value = value })
      end)
    elseif record.method == "confirm" then
      vim.ui.select(
        { "Yes", "No" },
        { prompt = one_line(record.title or "Confirm") .. ": " .. one_line(record.message) },
        function(value)
          finish_dialog(dialog, value == nil and { cancelled = true } or { confirmed = value == "Yes" })
        end
      )
    elseif record.method == "input" then
      vim.ui.input({
        prompt = one_line(record.title or "Input") .. ": ",
        default = "",
        placeholder = clean(record.placeholder),
      }, function(value)
        finish_dialog(dialog, value == nil and { cancelled = true } or { value = value })
      end)
    end
  end)
  if builtin_busy == dialog then
    builtin_busy = nil
    if dialog.done then
      vim.schedule(pump_dialogs)
    end
  end
  if not ok then
    local completed = dialog.done
    finish_dialog(dialog)
    if not completed and not dialog.s.closed then
      dialog.s:notice("Extension dialog failed: " .. clean(err), "error")
    end
    return
  end
  -- UI providers do not offer a common close API. Track only newly created floats.
  if not dialog.done and record.method ~= "editor" then
    dialog.windows = {}
    for _, win in ipairs(api.nvim_list_wins()) do
      if not before[win] and api.nvim_win_get_config(win).relative ~= "" then
        dialog.windows[#dialog.windows + 1] = win
      end
    end
    if #dialog.windows > 0 then
      dialog.group = api.nvim_create_augroup("DyadicDialog" .. dialog.windows[1], { clear = true })
      for _, win in ipairs(dialog.windows) do
        api.nvim_create_autocmd("WinClosed", {
          group = dialog.group,
          pattern = tostring(win),
          callback = function()
            finish_dialog(dialog)
          end,
        })
      end
    end
  end
end

function M.handle(s, record)
  if not s._view then
    return
  end
  local method = record.method
  if method == "notify" then
    s:notice(clean(record.message), record.notifyType or "info")
    return
  elseif method == "setStatus" then
    if record.statusKey then
      s.statuses[record.statusKey] = record.statusText and clean(record.statusText) or nil
    end
    s:render()
    return
  elseif method == "setWidget" then
    if record.widgetKey then
      s.widgets[record.widgetKey] = type(record.widgetLines) == "table"
          and {
            lines = record.widgetLines,
            placement = record.widgetPlacement or "aboveEditor",
          }
        or nil
    end
    s:render()
    return
  elseif method == "setTitle" then
    s.title = clean(record.title)
    s:render()
    return
  elseif method == "set_editor_text" then
    require("dyadic.view").set_draft(s, record.text or "")
    return
  end
  if record.id == nil then
    s:notice("Extension dialog has no request id", "error")
    return
  end
  if s._view.seen_dialogs[record.id] then
    return
  end
  if s.closed or s._view.disposed then
    respond(s, record.id, { cancelled = true })
    return
  end
  if not ({ select = true, confirm = true, input = true, editor = true })[method] then
    s._view.seen_dialogs[record.id] = true
    respond(s, record.id, { cancelled = true })
    s:notice("Unsupported extension UI method: " .. one_line(method), "warning")
    return
  end
  if s._view.dialogs[record.id] then
    -- Repeated live IDs belong to the pending request.
    return
  end
  local dialog = { s = s, id = record.id, record = record, windows = {}, done = false }
  s._view.dialogs[record.id] = dialog
  dialog_queue[#dialog_queue + 1] = dialog
  local timeout = tonumber(record.timeout)
  if timeout then
    dialog.timer = vim.uv.new_timer()
    dialog.timer:start(
      math.max(0, timeout),
      0,
      vim.schedule_wrap(function()
        finish_dialog(dialog)
      end)
    )
  end
  vim.schedule(pump_dialogs)
end

function M.dispose_dialogs(s)
  if not s._view then
    return
  end
  local pending = {}
  for _, dialog in pairs(s._view.dialogs) do
    pending[#pending + 1] = dialog
  end
  for _, dialog in ipairs(pending) do
    finish_dialog(dialog)
  end
end

return M
