local H = {}
H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
H.expect = MiniTest.expect

-- Write a scenario table for tests/fakepi.lua. Values must be plain Lua data.
function H.scenario(tbl)
  local path = vim.fn.tempname() .. "-dyadic-scenario.lua"
  vim.fn.writefile(vim.split("return " .. vim.inspect(tbl or {}), "\n"), path)
  return path
end

-- Turn messages (or raw entries with a `type`) into a linked pi entry list e1, e2, ...
function H.chain(items)
  local entries = {}
  for index, item in ipairs(items) do
    local entry = item.type and vim.deepcopy(item) or { type = "message", message = vim.deepcopy(item) }
    entry.id = entry.id or ("e" .. index)
    entry.parentId = entries[index - 1] and entries[index - 1].id or nil
    entries[index] = entry
  end
  return entries
end

function H.new_child()
  local child = MiniTest.new_child_neovim()

  function child.setup()
    child.restart({ "-u", H.root .. "/tests/minimal_init.lua" })
    child.o.lines, child.o.columns = 24, 80
    child.lua([[
      _G.notes = {}
      vim.notify = function(msg, level)
        table.insert(_G.notes, { msg = msg, level = level })
      end
    ]])
  end

  -- Configure dyadic to use the fake pi and open one conversation as _G.S.
  function child.open(scenario, config)
    local path = H.scenario(scenario)
    child.lua(
      [[
      local root, path, config = ...
      config = config or {}
      config.cmd = { vim.v.progpath, "--clean", "-l", root .. "/tests/fakepi.lua", path }
      require("dyadic").setup(config)
      _G.S = require("dyadic").open()
    ]],
      { H.root, path, config }
    )
    child.wait("_G.S.state.sessionId ~= nil and _G.S.phase == 'Idle'")
    -- Screenshots must not contain this machine's paths.
    child.lua("_G.S.cwd = '/work'; require('dyadic.view').render(_G.S)")
  end

  -- Wait inside the child, where libuv callbacks for the fake pi run.
  function child.wait(condition, timeout)
    local ok = child.lua("return vim.wait(...,  function() return " .. condition .. " end, 10)", { timeout or 3000 })
    if not ok then
      error("Timed out waiting for: " .. condition, 2)
    end
  end

  -- Let pending scheduled work, including the render timer, run.
  function child.settle(ms)
    child.lua("vim.wait(..., function() return false end, 10)", { ms or 80 })
  end

  function child.transcript()
    return child.lua_get("vim.api.nvim_buf_get_lines(_G.S.buf, 0, -1, false)")
  end

  function child.emit(events)
    child.lua("_G.S:request('test_emit', { events = ... })", { events })
  end

  -- Overlay rows as { line = 1-based, text = concatenated chunks }.
  function child.rows()
    return child.lua_get([[(function()
      local out = {}
      for _, row in ipairs(_G.S._view.model.rows) do
        local parts = {}
        for _, chunk in ipairs(row.chunks) do
          parts[#parts + 1] = chunk[1]
        end
        out[#out + 1] = { line = row.line + 1, text = table.concat(parts) }
      end
      return out
    end)()]])
  end

  function child.row_texts()
    return vim.tbl_map(function(row)
      return row.text
    end, child.rows())
  end

  -- Put the cursor of the transcript window on the first row whose text matches.
  function child.cursor_to_row(pattern)
    for _, row in ipairs(child.rows()) do
      if row.text:find(pattern) then
        child.lua(
          "local w = vim.fn.win_findbuf(_G.S.buf)[1]; vim.api.nvim_set_current_win(w); vim.api.nvim_win_set_cursor(w, { ..., 0 })",
          { row.line }
        )
        return row.line
      end
    end
    error("No row matches " .. pattern, 2)
  end

  function child.draft()
    return child.lua_get("_G.S:get_draft()")
  end

  return child
end

return H
