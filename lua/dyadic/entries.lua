local M = {}

-- Pi renders raw context entries, not context_edit replacements used by the model.
function M.messages(entries, leaf_id)
  local by_id, branch, seen = {}, {}, {}
  for _, entry in ipairs(entries) do
    by_id[entry.id] = entry
  end
  local id = leaf_id
  while id and id ~= vim.NIL and by_id[id] and not seen[id] do
    seen[id] = true
    table.insert(branch, 1, by_id[id])
    id = by_id[id].parentId
  end
  local boundary, kept
  for i, entry in ipairs(branch) do
    if entry.type == "compaction" then
      boundary = i
    end
  end
  -- Like pi's context: the latest compaction's summary, then the entries it kept, then the rest.
  local order = {}
  if boundary then
    local first = branch[boundary].firstKeptEntryId
    kept = boundary
    for i = 1, boundary do
      if branch[i].id == first then
        kept = i
        break
      end
    end
    order[1] = boundary
    for i = kept, boundary - 1 do
      order[#order + 1] = i
    end
    for i = boundary + 1, #branch do
      order[#order + 1] = i
    end
  else
    for i = 1, #branch do
      order[i] = i
    end
  end
  local messages = {}
  for _, i in ipairs(order) do
    local entry = branch[i]
    local message
    if entry.type == "message" and type(entry.message) == "table" then
      message = vim.tbl_extend("force", {}, entry.message)
    elseif entry.type == "custom_message" then
      message = {
        role = "custom",
        customType = entry.customType,
        content = entry.content,
        display = entry.display,
        details = entry.details,
        timestamp = entry.timestamp,
      }
    elseif entry.type == "compaction" then
      message = {
        role = "compactionSummary",
        summary = entry.summary,
        tokensBefore = entry.tokensBefore,
        timestamp = entry.timestamp,
      }
    elseif entry.type == "branch_summary" then
      message = { role = "branchSummary", summary = entry.summary, fromId = entry.fromId, timestamp = entry.timestamp }
    end
    -- Entry IDs stay stable across history re-fetches, so rendering can cache by them.
    if message then
      message._entry_id = entry.id
    end
    -- Earlier summaries in the retained range are valid context entries too.
    if message and not (boundary and i < boundary and message.role == "system") then
      messages[#messages + 1] = message
    end
    if (entry.type == "compaction" or entry.type == "branch_summary" or entry.type == "usage") and entry.usage then
      local usage = entry.usage
      messages[#messages + 1] = {
        role = "usage",
        _entry_id = entry.id and entry.id .. ":usage",
        kind = entry.kind or entry.type,
        usage = usage,
        content = string.format(
          "%s: %s tokens billed, $%.4f",
          entry.kind or entry.type,
          tostring(usage.totalTokens or 0),
          (usage.cost or {}).total or 0
        ),
      }
    end
  end
  return messages
end

return M
