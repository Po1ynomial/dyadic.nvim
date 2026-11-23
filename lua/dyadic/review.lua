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

-- A rule's path, resolved like the files it is matched against, even before it exists.
local function expand(path, cwd)
  path = vim.fs.normalize(path)
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.joinpath(cwd, path)
  end
  return Files.real_file(path)
end

-- Whether a change to `path` is reviewed: the agent's switch, else the nearest review
-- rule above the file, else the default. Rules and files are compared by where they
-- really are, so a file reached through a symlink follows the rules of its target.
function M.enabled(agent, path)
  if agent.review_switch ~= nil then
    return agent.review_switch
  end
  local options = M.options(agent.config)
  local file = Files.real_file(path)
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

-- Word-level differences between a removed line and the added line paired with it.

-- Words (with any non-ASCII bytes), runs of spaces, and single ASCII punctuation marks, as
-- byte ranges [s, e).
local function tokens(line)
  local list, i = {}, 1
  while i <= #line do
    local _, e = line:find("^[%w_\128-\255]+", i)
    if not e then
      _, e = line:find("^%s+", i)
    end
    e = e or i
    list[#list + 1] = { s = i - 1, e = e }
    i = e + 1
  end
  return list
end

local MAX_LINE_BYTES = 1000
local MAX_PAIRED_LINES = 200

-- Changed byte ranges of `old` and `new`, or nil when the lines have too little in common
-- for word highlights to help.
local function word_spans(old, new)
  if #old > MAX_LINE_BYTES or #new > MAX_LINE_BYTES or vim.trim(old) == "" or vim.trim(new) == "" then
    return nil
  end
  local a, b = tokens(old), tokens(new)
  local function joined(line, list)
    local parts = {}
    for _, token in ipairs(list) do
      parts[#parts + 1] = line:sub(token.s + 1, token.e)
    end
    return table.concat(parts, "\n") .. "\n"
  end
  local blocks = Files.diff(joined(old, a), joined(new, b), { result_type = "indices" })
  ---@cast blocks integer[][]
  local old_spans, new_spans, changed = {}, {}, 0
  for _, block in ipairs(blocks) do
    local sa, ca, sb, cb = block[1], block[2], block[3], block[4]
    if ca > 0 then
      old_spans[#old_spans + 1] = { a[sa].s, a[sa + ca - 1].e }
    end
    if cb > 0 then
      new_spans[#new_spans + 1] = { b[sb].s, b[sb + cb - 1].e }
      changed = changed + b[sb + cb - 1].e - b[sb].s
    end
  end
  if #new - changed < 0.4 * math.max(#old, #new) then
    return nil
  end
  return old_spans, new_spans
end

-- Pair a hunk's removed and added lines in order and find their word differences.
local function find_words(hunk)
  hunk.old_words, hunk.new_words = {}, {}
  if hunk.count == 0 or hunk.old_count == 0 then
    return
  end
  for i = 1, math.min(hunk.count, hunk.old_count, MAX_PAIRED_LINES) do
    hunk.old_words[i], hunk.new_words[i] = word_spans(hunk.old[i], hunk.lines[i])
  end
end

-- Split `line` into { text, hl } chunks: `spans` in `strong`, the rest in `base`.
local function segments(line, spans, base, strong)
  local list, col = {}, 0
  for _, span in ipairs(spans or {}) do
    if span[1] > col then
      list[#list + 1] = { line:sub(col + 1, span[1]), base }
    end
    list[#list + 1] = { line:sub(span[1] + 1, span[2]), strong }
    col = span[2]
  end
  if col < #line then
    list[#list + 1] = { line:sub(col + 1), base }
  end
  return list
end

-- Lay chunks out as virtual lines the way the window shows a real line: tabs expanded,
-- wrapped at `view.width` cells when 'wrap' is set, at a 'breakat' character when
-- 'linebreak' is too, and each row padded with `fill` so its background reaches the edge.
local function layout(chunks, view, fill)
  local cells, vcol = {}, 0
  for _, chunk in ipairs(chunks) do
    for char in chunk[1]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local width = char == "\t" and (view.tabstop - vcol % view.tabstop) or vim.fn.strdisplaywidth(char)
      cells[#cells + 1] = {
        text = char == "\t" and string.rep(" ", width) or char,
        hl = chunk[2],
        width = width,
        brk = #char == 1 and view.breakat[char] or false,
      }
      vcol = vcol + width
    end
  end
  -- Rows as [first, last] cell ranges.
  local rows, first = {}, 1
  while first <= #cells do
    local used, last, brk, next_cell = 0, first - 1, nil, first
    while next_cell <= #cells do
      local width = cells[next_cell].width
      if view.wrap and used > 0 and used + width > view.width then
        break
      end
      used, last = used + width, next_cell
      if cells[next_cell].brk then
        brk = next_cell
      end
      next_cell = next_cell + 1
    end
    if next_cell <= #cells and view.linebreak and brk then
      last = brk
    end
    rows[#rows + 1] = { first, last }
    first = last + 1
  end
  if #rows == 0 then
    rows[1] = { 1, 0 }
  end
  local lines = {}
  for _, range in ipairs(rows) do
    local line, used = {}, 0
    for i = range[1], range[2] do
      local cell = cells[i]
      local previous = line[#line]
      if previous and previous[2] == cell.hl then
        previous[1] = previous[1] .. cell.text
      else
        line[#line + 1] = { cell.text, cell.hl }
      end
      used = used + cell.width
    end
    if fill and used < view.width then
      line[#line + 1] = { string.rep(" ", view.width - used), fill }
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- The banner over the hunk at the cursor: its number and the keys that act on it.
local function banner(review, hunk, width)
  local keys = M.options(review.agent.config).keys
  local items = { { { string.format("hunk %d/%d", hunk.index, #review.hunks), "DyadicReviewHint" } } }
  for _, item in ipairs({
    { "accept", "accept" },
    { "reject", "reject" },
    { "reject_reason", "reject with reason" },
    { "accept_all", "accept all" },
  }) do
    local key = keys[item[1]]
    if type(key) == "string" and key ~= "" then
      items[#items + 1] = { { key, "DyadicReviewKey" }, { " " .. item[2], "DyadicReviewHint" } }
    end
  end
  local moves = vim.tbl_filter(function(key)
    return type(key) == "string" and key ~= ""
  end, { keys.next, keys.prev })
  if #moves > 0 then
    items[#items + 1] = { { table.concat(moves, " "), "DyadicReviewKey" }, { " move", "DyadicReviewHint" } }
  end
  local lines, line, used = {}, {}, 0
  for _, item in ipairs(items) do
    local cells = 0
    for _, chunk in ipairs(item) do
      cells = cells + vim.fn.strdisplaywidth(chunk[1])
    end
    if used > 0 and used + 3 + cells > width then
      lines[#lines + 1], line, used = line, {}, 0
    end
    if used > 0 then
      line[#line + 1] = { " · ", "DyadicReviewHint" }
      used = used + 3
    end
    vim.list_extend(line, item)
    used = used + cells
  end
  lines[#lines + 1] = line
  return lines
end

-- How a review knows where its hunks are and what was decided.
--
-- The buffer's text is the truth, and the undo history holds the decisions. The agent's
-- change, and each accept or reject, is one undo step. After every change, undo and redo
-- included, each hunk is found by diffing the review's original text against the buffer,
-- and its state follows from what its lines show:
--   the agent's lines  pending, or accepted if an accept of it is in the undo path
--   the old lines      rejected
--   anything else      the user's edit: rejected if a reject of it is in the undo path,
--                      else accepted
-- Undoing past the agent's change ends the review as undone.

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

-- The buffer's lines as file content: an empty buffer has none.
local function content_lines(buf)
  if Files.text(buf) == "" then
    return {}
  end
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function joined(lines)
  return #lines == 0 and "" or (table.concat(lines, "\n") .. "\n")
end

local function same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- Where the buffer differs from the original: { as, ae, bs, be } 0-based, end-exclusive
-- line ranges in the original and in the buffer.
local function changes(review, lines)
  local list = {}
  local raw = Files.diff(joined(review.original), joined(lines), { result_type = "indices", algorithm = "histogram" })
  ---@cast raw integer[][]
  for _, block in ipairs(raw) do
    local as = block[2] == 0 and block[1] or block[1] - 1
    local bs = block[4] == 0 and block[3] or block[3] - 1
    list[#list + 1] = { as = as, ae = as + block[2], bs = bs, be = bs + block[4] }
  end
  return list
end

-- What a hunk's place in the buffer shows ("new", "old", or "other"), and the row where
-- its own lines start. Changes that overlap the hunk, or for an insertion touch it, count
-- as part of it.
local function locate(review, hunk, blocks, lines)
  local s, e = hunk.s, hunk.e
  local us, ue, grow, hit = s, e, 0, {}
  for i, block in ipairs(blocks) do
    local overlaps
    if s == e then
      overlaps = block.as <= s and s <= block.ae
    else
      overlaps = (block.as < e and s < block.ae) or (block.as == block.ae and s < block.as and block.as < e)
    end
    if overlaps then
      hit[i] = true
      us, ue = math.min(us, block.as), math.max(ue, block.ae)
      grow = grow + (block.be - block.bs) - (block.ae - block.as)
    end
  end
  local shift = 0
  for i, block in ipairs(blocks) do
    if not hit[i] and block.ae <= us then
      shift = shift + (block.be - block.bs) - (block.ae - block.as)
    end
  end
  local first = us + shift
  local region = vim.list_slice(lines, first + 1, first + (ue - us) + grow)
  local before = vim.list_slice(review.original, us + 1, s)
  local after = vim.list_slice(review.original, e + 1, ue)
  local proposed = vim.list_extend(vim.list_extend(vim.list_extend({}, before), hunk.lines), after)
  if same(region, proposed) then
    return "new", first + (s - us)
  elseif same(region, vim.list_slice(review.original, us + 1, ue)) then
    return "old", first + (s - us)
  end
  return "other", first
end

-- End the current undo block, so the next change, even one typed right away, is a step of
-- its own.
local function close_step(buf)
  api.nvim_buf_call(buf, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
  end)
end

local function undo_seq(buf)
  return api.nvim_buf_call(buf, function()
    return vim.fn.undotree().seq_cur
  end)
end

-- The undo steps from the oldest state to the current one, as a set of sequence numbers.
local function undo_path(buf)
  local tree = api.nvim_buf_call(buf, function()
    return vim.fn.undotree()
  end)
  local function walk(entries, prefix)
    local path = vim.list_extend({}, prefix)
    for _, entry in ipairs(entries) do
      -- An alternate branch replaces this entry, so it follows the entries before it.
      if entry.alt then
        local found = walk(entry.alt, path)
        if found then
          return found
        end
      end
      path[#path + 1] = entry.seq
      if entry.seq == tree.seq_cur then
        return path
      end
    end
  end
  local set = {}
  for _, seq in ipairs(tree.seq_cur ~= 0 and walk(tree.entries, {}) or {}) do
    set[seq] = true
  end
  return set
end

-- The latest decision about `hunk` that is in effect.
local function decision(review, hunk, path)
  local found
  for _, step in ipairs(review.steps) do
    if step.hunks[hunk] and (not path or path[step.seq]) and (not found or step.seq >= found.seq) then
      found = step
    end
  end
  return found
end

-- The row a hunk is picked from and drawn at: its first added line, or for a deletion the
-- line its removed lines are drawn above, or the last line when nothing follows.
local function anchor(review, hunk)
  if hunk.count > 0 then
    return hunk.first
  end
  return math.min(hunk.first, api.nvim_buf_line_count(review.buf) - 1)
end

-- The window whose cursor picks the hunk: the current one, else one in this tab that shows
-- the buffer.
local function cursor_window(review)
  local current = api.nvim_get_current_win()
  if api.nvim_win_get_buf(current) == review.buf then
    return current
  end
  for _, win in ipairs(vim.fn.win_findbuf(review.buf)) do
    if api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage() then
      return win
    end
  end
end

-- How the window shows lines: text width, 'wrap', 'linebreak', 'breakat', 'tabstop'.
local function text_view(review, win)
  local breakat = {}
  for char in vim.o.breakat:gmatch(".") do
    breakat[char] = true
  end
  local view = { width = vim.o.columns, wrap = true, linebreak = false, breakat = breakat }
  view.tabstop = vim.bo[review.buf].tabstop
  if win then
    local info = vim.fn.getwininfo(win)[1]
    view.width = math.max(20, info.width - info.textoff)
    view.wrap, view.linebreak = vim.wo[win].wrap, vim.wo[win].linebreak
  end
  return view
end

-- Draw the pending hunks: added lines highlighted with word highlights, and above them the
-- banner, when the hunk is at the cursor, and the removed lines.
local function draw(review)
  local buf = review.buf
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local view = text_view(review, cursor_window(review))
  local count = api.nvim_buf_line_count(buf)
  for _, hunk in ipairs(pending(review)) do
    for i = 0, hunk.count - 1 do
      local row = hunk.first + i
      api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "DyadicReviewAdd" })
      for _, span in ipairs(hunk.new_words[i + 1] or {}) do
        api.nvim_buf_set_extmark(buf, ns, row, span[1], {
          end_col = span[2],
          hl_group = "DyadicReviewAddText",
          priority = 4097,
        })
      end
    end
    local virt = review.banner == hunk and banner(review, hunk, view.width) or {}
    for i, old in ipairs(hunk.old) do
      local chunks = segments(old, hunk.old_words[i], "DyadicReviewDelete", "DyadicReviewDeleteText")
      vim.list_extend(virt, layout(chunks, view, "DyadicReviewDelete"))
    end
    if #virt > 0 then
      -- A deletion at the end shows below the last line.
      local above = hunk.count > 0 or hunk.first < count
      api.nvim_buf_set_extmark(buf, ns, anchor(review, hunk), 0, { virt_lines = virt, virt_lines_above = above })
    end
  end
end

-- The text that should be in the buffer if nobody touched it: the original with the
-- accepted hunks applied.
local function expected(review)
  local result, line = {}, 1
  for _, hunk in ipairs(review.hunks) do
    while line <= hunk.s do
      result[#result + 1] = review.original[line]
      line = line + 1
    end
    vim.list_extend(result, hunk.state == "accepted" and hunk.lines or hunk.old)
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
  local edited = not same(wanted, content_lines(review.buf)) and " The user also edited the file during the review."
    or ""
  local path = display(review.agent, review.path)
  if accepted == #review.hunks then
    return { note = "Accepted by the user; unsaved in the editor." .. edited }
  elseif accepted == 0 then
    return { error = "The user rejected the change to " .. path .. ".\n" .. table.concat(rejected, "\n") }
  end
  return {
    text = string.format(
      "The user accepted %d of %d hunks in %s; unsaved in the editor.%s Rejected:\n%s",
      accepted,
      #review.hunks,
      path,
      edited,
      table.concat(rejected, "\n")
    ),
    diff = Files.diff(joined(review.original), joined(wanted), { result_type = "unified", ctxlen = 3 }),
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

-- Apply line edits { start, end, lines } as one undo step; returns the step's number.
local function step(review, edits)
  table.sort(edits, function(a, b)
    return a[1] > b[1]
  end)
  api.nvim_buf_call(review.buf, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
    for i, edit in ipairs(edits) do
      if i > 1 then
        pcall(vim.cmd.undojoin)
      end
      api.nvim_buf_set_lines(review.buf, edit[1], edit[2], false, edit[3])
    end
  end)
  close_step(review.buf)
  return undo_seq(review.buf)
end

-- The edit that accepts a pending hunk (its lines written again, so the accept is an undo
-- step) or rejects it (its old lines back).
local function edit_for(review, hunk, accept)
  if accept then
    local row = anchor(review, hunk)
    local last = hunk.count > 0 and row + hunk.count or row + 1
    return { row, last, api.nvim_buf_get_lines(review.buf, row, last, false) }
  end
  return { hunk.first, hunk.first + hunk.count, hunk.old }
end

-- After the review ended because its change was undone, a no-op change drops the redo, so
-- CTRL-R cannot bring the change back unreviewed. :undo N and g+ still can, deliberately.
local function drop_redo(buf)
  local modified = vim.bo[buf].modified
  api.nvim_buf_call(buf, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
    api.nvim_buf_set_lines(buf, 0, 1, false, api.nvim_buf_get_lines(buf, 0, 1, false))
  end)
  vim.bo[buf].modified = modified
end

-- End a review. `how`: nil when every hunk is decided; "aborted" reverts the pending hunks
-- and reports nothing; "undone" when the change was undone; "closed" when the buffer went.
local function finish(review, how)
  if review.done then
    return
  end
  local live = valid_buf(review.buf) and how ~= "closed"
  if how == "aborted" and live then
    local edits = {}
    for _, hunk in ipairs(pending(review)) do
      edits[#edits + 1] = edit_for(review, hunk, false)
      hunk.state = "rejected"
    end
    if #edits > 0 then
      step(review, edits)
    end
  end
  review.done = true
  reviews[review.buf] = nil
  if review.group then
    pcall(api.nvim_del_augroup_by_id, review.group)
  end
  local path = display(review.agent, review.path)
  local result
  if how == "undone" then
    result = { error = "The user undid the change to " .. path .. "." }
  elseif how == "closed" then
    result = { error = "The buffer of " .. path .. " was closed during the review; the change was dropped." }
  elseif how ~= "aborted" and live then
    result = outcome(review)
  end
  if live then
    api.nvim_buf_clear_namespace(review.buf, ns, 0, -1)
    restore_keys(review)
    -- A rejected new file leaves nothing behind.
    if review.created and vim.fn.filereadable(review.path) == 0 and result and result.error then
      Files.wipe(review.buf)
    elseif how == "undone" and review.undo then
      drop_redo(review.buf)
    end
  end
  if result then
    review.reply(result)
  end
  review.agent:render()
  start_next(review.buf)
end

-- Work out where each hunk is and its state, redraw, and end the review when nothing is
-- left to decide.
local function reconcile(review)
  review.dirty = false
  if review.done then
    return
  end
  if not valid_buf(review.buf) then
    finish(review, "closed")
    return
  end
  local path = review.undo and undo_path(review.buf)
  if path and not path[review.undo.applied] then
    finish(review, "undone")
    return
  end
  local before = #pending(review)
  local lines = content_lines(review.buf)
  local blocks = changes(review, lines)
  for _, hunk in ipairs(review.hunks) do
    local text, first = locate(review, hunk, blocks, lines)
    local made = decision(review, hunk, path)
    hunk.first = first
    if text == "new" then
      hunk.state = made and made.accept and "accepted" or "pending"
    elseif text == "old" or (made and not made.accept) then
      hunk.state = "rejected"
    else
      hunk.state = "accepted"
    end
    hunk.reason = hunk.state == "rejected" and made and not made.accept and made.reason or nil
  end
  if #pending(review) == 0 then
    finish(review, nil)
    return
  end
  if review.banner and review.banner.state ~= "pending" then
    review.banner = nil
  end
  draw(review)
  if #pending(review) ~= before then
    review.agent:render()
  end
end

-- Bring the review up to date with the buffer; false once it has ended.
local function sync(review)
  if review.dirty then
    reconcile(review)
  end
  return not review.done
end

-- The undecided hunk at the cursor of `win`, if any.
local function hunk_at(review, win)
  if not win then
    return nil
  end
  local line = api.nvim_win_get_cursor(win)[1] - 1
  for _, hunk in ipairs(pending(review)) do
    if hunk.count == 0 then
      if anchor(review, hunk) == line then
        return hunk
      end
    elseif line >= hunk.first and line < hunk.first + hunk.count then
      return hunk
    end
  end
end

-- Virtual lines above the first line show only with filler rows at the top of the view.
local function reveal_top(review, win)
  local hunk = review.banner
  if not (win and hunk and anchor(review, hunk) == 0 and (hunk.count > 0 or hunk.first == 0)) then
    return
  end
  api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    -- topfill must be exact; a larger value is ignored.
    local fill = api.nvim_win_text_height(win, { start_row = 0, end_row = 0 }).fill
    if view.topline == 1 and view.topfill < fill then
      vim.fn.winrestview({ topline = 1, topfill = fill })
    end
  end)
end

-- Put the banner on the hunk at the cursor.
local function follow_cursor(review)
  if not sync(review) or not valid_buf(review.buf) then
    return
  end
  local win = cursor_window(review)
  local hunk = hunk_at(review, win)
  if hunk ~= review.banner then
    review.banner = hunk
    draw(review)
  end
  reveal_top(review, win)
end

-- Move the cursor of the current window, when it shows the buffer, to a hunk.
local function jump_to(review, hunk)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= review.buf then
    return
  end
  api.nvim_win_set_cursor(win, { anchor(review, hunk) + 1, 0 })
  follow_cursor(review)
end

-- The first undecided hunk at or after `row`, else the first one.
local function next_from(review, row)
  local list = pending(review)
  for _, hunk in ipairs(list) do
    if anchor(review, hunk) >= row then
      return hunk
    end
  end
  return list[1]
end

-- Record a decision about `hunks` as one undo step and bring the review up to date.
local function decide(review, hunks, accept, reason)
  local edits, set = {}, {}
  for _, hunk in ipairs(hunks) do
    edits[#edits + 1] = edit_for(review, hunk, accept)
    set[hunk] = true
  end
  local seq = step(review, edits)
  review.steps[#review.steps + 1] = { seq = seq, accept = accept, hunks = set, reason = reason }
  reconcile(review)
end

-- After a decision at `row`: show the next undecided hunk.
local function after_decision(review, row)
  if review.done then
    return
  end
  local hunk = next_from(review, row or 0)
  if hunk then
    jump_to(review, hunk)
  end
  follow_cursor(review)
end

-- The hunk the keys act on: the one at the cursor. Says so when there is none.
local function target(review)
  local hunk = hunk_at(review, cursor_window(review))
  if not hunk then
    local keys = M.options(review.agent.config).keys
    local moves = vim.tbl_filter(function(key)
      return type(key) == "string" and key ~= ""
    end, { keys.next, keys.prev })
    review.agent:notice(
      "No hunk at the cursor" .. (#moves > 0 and ("; " .. table.concat(moves, " and ") .. " move to one") or ""),
      "warning"
    )
  end
  return hunk
end

-- Accept or reject the hunk at the cursor, or every undecided hunk.
function M.decide(review, accept, all, reason)
  if not sync(review) then
    return
  end
  if all then
    decide(review, pending(review), accept, reason)
    after_decision(review, 0)
    return
  end
  local hunk = target(review)
  if hunk then
    local row = anchor(review, hunk)
    decide(review, { hunk }, accept, reason)
    after_decision(review, row)
  end
end

local function ask_reason(review)
  if not sync(review) then
    return
  end
  local hunk = target(review)
  if not hunk then
    return
  end
  vim.ui.input({ prompt = string.format("Reason for rejecting hunk %d: ", hunk.index) }, function(reason)
    if reason ~= nil and sync(review) and hunk.state == "pending" then
      local row = anchor(review, hunk)
      decide(review, { hunk }, false, vim.trim(reason))
      after_decision(review, row)
    end
  end)
end

local function move(review, forward)
  if not sync(review) then
    return
  end
  local line = api.nvim_win_get_cursor(0)[1] - 1
  local best, best_row
  for _, hunk in ipairs(pending(review)) do
    local row = anchor(review, hunk)
    if forward and row > line and (not best_row or row < best_row) then
      best, best_row = hunk, row
    elseif not forward and row < line and (not best_row or row > best_row) then
      best, best_row = hunk, row
    end
  end
  if best then
    jump_to(review, best)
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
      ask_reason(review)
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

local function watch(review)
  review.group = api.nvim_create_augroup("DyadicReview" .. review.buf, { clear = true })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = review.group,
    buffer = review.buf,
    callback = function()
      follow_cursor(review)
    end,
  })
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = review.group,
    callback = function()
      vim.schedule(function()
        follow_cursor(review)
      end)
    end,
  })
  -- Removed lines are laid out for the window's width and 'wrap'.
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = review.group,
    callback = function()
      if sync(review) then
        draw(review)
      end
    end,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = review.group,
    pattern = {
      "wrap",
      "linebreak",
      "breakat",
      "tabstop",
      "number",
      "relativenumber",
      "signcolumn",
      "foldcolumn",
    },
    callback = function()
      if sync(review) then
        draw(review)
      end
    end,
  })
  -- Every change, undo and redo included, brings the review up to date once per tick.
  local function changed()
    if review.done then
      return true
    end
    if not review.dirty then
      review.dirty = true
      vim.schedule(function()
        if review.dirty then
          reconcile(review)
        end
      end)
    end
  end
  api.nvim_buf_attach(review.buf, false, {
    on_lines = changed,
    on_reload = changed,
    on_detach = function()
      vim.schedule(function()
        if not review.done then
          finish(review, "closed")
        end
      end)
    end,
  })
end

local function begin(agent, buf, path, content, reply, created)
  -- An empty buffer's one empty line is not content.
  local original = content_lines(buf)
  local review = {
    agent = agent,
    buf = buf,
    path = path,
    reply = reply,
    original = original,
    created = created,
    steps = {},
  }
  local base = undo_seq(buf)
  local hunks = Files.apply(buf, content)
  close_step(buf)
  if #hunks == 0 then
    reply({})
    start_next(buf)
    return
  end
  -- Without undo ('undolevels' -1), decisions always count and the change cannot be undone.
  local applied = undo_seq(buf)
  review.undo = applied ~= base and { applied = applied } or nil
  for index, hunk in ipairs(hunks) do
    hunk.index = index
    hunk.s = hunk.old_count == 0 and hunk.old_start or hunk.old_start - 1
    hunk.e = hunk.s + hunk.old_count
    find_words(hunk)
  end
  review.hunks = hunks
  reviews[buf] = review
  reconcile(review)
  bind(review)
  watch(review)
  follow_cursor(review)
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
    if review.agent == agent and sync(review) then
      finish(review, "aborted")
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
  if not review or not sync(review) then
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
  local hunk = hunk_at(review, win) or next_from(review, api.nvim_win_get_cursor(win)[1] - 1)
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

M._layout = layout

return M
