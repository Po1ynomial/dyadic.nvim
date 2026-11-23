-- pi's command-line arguments for a new agent: `:Dyadic -c`, `:Dyadic --model x`, and `args`
-- from setup(). They are read as pi's parser reads them (cli/args.js), so dyadic knows which
-- words are flag values and which are messages.
local M = {}
local Sessions = require("dyadic.sessions")

local function notify(text, level)
  vim.notify("Dyadic: " .. text, level or vim.log.levels.ERROR)
end

-- Split like a shell: whitespace separates words; '...' is literal; in "...", \" and \\
-- escape; elsewhere \ escapes the next character. A leading unquoted ~ is the home directory.
function M.split(text)
  local words, word, quote, started, tilde = {}, {}, nil, false, false
  local i = 1
  local function finish()
    if started then
      local value = table.concat(word)
      if tilde and (value == "~" or value:sub(1, 2) == "~/") then
        value = vim.uv.os_homedir() .. value:sub(2)
      end
      words[#words + 1] = value
    end
    word, started, tilde = {}, false, false
  end
  while i <= #text do
    local c = text:sub(i, i)
    if quote == "'" then
      if c == "'" then
        quote = nil
      else
        word[#word + 1] = c
      end
    elseif quote == '"' then
      local nxt = text:sub(i + 1, i + 1)
      if c == '"' then
        quote = nil
      elseif c == "\\" and (nxt == '"' or nxt == "\\") then
        word[#word + 1], i = nxt, i + 1
      else
        word[#word + 1] = c
      end
    elseif c:match("%s") then
      finish()
    elseif c == "'" or c == '"' then
      quote, started = c, true
    elseif c == "\\" then
      word[#word + 1], started, i = text:sub(i + 1, i + 1), true, i + 1
    else
      if not started and c == "~" then
        tilde = true
      end
      word[#word + 1], started = c, true
    end
    i = i + 1
  end
  if quote then
    return nil, "unterminated " .. quote
  end
  finish()
  return words
end

-- Flags whose next word is always their value.
local valued = {}
for _, flag in ipairs({
  "--provider",
  "--model",
  "--api-key",
  "--system-prompt",
  "--append-system-prompt",
  "--name",
  "-n",
  "--session",
  "--session-id",
  "--fork",
  "--session-dir",
  "--models",
  "--tools",
  "-t",
  "--exclude-tools",
  "-xt",
  "--thinking",
  "--export",
  "--extension",
  "-e",
  "--skill",
  "--prompt-template",
  "--theme",
}) do
  valued[flag] = true
end

-- pi's flags without a value; unknown flags may take one.
local boolean = {}
for _, flag in ipairs({
  "--help",
  "-h",
  "--version",
  "-v",
  "--continue",
  "-c",
  "--resume",
  "-r",
  "--no-session",
  "--no-tools",
  "-nt",
  "--no-builtin-tools",
  "-nbt",
  "--no-extensions",
  "-ne",
  "--no-mcp",
  "--no-skills",
  "-ns",
  "--no-prompt-templates",
  "-np",
  "--no-themes",
  "--no-context-files",
  "-nc",
  "--verbose",
  "--approve",
  "-a",
  "--no-approve",
  "-na",
  "--offline",
}) do
  boolean[flag] = true
end

local function dash(word)
  return word ~= nil and word:sub(1, 1) == "-"
end

-- The flags, with the index of each and of its value, the @file words, the messages, and
-- the indexes of the words that are messages, `--` included.
function M.parse(words)
  local flags, files, messages, positional = {}, {}, {}, {}
  local i = 1
  while i <= #words do
    local word = words[i]
    local nxt = words[i + 1]
    local flag = { name = word, index = i }
    if word == "--" then
      for j = i, #words do
        positional[j] = true
        if j > i then
          local target = words[j]:sub(1, 1) == "@" and files or messages
          target[#target + 1] = words[j]
        end
      end
      break
    elseif valued[word] then
      if nxt ~= nil then
        flag.value, flag.value_index, i = nxt, i + 1, i + 1
      end
      flags[#flags + 1] = flag
    elseif word == "--mode" or word == "--use-theme" or word == "--tui-mode" then
      if nxt ~= nil and not dash(nxt) then
        flag.value, flag.value_index, i = nxt, i + 1, i + 1
      end
      flags[#flags + 1] = flag
    elseif word == "--print" or word == "-p" then
      if nxt ~= nil and nxt:sub(1, 1) ~= "@" and (not dash(nxt) or nxt:sub(1, 3) == "---") then
        messages[#messages + 1], positional[i + 1], i = nxt, true, i + 1
      end
      flags[#flags + 1] = flag
    elseif word == "--list-models" then
      if nxt ~= nil and not dash(nxt) and nxt:sub(1, 1) ~= "@" then
        flag.value, flag.value_index, i = nxt, i + 1, i + 1
      end
      flags[#flags + 1] = flag
    elseif word:sub(1, 1) == "@" then
      files[#files + 1] = word
    elseif boolean[word] then
      flags[#flags + 1] = flag
    elseif word:sub(1, 2) == "--" then
      -- Extension flags: `--name=value`, or a value that is not a flag or an @file.
      if not word:find("=", 1, true) and nxt ~= nil and not dash(nxt) and nxt:sub(1, 1) ~= "@" then
        flag.value, flag.value_index, i = nxt, i + 1, i + 1
      end
      flags[#flags + 1] = flag
    elseif dash(word) then
      flags[#flags + 1] = flag
    else
      messages[#messages + 1], positional[i] = word, true
    end
    i = i + 1
  end
  local by_name = {}
  for _, flag in ipairs(flags) do
    by_name[flag.name] = flag
  end
  return {
    flags = flags,
    files = files,
    messages = messages,
    positional = positional,
    has = function(...)
      for _, name in ipairs({ ... }) do
        if by_name[name] then
          return by_name[name]
        end
      end
    end,
  }
end

-- Arguments that start no agent, or that break pi's RPC mode.
local refused = {
  { "--help", "-h" },
  { "--version", "-v" },
  { "--mode" },
  { "--print", "-p" },
  { "--export" },
  { "--list-models" },
}

local function refusal(parsed)
  for _, names in ipairs(refused) do
    local flag = parsed.has(unpack(names))
    if flag then
      return flag.name .. " does not start an agent. Run `pi " .. flag.name .. "` in a terminal"
    end
  end
  if #parsed.files > 0 then
    return parsed.files[1] .. ": @file arguments are not supported. Mention the file in the composer"
  end
  -- Like pi, which exits on these combinations.
  local fork = parsed.has("--fork")
  local session_id = parsed.has("--session-id")
  local function conflicts(names)
    local found = {}
    for _, name in ipairs(names) do
      local flag = parsed.has(unpack(name))
      if flag then
        found[#found + 1] = name[1]
      end
    end
    return found
  end
  if fork then
    local found = conflicts({ { "--session" }, { "--continue", "-c" }, { "--resume", "-r" }, { "--no-session" } })
    if #found > 0 then
      return "--fork cannot be combined with " .. table.concat(found, ", ")
    end
  end
  if session_id then
    local found = conflicts({ { "--session" }, { "--continue", "-c" }, { "--resume", "-r" } })
    if #found > 0 then
      return "--session-id cannot be combined with " .. table.concat(found, ", ")
    end
  end
end

-- An error message when `args` from setup() cannot go before every agent's arguments.
function M.check(args)
  local parsed = M.parse(args)
  local reason = refusal(parsed)
  if reason then
    return reason
  end
  if #parsed.messages > 0 or vim.tbl_contains(args, "--") then
    return "messages are not supported in args"
  end
end

local function without(words, drop)
  local kept = {}
  for index, word in ipairs(words) do
    if not drop[index] then
      kept[#kept + 1] = word
    end
  end
  return kept
end

-- Turn `config_args` and the user's `words` into the arguments pi gets, resolving what pi
-- would ask about on the terminal: -r opens a picker, and a session ID from another
-- directory asks whether to fork it. Calls done(args, draft), at once when nothing needs
-- asking; without `opts.interactive`, an argument that needs asking is an error.
-- `opts.config` is dyadic's configuration, for the session picker's keys.
function M.prepare(cwd, config_args, words, done, opts)
  opts = opts or {}
  local combined = vim.list_extend(vim.deepcopy(config_args), words)
  local parsed = M.parse(combined)
  local reason = refusal(parsed)
  if reason then
    notify(reason)
    return
  end
  -- Messages, which pi ignores in RPC mode, become the draft.
  local draft = table.concat(parsed.messages, " ")
  local drop = vim.deepcopy(parsed.positional)
  -- pi reads -r only without --no-session, --fork, or --session.
  local resume = parsed.has("--resume", "-r")
  for _, flag in ipairs(parsed.flags) do
    if flag.name == "--resume" or flag.name == "-r" then
      drop[flag.index] = true
    end
  end
  local session = parsed.has("--session")
  local skip_resume = parsed.has("--no-session", "--fork") or session
  local where = { cwd = cwd, args = combined }
  local function interactive()
    if not opts.interactive then
      notify("-r and session IDs from other directories need :Dyadic")
      return false
    end
    return true
  end
  if not parsed.has("--no-session") and not parsed.has("--fork") and session and session.value then
    local value = session.value
    local is_path = value:find("/", 1, true) or value:find("\\", 1, true) or value:match("%.jsonl$")
    if not is_path then
      local found = Sessions.find(value, where)
      if not found then
        notify("No session found matching '" .. value .. "'")
        return
      end
      if not found.here then
        if not interactive() then
          return
        end
        local prompt = "Session found in " .. vim.fn.fnamemodify(found.cwd, ":~") .. ". Fork it into this directory?"
        vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
          if choice == "Yes" then
            local args = without(combined, drop)
            for index, word in ipairs(args) do
              if word == "--session" and args[index + 1] == value then
                args[index], args[index + 1] = "--fork", found.path
                break
              end
            end
            done(args, draft)
          end
        end)
        return
      end
    end
  end
  if resume and not skip_resume then
    if not interactive() then
      return
    end
    require("dyadic.session_picker").open({
      where = where,
      config = opts.config,
      on_choose = function(path)
        local args = without(combined, drop)
        vim.list_extend(args, { "--session", path })
        done(args, draft)
      end,
    })
    return
  end
  done(without(combined, drop), draft)
end

local flag_names = {
  "--provider",
  "--model",
  "--api-key",
  "--system-prompt",
  "--append-system-prompt",
  "--continue",
  "--resume",
  "--session",
  "--session-id",
  "--fork",
  "--session-dir",
  "--no-session",
  "--name",
  "--models",
  "--no-tools",
  "--no-builtin-tools",
  "--tools",
  "--exclude-tools",
  "--thinking",
  "--extension",
  "--no-extensions",
  "--no-mcp",
  "--skill",
  "--no-skills",
  "--prompt-template",
  "--no-prompt-templates",
  "--theme",
  "--no-themes",
  "--no-context-files",
  "--verbose",
  "--approve",
  "--no-approve",
  "--offline",
}
local path_flags = {
  ["--session"] = true,
  ["--fork"] = true,
  ["--session-dir"] = true,
  ["--extension"] = true,
  ["-e"] = true,
  ["--skill"] = true,
  ["--prompt-template"] = true,
  ["--theme"] = true,
  ["--append-system-prompt"] = true,
}

-- Complete `lead`, the word being typed after the words in `before`.
function M.complete(lead, before)
  local previous = before[#before]
  if previous == "--thinking" then
    return vim.tbl_filter(function(level)
      return level:sub(1, #lead) == lead
    end, { "off", "minimal", "low", "medium", "high", "xhigh", "max" })
  end
  if path_flags[previous] then
    return vim.fn.getcompletion(lead, "file")
  end
  return vim.tbl_filter(function(flag)
    return flag:sub(1, #lead) == lead
  end, lead:sub(1, 1) == "-" and flag_names or {})
end

return M
