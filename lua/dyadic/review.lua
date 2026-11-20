-- Reviews: an agent's proposed change to a file lands in the file's buffer as ordinary
-- edits, marked hunk by hunk, and the tool call waits until the user has decided every hunk.
-- Reviewed changes are never saved (docs/adr/0003-reviewed-changes-stay-unsaved.md).
local M = {}
local api = vim.api
local Files = require("dyadic.files")

local ns = api.nvim_create_namespace("dyadic_review")

M.default_keys = {
  next = "]c",
  prev = "[c",
  accept = "ga",
  reject = "gs",
  reject_reason = "gS",
  accept_all = "gA",
}

local reviews = {} -- buffer -> the open review
local waiting = {} -- buffer -> { agent, start } entries that start once its review ends

local function valid_buf(buf)
  return buf and api.nvim_buf_is_valid(buf)
end

-- `review` may be a boolean or { default, paths, keys }.
function M.options(config)
  local value = config.review
  if type(value) ~= "table" then
    value = { default = value == true }
  end
  return {
    default = value.default == true,
    paths = type(value.paths) == "table" and value.paths or {},
    keys = vim.tbl_extend("force", M.default_keys, type(value.keys) == "table" and value.keys or {}),
  }
end

local function expand(path, cwd)
  path = vim.fs.normalize(path)
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.joinpath(cwd, path)
  end
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

-- The real path of a file that may not exist yet: its nearest existing parent's, resolved.
local function real_file(path)
  local current, rest = vim.fs.normalize(path), {}
  while not vim.uv.fs_realpath(current) do
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    table.insert(rest, 1, vim.fs.basename(current))
    current = parent
  end
  return vim.fs.joinpath(vim.uv.fs_realpath(current) or current, unpack(rest))
end

