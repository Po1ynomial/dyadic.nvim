local H = dofile("tests/helpers.lua")
local eq = H.expect.equality
local child = H.new_child()

local T = MiniTest.new_set({
  hooks = {
    pre_case = child.setup,
    post_once = child.stop,
  },
})

-- Records every request dyadic sends; returns the decoded lines.
local function sent(log)
  local records = {}
  for _, line in ipairs(vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}) do
    records[#records + 1] = vim.json.decode(line)
  end
  return records
end

local function responses(log)
  return vim.tbl_filter(function(r)
    return r.type == "extension_ui_response"
  end, sent(log))
end

local function emit(events)
  child.lua("_G.S:request('test_emit', { events = ... })", { events })
end

T["select is answered once through vim.ui.select"] = function()
  local log = vim.fn.tempname()
  child.open({ log = log })
  child.lua("vim.ui.select = function(items, _, on_choice) on_choice(items[2]) end")
  local request =
    { type = "extension_ui_request", id = "d1", method = "select", title = "Pick", options = { "a", "b" } }
  emit({ request, request })
  child.settle(150)
  eq(responses(log), { { type = "extension_ui_response", id = "d1", value = "b" } })
end

T["confirm maps the answer to confirmed"] = function()
  local log = vim.fn.tempname()
  child.open({ log = log })
  child.lua("vim.ui.select = function(_, _, on_choice) on_choice('No') end")
  emit({ { type = "extension_ui_request", id = "d2", method = "confirm", title = "Sure?", message = "x" } })
  child.settle(150)
  eq(responses(log), { { type = "extension_ui_response", id = "d2", confirmed = false } })
end

T["closing the conversation cancels a pending dialog"] = function()
  local log = vim.fn.tempname()
  child.open({ log = log })
  child.lua("vim.ui.input = function() end")
  emit({ { type = "extension_ui_request", id = "d3", method = "input", title = "Name" } })
  child.settle(150)
  child.lua("_G.S:close()")
  child.wait("_G.S.rpc._finished == true")
  eq(responses(log), { { type = "extension_ui_response", id = "d3", cancelled = true } })
end

T["set_editor_text replaces the draft"] = function()
  child.open()
  emit({ { type = "extension_ui_request", id = "d4", method = "set_editor_text", text = "from extension" } })
  child.wait("_G.S:get_draft() == 'from extension'")
end

return T
