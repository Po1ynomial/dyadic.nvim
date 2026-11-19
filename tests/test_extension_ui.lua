local H = dofile("tests/helpers.lua")
local eq = H.eq
local T = H.suite()

local function responses(log)
  return vim.tbl_filter(function(record)
    return record.type == "extension_ui_response"
  end, H.sent(log))
end

T("select is answered once through vim.ui.select", function()
  local log = vim.fn.tempname()
  local s = H.open({ log = log })
  vim.ui.select = function(items, _, on_choice)
    on_choice(items[2])
  end
  local request =
    { type = "extension_ui_request", id = "d1", method = "select", title = "Pick", options = { "a", "b" } }
  H.emit(s, { request, request })
  H.settle(150)
  eq(responses(log), { { type = "extension_ui_response", id = "d1", value = "b" } })
end)

T("confirm maps the answer to confirmed", function()
  local log = vim.fn.tempname()
  local s = H.open({ log = log })
  vim.ui.select = function(_, _, on_choice)
    on_choice("No")
  end
  H.emit(s, { { type = "extension_ui_request", id = "d2", method = "confirm", title = "Sure?", message = "x" } })
  H.settle(150)
  eq(responses(log), { { type = "extension_ui_response", id = "d2", confirmed = false } })
end)

T("closing the conversation cancels a pending dialog", function()
  local log = vim.fn.tempname()
  local s = H.open({ log = log })
  vim.ui.input = function() end
  H.emit(s, { { type = "extension_ui_request", id = "d3", method = "input", title = "Name" } })
  H.settle(150)
  s:close()
  H.wait(function()
    return s.rpc._finished == true
  end)
  eq(responses(log), { { type = "extension_ui_response", id = "d3", cancelled = true } })
end)

T("set_editor_text replaces the draft", function()
  local s = H.open()
  H.emit(s, { { type = "extension_ui_request", id = "d4", method = "set_editor_text", text = "from extension" } })
  H.wait(function()
    return s:get_draft() == "from extension"
  end)
end)

return T