-- Whether a change to `path` is reviewed: the agent's switch, else the nearest review
-- rule above the file, else the default.
function M.enabled(agent, path)
  if agent.review_switch ~= nil then
    return agent.review_switch
  end
  local options = M.options(agent.config)
  local file = real_file(path)
  local best, depth
  for rule, value in pairs(options.paths) do
    local root = expand(rule, agent.cwd)
    if root == "/" or file == root or file:sub(1, #root + 1) == root .. "/" then
      if not depth or #root > depth then
        best, depth = value, #root
      end
    end
  end
  if best ~= nil then
    return best == true
  end
  return options.default
end

local function display(agent, path)
  local cwd = vim.fs.normalize(agent.cwd or "")
  if cwd ~= "" and path:sub(1, #cwd + 1) == cwd .. "/" then
    return path:sub(#cwd + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

-- Where a hunk is now: buffer rows [first, last) of its lines; a deletion has first == last.
local function range(review, hunk)
  if not hunk.mark then
    return nil
  end
  local mark = api.nvim_buf_get_extmark_by_id(review.buf, ns, hunk.mark, { details = true })
  if not mark or not mark[1] then
    return nil
  end
  local first = mark[1]
  if hunk.count == 0 then
    -- A deletion marks the line after it, or the last line when nothing follows.
    local at = hunk.below and first + 1 or first
    return at, at
  end
  -- A hunk that reaches the end of the buffer has no line after it to end on.
  local last = hunk.to_end and api.nvim_buf_line_count(review.buf) or (mark[3].end_row or first)
  return first, math.max(last, first + 1)
end

local function pending(review)
  local list = {}
  for _, hunk in ipairs(review.hunks) do
    if hunk.state == "pending" then
      list[#list + 1] = hunk
    end
  end
  return list
end

-- Pending hunks of an agent's reviews, for the composer's bar.
function M.pending(agent)
  local count = 0
  for _, review in pairs(reviews) do
    if review.agent == agent then
      count = count + #pending(review)
    end
  end
  return count
end

local function hint(review)
  local keys = M.options(review.agent.config).keys
  local parts = {}
  for _, item in ipairs({ { "accept", "accept" }, { "reject", "reject" }, { "reject_reason", "reason" } }) do
    local key = keys[item[1]]
    if type(key) == "string" and key ~= "" then
      parts[#parts + 1] = key .. " " .. item[2]
    end
  end
  return table.concat(parts, " · ")
end

local function draw(review, hunk, index)
  local deleted = {}
  for _, line in ipairs(hunk.old) do
    deleted[#deleted + 1] = { { line, "DyadicReviewDelete" } }
  end
  local count = api.nvim_buf_line_count(review.buf)
  local row = hunk.start - 1
  local opts = {
    virt_lines = #deleted > 0 and deleted or nil,
    virt_lines_above = true,
    virt_text = { { string.format("  %d/%d  %s", index, #review.hunks, hint(review)), "DyadicReviewHint" } },
    virt_text_pos = "eol",
  }
  if hunk.count > 0 then
    opts.end_row = row + hunk.count
    opts.end_col = 0
    opts.hl_group = "DyadicReviewAdd"
    opts.hl_eol = true
    -- Grow with lines replaced or added at either edge, so edits there stay in the hunk.
    opts.right_gravity = false
    opts.end_right_gravity = true
    if opts.end_row >= count then
      hunk.to_end = true
      opts.end_row = count - 1
      opts.end_col = #(api.nvim_buf_get_lines(review.buf, count - 1, count, false)[1] or "")
    end
  elseif row >= count then
    -- A deletion at the end shows below the last line.
    row, hunk.below, opts.virt_lines_above = count - 1, true, false
  end
  hunk.mark = api.nvim_buf_set_extmark(review.buf, ns, math.max(0, row), 0, opts)
end

-- The text that should be in the buffer if nobody touched it: the original with the
-- accepted hunks applied.
local function expected(review)
  local result, line = {}, 1
  for _, hunk in ipairs(review.hunks) do
    local first = hunk.old_count == 0 and hunk.old_start + 1 or hunk.old_start
    while line < first do
      result[#result + 1] = review.original[line]
      line = line + 1
    end
    if hunk.state == "accepted" then
      vim.list_extend(result, hunk.lines)
    else
      vim.list_extend(result, hunk.old)
    end
    line = line + hunk.old_count
  end
  while line <= #review.original do
    result[#result + 1] = review.original[line]
    line = line + 1
  end
  return result
end

local function where(hunk)
  if hunk.old_count == 0 then
    return hunk.old_start == 0 and "at the start" or ("after line " .. hunk.old_start)
  elseif hunk.old_count == 1 then
    return "line " .. hunk.old_start
  end
  return string.format("lines %d–%d", hunk.old_start, hunk.old_start + hunk.old_count - 1)
end

-- What the tool result says about a finished review.
local function outcome(review)
  local accepted, rejected = 0, {}
  for _, hunk in ipairs(review.hunks) do
    if hunk.state == "accepted" then
      accepted = accepted + 1
    else
      rejected[#rejected + 1] = "- "
        .. where(hunk)
        .. (hunk.reason and hunk.reason ~= "" and (": " .. hunk.reason) or " (no reason)")
    end
  end
  local wanted = expected(review)
  local actual = api.nvim_buf_get_lines(review.buf, 0, -1, false)
  local edited = not vim.deep_equal(wanted, actual) and " The user also edited the file during the review." or ""
  local path = display(review.agent, review.path)
  if accepted == #review.hunks then
    return { note = "Accepted by the user; unsaved in the editor." .. edited }
  elseif accepted == 0 then
    return { error = "The user rejected the change to " .. path .. ".\n" .. table.concat(rejected, "\n") }
  end
  local before = table.concat(review.original, "\n") .. "\n"
  local after = table.concat(wanted, "\n") .. "\n"
  return {
    text = string.format(
      "The user accepted %d of %d hunks in %s; unsaved in the editor.%s Rejected:\n%s",
      accepted,
      #review.hunks,
      path,
      edited,
      table.concat(rejected, "\n")
    ),
    diff = Files.diff(before, after, { result_type = "unified", ctxlen = 3 }),
  }
end

local function restore_keys(review)
  for lhs, saved in pairs(review.keys or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = review.buf })
    if saved ~= false then
      api.nvim_buf_call(review.buf, function()
        vim.fn.mapset("n", false, saved)
      end)
    end
  end
  review.keys = nil
end

local function start_next(buf)
  local queue = waiting[buf]
  local entry = queue and table.remove(queue, 1)
  if queue and #queue == 0 then
    waiting[buf] = nil
  end
  if entry then
    entry.start()
  end
end

-- End a review. Aborted, undecided hunks are reverted and nothing is reported.
local function finish(review, aborted)
  if review.done then
    return
  end
  if aborted then
    review.applying = true
    for index = #review.hunks, 1, -1 do
      local hunk = review.hunks[index]
      if hunk.state == "pending" and valid_buf(review.buf) then
        local first, last = range(review, hunk)
        if first and last then
          api.nvim_buf_set_lines(review.buf, first, last, false, hunk.old)
        end
        hunk.state = "rejected"
      end
    end
    review.applying = false
  end
  review.done = true
  reviews[review.buf] = nil
  local result = not aborted and valid_buf(review.buf) and outcome(review) or nil
  if valid_buf(review.buf) then
    api.nvim_buf_clear_namespace(review.buf, ns, 0, -1)
    restore_keys(review)
    -- A rejected new file leaves nothing behind.
    if review.created and vim.fn.filereadable(review.path) == 0 and result and result.error then
      pcall(api.nvim_buf_delete, review.buf, { force = true })
    end
  end
  if result then
    review.reply(result)
  end
  review.agent:render()
  start_next(review.buf)
end

local function jump_to(review, hunk)
  local first = range(review, hunk)
  if not first then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(review.buf)) do
    if win == api.nvim_get_current_win() then
      api.nvim_win_set_cursor(win, { math.min(first + 1, api.nvim_buf_line_count(review.buf)), 0 })
    end
  end
end

-- The hunk at the cursor, or the next pending one after it, or the first pending one.
local function current_hunk(review)
  local line = api.nvim_get_current_buf() == review.buf and api.nvim_win_get_cursor(0)[1] - 1 or 0
  local list = pending(review)
  for _, hunk in ipairs(list) do
    local first, last = range(review, hunk)
    if first and last and line >= first and line < math.max(last, first + 1) then
      return hunk
    end
  end
  for _, hunk in ipairs(list) do
    local first = range(review, hunk)
    if first and first >= line then
      return hunk
    end
  end
  return list[1]
end

local function after_decision(review)
  if #pending(review) == 0 then
    finish(review, false)
    return
  end
  local next_hunk = current_hunk(review)
  if next_hunk then
    jump_to(review, next_hunk)
  end
  review.agent:render()
end

local function decide(review, hunk, accept, reason)
  if not hunk or hunk.state ~= "pending" then
    return
  end
  if not accept then
    local first, last = range(review, hunk)
    if first and last then
      review.applying = true
      api.nvim_buf_set_lines(review.buf, first, last, false, hunk.old)
      review.applying = false
    end
  end
  api.nvim_buf_del_extmark(review.buf, ns, hunk.mark)
  hunk.mark = nil
  hunk.state = accept and "accepted" or "rejected"
  hunk.reason = reason
end

-- Accept or reject the hunk at the cursor, or every pending hunk.
function M.decide(review, accept, all, reason)
  if review.done then
    return
  end
  if all then
    -- Bottom up, so reverting one hunk does not move the others' ranges before use.
    local list = pending(review)
    for index = #list, 1, -1 do
      decide(review, list[index], accept, reason)
    end
  else
    decide(review, current_hunk(review), accept, reason)
  end
  after_decision(review)
end

local function ask_reason(review, all)
  vim.ui.input({ prompt = "Reason for rejecting: " }, function(reason)
    if reason ~= nil and not review.done then
      M.decide(review, false, all, vim.trim(reason))
    end
  end)
end

local function move(review, forward)
  local line = api.nvim_win_get_cursor(0)[1] - 1
  local target
  for _, hunk in ipairs(pending(review)) do
    local first = range(review, hunk)
    if first then
      if forward and first > line and (not target or first < target) then
        target = first
      elseif not forward and first < line and (not target or first > target) then
        target = first
      end
    end
  end
  if target then
    api.nvim_win_set_cursor(0, { math.min(target + 1, api.nvim_buf_line_count(review.buf)), 0 })
  end
end

local function bind(review)
  local keys = M.options(review.agent.config).keys
  local actions = {
    next = function()
      move(review, true)
    end,
    prev = function()
      move(review, false)
    end,
    accept = function()
      M.decide(review, true, false)
    end,
    reject = function()
      M.decide(review, false, false)
    end,
    reject_reason = function()
      ask_reason(review, false)
    end,
    accept_all = function()
      M.decide(review, true, true)
    end,
  }
  review.keys = {}
  for name, fn in pairs(actions) do
    local lhs = keys[name]
    if type(lhs) == "string" and lhs ~= "" then
      -- Keep the user's own buffer-local mapping to put back afterwards.
      local saved = api.nvim_buf_call(review.buf, function()
        return vim.fn.maparg(lhs, "n", false, true)
      end)
      review.keys[lhs] = (saved.buffer == 1) and saved or false
      vim.keymap.set(
        "n",
        lhs,
        fn,
        { buffer = review.buf, silent = true, nowait = true, desc = "Dyadic review " .. name }
      )
    end
  end
end

local function begin(agent, buf, path, content, reply, created)
  local original = api.nvim_buf_get_lines(buf, 0, -1, false)
  local review = { agent = agent, buf = buf, path = path, reply = reply, original = original, created = created }
  review.applying = true
  local hunks = Files.apply(buf, content)
  review.applying = false
  if #hunks == 0 then
    reply({})
    start_next(buf)
    return
  end
  for _, hunk in ipairs(hunks) do
    hunk.state = "pending"
  end
  review.hunks = hunks
  reviews[buf] = review
  for index, hunk in ipairs(hunks) do
    draw(review, hunk, index)
  end
  bind(review)
  -- Editing inside an undecided hunk accepts it, with the user's changes.
  api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      if review.done then
        return true
      end
      if review.applying then
        return
      end
      local last = math.max(last_old, last_new)
      local touched = false
      for _, hunk in ipairs(review.hunks) do
        if hunk.state == "pending" then
          local from, to = range(review, hunk)
          if from and to and first <= math.max(to, from + 1) - 1 and last > from then
            hunk.state, touched = "accepted", true
          end
        end
      end
      if touched then
        vim.schedule(function()
          if not review.done then
            for _, hunk in ipairs(review.hunks) do
              if hunk.state == "accepted" and hunk.mark then
                pcall(api.nvim_buf_del_extmark, review.buf, ns, hunk.mark)
                hunk.mark = nil
              end
            end
            after_decision(review)
          end
        end)
      end
    end,
  })
  agent:render()
end

-- Review `content` for the file `path` in buffer `buf`, then `reply(outcome)`. `base` is the
-- text pi changed; if the buffer no longer holds it, the change is refused. Reviews of one
-- buffer run one at a time.
function M.request(agent, buf, path, content, base, reply, created)
  local function start()
    if agent.closed or not valid_buf(buf) then
      reply({ error = "The file's buffer closed before the review started." })
      start_next(buf)
      return
    end
    if Files.text(buf) ~= base then
      reply({ error = "The file changed in the editor since this edit read it; read it again." })
      start_next(buf)
      return
    end
    begin(agent, buf, path, content, reply, created)
  end
  if reviews[buf] then
    waiting[buf] = waiting[buf] or {}
    table.insert(waiting[buf], { agent = agent, start = start })
  else
    start()
  end
end

-- End an agent's open and waiting reviews, for example when its run was aborted.
function M.abort(agent)
  for buf, queue in pairs(waiting) do
    waiting[buf] = vim.tbl_filter(function(entry)
      return entry.agent ~= agent
    end, queue)
  end
  for _, review in ipairs(vim.tbl_values(reviews)) do
    if review.agent == agent then
      finish(review, true)
    end
  end
end

-- The review in a buffer, if any.
function M.get(buf)
  return reviews[buf or api.nvim_get_current_buf()]
end

-- An agent's first open review.
function M.first(agent)
  local found
  for _, review in pairs(reviews) do
    if review.agent == agent and (not found or review.buf < found.buf) then
      found = review
    end
  end
  return found
end

-- Show the agent's next undecided hunk, in a window of the main area when the buffer is
-- not visible in this tab.
function M.jump(agent)
  local review = M.first(agent)
  if not review then
    agent:notice("No open review")
    return
  end
  local win
  for _, candidate in ipairs(vim.fn.win_findbuf(review.buf)) do
    if api.nvim_win_get_tabpage(candidate) == api.nvim_get_current_tabpage() then
      win = candidate
      break
    end
  end
  if not win then
    win = require("dyadic.sidebar").main_window()
    api.nvim_win_set_buf(win, review.buf)
  end
  api.nvim_set_current_win(win)
  local hunk = current_hunk(review)
  if hunk then
    jump_to(review, hunk)
  end
end

-- :Dyadic review [on|off|auto|accept|reject] [all]
function M.command(agent, args)
  local action, scope = args[1], args[2]
  if not action then
    M.jump(agent)
  elseif action == "on" or action == "off" or action == "auto" then
    if action == "auto" then
      agent.review_switch = nil
    else
      agent.review_switch = action == "on"
    end
    agent:notice(
      action == "auto" and "Review follows the review rules for this agent"
        or ("Review " .. action .. " for this agent")
    )
    agent:render()
  elseif action == "accept" or action == "reject" then
    local review = M.get()
    if not review then
      agent:notice("No review in this buffer", "warning")
      return
    end
    M.decide(review, action == "accept", scope == "all")
  else
    agent:notice("Usage: :Dyadic review [on|off|auto|accept|reject] [all]", "error")
  end
end

return M
