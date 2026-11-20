-- Editor-backed file access for the bridge's read, edit, and write tools: which buffer holds
-- a file, its text as pi sees it, and applying new text as ordinary buffer changes.
local M = {}
local api = vim.api

-- vim.text.diff replaces vim.diff from Neovim 0.12.
---@diagnostic disable-next-line: deprecated
local diff = vim.text and vim.text.diff or vim.diff
M.diff = diff

local function normalize(path)
  return vim.fs.normalize(path)
end

local function real(path)
  return vim.uv.fs_realpath(path)
end

-- The loaded file buffer for an absolute path, if any.
function M.buffer(path)
  local wanted = normalize(path)
  local wanted_real = real(wanted)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = api.nvim_buf_get_name(buf)
      if name ~= "" then
        name = normalize(name)
        if name == wanted or (wanted_real and real(name) == wanted_real) then
          return buf
        end
      end
    end
  end
end

-- The buffer's text as a file's content: lines joined with LF, with a final newline when the
-- buffer writes one. The file format and BOM stay the buffer's business.
function M.text(buf)
  local empty = api.nvim_buf_call(buf, function()
    return vim.fn.line2byte(vim.fn.line("$") + 1) == -1
  end)
  if empty then
    return ""
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local eol = vim.bo[buf].eol or vim.bo[buf].fixeol
  return table.concat(lines, "\n") .. (eol and "\n" or "")
end

-- Split file content into buffer lines and whether it ends with a newline.
function M.lines(content)
  content = content:gsub("\r\n", "\n")
  local eol = content:sub(-1) == "\n"
  if eol then
    content = content:sub(1, -2)
  end
  return vim.split(content, "\n", { plain = true }), eol
end

-- Change the buffer to `content` hunk by hunk, so untouched lines keep their marks, folds,
-- and diagnostics, and one undo reverts the whole change. Returns the hunks applied as
-- { start, count, lines } in final buffer lines (1-based start; count 0 for deletions).
function M.apply(buf, content)
  local old = api.nvim_buf_get_lines(buf, 0, -1, false)
  local new, eol = M.lines(content)
  local hunks = diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", {
    result_type = "indices",
    algorithm = "histogram",
  })
  ---@cast hunks integer[][]
  local applied = {}
  api.nvim_buf_call(buf, function()
    -- Start a new undo block, so the user's last change is not undone with this one.
    vim.cmd("let &l:undolevels = &l:undolevels")
    local first = true
    -- From the bottom up, so earlier hunks keep their line numbers.
    for index = #hunks, 1, -1 do
      local start_a, count_a, start_b, count_b = unpack(hunks[index])
      local replacement = vim.list_slice(new, start_b, start_b + count_b - 1)
      -- For a pure insertion, diff gives the line after which to insert.
      local from = count_a == 0 and start_a or start_a - 1
      if not first then
        pcall(vim.cmd.undojoin)
      end
      first = false
      api.nvim_buf_set_lines(buf, from, from + count_a, false, replacement)
      table.insert(applied, 1, { start = start_b, count = count_b, lines = replacement })
    end
  end)
  if vim.bo[buf].eol ~= eol and not (eol and vim.bo[buf].fixeol) then
    vim.bo[buf].eol = eol
  end
  return applied
end

-- Write the buffer like :write does, autocommands and all, creating missing directories.
function M.save(buf)
  local ok, err = pcall(api.nvim_buf_call, buf, function()
    vim.cmd("silent write ++p")
  end)
  if not ok then
    return false, tostring(err)
  end
  return true
end

return M
