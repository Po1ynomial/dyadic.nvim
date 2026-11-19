local H = dofile("tests/helpers.lua")
local eq = H.eq
local T = H.suite()

local function roles(messages)
  return vim.tbl_map(function(message)
    return message._entry_id .. ":" .. message.role
  end, messages)
end

T("entries kept by a compaction follow its summary", function()
  local entries = H.chain({
    { role = "user", content = "dropped", timestamp = 1 },
    { role = "user", content = "kept", timestamp = 2 },
    { role = "assistant", content = {}, timestamp = 3 },
    { type = "compaction", summary = "Earlier work", firstKeptEntryId = "e2" },
    { role = "user", content = "after", timestamp = 4 },
  })
  local messages = require("dyadic.history").messages(entries, "e5")
  eq(roles(messages), { "e4:compactionSummary", "e2:user", "e3:assistant", "e5:user" })
end)

T("only the branch up to the leaf is shown", function()
  local entries = H.chain({
    { role = "user", content = "one", timestamp = 1 },
    { role = "user", content = "two", timestamp = 2 },
  })
  eq(roles(require("dyadic.history").messages(entries, "e1")), { "e1:user" })
end)

return T
