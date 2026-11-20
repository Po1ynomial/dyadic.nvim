-- Windows dyadic opens for its own buffers never show another buffer. 'winfixbuf' refuses
-- ordinary switches such as :bnext, [b, or <C-^> with E1513. A forced switch (:bnext!,
-- :buffer! N, :edit! file) shows that buffer in the main area instead: the window gets
-- its own buffer back, or, when that buffer is gone, its owner closes it through `lost`.
local M = {}
local api = vim.api

-- window -> { buf = the buffer it shows, lost = called when the buffer is gone }
local pinned = {}
-- Forced switches seen and not yet undone: { win, entry, foreign }.
local pending = {}
local scheduled = false

local function valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

-- Pin `buf` to `win`. `opts.lost` closes whatever the window belongs to; the window itself
-- is closed afterwards in any case.
function M.pin(win, buf, opts)
  vim.wo[win].winfixbuf = true
  pinned[win] = { buf = buf, lost = opts and opts.lost }
end

-- Let `win` show other buffers again.
function M.unpin(win)
  pinned[win] = nil
  if valid_win(win) then
    vim.wo[win].winfixbuf = false
  end
end

-- Show `buf` in the pinned window `win` and pin it there instead.
function M.set_buf(win, buf)
  local entry = pinned[win] or {}
  pinned[win] = { buf = buf, lost = entry.lost }
  vim.wo[win].winfixbuf = false
  api.nvim_win_set_buf(win, buf)
  vim.wo[win].winfixbuf = true
end

function M.is_pinned(win)
  return pinned[win] ~= nil
end

-- Note windows that show a buffer other than their own, while the foreign buffer is known.
local function capture()
  for win, entry in pairs(pinned) do
    if not valid_win(win) then
      pinned[win] = nil
    elseif api.nvim_win_get_buf(win) ~= entry.buf then
      pinned[win] = nil
      pending[#pending + 1] = { win = win, entry = entry, foreign = api.nvim_win_get_buf(win) }
    end
  end
end

-- Undo forced switches: the foreign buffer moves to the main area.
function M.check()
  scheduled = false
  capture()
  local list = pending
  pending = {}
  for _, item in ipairs(list) do
    local win, entry = item.win, item.entry
    if valid_win(win) and api.nvim_buf_is_valid(entry.buf) then
      vim.wo[win].winfixbuf = false
      pcall(api.nvim_win_set_buf, win, entry.buf)
      M.pin(win, entry.buf, entry)
    else
      if entry.lost then
        pcall(entry.lost)
      end
      if valid_win(win) then
        pcall(api.nvim_win_close, win, true)
      end
    end
    if api.nvim_buf_is_valid(item.foreign) then
      local main = require("dyadic.sidebar").main_window()
      pcall(api.nvim_win_set_buf, main, item.foreign)
      pcall(api.nvim_set_current_win, main)
    end
  end
end

local group = api.nvim_create_augroup("DyadicPin", { clear = true })
api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  callback = function()
    capture()
    if #pending > 0 and not scheduled then
      scheduled = true
      vim.schedule(M.check)
    end
  end,
})
api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(ev)
    pinned[tonumber(ev.match)] = nil
  end,
})

return M
