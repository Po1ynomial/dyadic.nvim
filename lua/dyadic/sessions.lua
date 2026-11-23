-- Saved pi sessions: reading session files without pi.
local M = {}
local uv = vim.uv

-- The header of a session file, its first line, or nil when the file has none yet.
function M.header(path)
  local fd = type(path) == "string" and path ~= "" and uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local text = uv.fs_read(fd, 65536, 0) or ""
  uv.fs_close(fd)
  local line = text:match("^([^\n]*)\n") or text
  local ok, header = pcall(vim.json.decode, (line:gsub("^\239\187\191", "")))
  if ok and type(header) == "table" and header.type == "session" and type(header.cwd) == "string" then
    return header
  end
end

return M
