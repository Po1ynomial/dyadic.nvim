if vim.g.loaded_dyadic then
  return
end
vim.g.loaded_dyadic = true

vim.api.nvim_create_user_command("Dyadic", function(opts)
  require("dyadic").command(opts.args)
end, {
  nargs = "*",
  complete = function(lead, line, pos)
    -- The words between the command name and the one being completed.
    local typed = line:sub(1, pos):sub(1, -#lead - 1):gsub("^%s*%S+", "", 1)
    return require("dyadic").complete(lead, vim.split(typed, "%s+", { trimempty = true }))
  end,
  desc = "Open and control native pi conversations",
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("DyadicShutdown", { clear = true }),
  callback = function()
    require("dyadic").shutdown()
  end,
})
