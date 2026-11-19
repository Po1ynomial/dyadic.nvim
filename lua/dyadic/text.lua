-- Text helpers shared by rendering, details, and extension UI.
local M = {}

-- Strip terminal control sequences and control characters; normalize line endings.
function M.clean(value)
  local text = value == nil and "" or tostring(value)
  text = text:gsub("\27%][^\7]*\7", ""):gsub("\27%].-\27\\", "")
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", ""):gsub("\27[@-_]", "")
  return (text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("[%z\1-\8\11\12\14-\31\127]", ""))
end

function M.lines_of(text)
  return vim.split(M.clean(text), "\n", { plain = true })
end

function M.one_line(text)
  return (M.clean(text):gsub("%s*\n%s*", " "))
end

-- Shorten to at most `width` display cells, marking the cut with an ellipsis.
function M.truncate(text, width)
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

function M.sorted_keys(t)
  local keys = {}
  for key in pairs(t or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

-- Indented JSON with sorted keys. vim.json.encode has no indent option before Neovim 0.12.
function M.json(value, indent)
  indent = indent or ""
  if value == nil or value == vim.NIL then
    return "null"
  end
  if type(value) ~= "table" then
    local ok, encoded = pcall(vim.json.encode, value)
    return ok and encoded or vim.json.encode(tostring(value))
  end
  if next(value) == nil then
    return vim.islist(value) and "[]" or "{}"
  end
  local inner, parts = indent .. "  ", {}
  if vim.islist(value) then
    for _, item in ipairs(value) do
      parts[#parts + 1] = inner .. M.json(item, inner)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  for _, key in ipairs(M.sorted_keys(value)) do
    parts[#parts + 1] = inner .. vim.json.encode(tostring(key)) .. ": " .. M.json(value[key], inner)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

-- Readable text for an arbitrary value: strings as-is, everything else as JSON.
function M.describe(value)
  if type(value) == "string" then
    return M.clean(value)
  end
  if value == nil or value == vim.NIL then
    return ""
  end
  return M.clean(M.json(value))
end

function M.content_text(content)
  if type(content) == "string" then
    return M.clean(content)
  end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "text" then
      parts[#parts + 1] = M.clean(block.text)
    elseif block.type == "image" then
      parts[#parts + 1] = "[Image: " .. M.one_line(block.mimeType or "unknown format") .. "]"
    end
  end
  return table.concat(parts, "\n")
end

return M
