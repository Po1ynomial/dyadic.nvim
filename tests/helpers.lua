local H = {}
H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
H.expect = MiniTest.expect

-- Write a scenario table for tests/fakepi.lua. Values must be plain Lua data.
function H.scenario(tbl)
  local path = vim.fn.tempname() .. "-dyadic-scenario.lua"
  vim.fn.writefile(vim.split("return " .. vim.inspect(tbl or {}), "\n"), path)
  return path
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
    child.wait("_G.S.state.sessionId ~= nil and _G.S.status == 'Idle'")
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

  function child.draft()
    return child.lua_get("_G.S:get_draft()")
  end

  return child
end

return H
