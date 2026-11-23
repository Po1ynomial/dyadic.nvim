-- blink.cmp source for the composer. dyadic registers it itself (see dyadic.completion);
-- it can also be configured by hand as `module = "dyadic.completion.blink"`.
local Completion = require("dyadic.completion")

local Source = {}
Source.__index = Source

-- Not Function or Method: blink.cmp would add brackets to those.
local KINDS = {
  builtin = "Keyword",
  extension = "Module",
  prompt = "Snippet",
  skill = "Reference",
  setting = "Property",
  value = "Value",
  model = "Value",
  file = "File",
  directory = "Folder",
}

function Source.new(opts)
  return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled()
  return Completion.agent(vim.api.nvim_get_current_buf()) ~= nil
end

function Source:get_trigger_characters()
  return { "/", "@" }
end

local function to_blink(item, row, ctx, col)
  local kinds = require("blink.cmp.types").CompletionItemKind
  return {
    label = item.label,
    filterText = item.label,
    sortText = item.sort,
    kind = kinds[KINDS[item.kind]],
    textEdit = {
      newText = item.word,
      range = {
        start = { line = row - 1, character = ctx.start },
        ["end"] = { line = row - 1, character = col },
      },
    },
    labelDetails = item.menu and { description = item.menu } or nil,
    documentation = item.doc and { kind = "markdown", value = item.doc } or nil,
    data = { dyadic = { path = item.path, reshow = item.reshow } },
  }
end

function Source:get_completions(context, callback)
  local agent = Completion.agent(context.bufnr)
  local row, col = context.cursor[1], context.cursor[2]
  local ctx = agent and Completion.context(context.line, row, col)
  if not ctx then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end
  local cancelled = false
  Completion.items(agent, ctx, { match = "fuzzy" }, function(items)
    if cancelled then
      return
    end
    callback({
      items = vim.tbl_map(function(item)
        return to_blink(item, row, ctx, col)
      end, items),
      is_incomplete_forward = false,
      -- Results were narrowed to the typed text; deleting some of it needs a new answer.
      is_incomplete_backward = true,
    })
  end)
  return function()
    cancelled = true
  end
end

function Source:resolve(item, callback)
  local data = item.data and item.data.dyadic
  if data and data.path and not item.documentation then
    item = vim.deepcopy(item)
    item.documentation = { kind = "markdown", value = Completion.preview(data.path) }
  end
  callback(item)
end

-- The id blink.cmp knows this source by: dyadic's own, or the one a config gave it.
local function provider_id()
  local ok, config = pcall(require, "blink.cmp.config")
  for id, provider in pairs(ok and config.sources.providers or {}) do
    if provider.module == "dyadic.completion.blink" then
      return id
    end
  end
end

function Source:execute(_, item, callback, default_implementation)
  default_implementation()
  local data = item.data and item.data.dyadic
  if data and data.reshow then
    -- The accepted text ends in a space, which triggers nothing; open the arguments. Not
    -- before the cursor move the accepted text causes: blink.cmp hides its menu on that.
    -- The space the accepted text ends in always moves the cursor.
    vim.api.nvim_create_autocmd("CursorMovedI", {
      buffer = vim.api.nvim_get_current_buf(),
      once = true,
      callback = function()
        vim.schedule(function()
          local ok, blink = pcall(require, "blink.cmp")
          local id = ok and provider_id()
          if id and Completion.agent(vim.api.nvim_get_current_buf()) then
            blink.show({ providers = { id } })
          end
        end)
      end,
    })
  end
  callback()
end

return Source
