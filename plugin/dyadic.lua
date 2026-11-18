if vim.g.loaded_dyadic then
  return
end
vim.g.loaded_dyadic = true

vim.api.nvim_create_user_command("Dyadic", function(opts)
  require("dyadic").command(opts.args)
end, {
  nargs = "*",
  complete = function(lead)
    return require("dyadic").complete(lead)
  end,
  desc = "Open and control native pi conversations",
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("DyadicShutdown", { clear = true }),
  callback = function()
    require("dyadic").shutdown()
  end,
})
