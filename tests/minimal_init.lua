-- Test init for the parent runner and every child Neovim.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local mini = vim.env.MINI_TEST_PATH
if not mini or mini == "" then
  mini = root .. "/deps/mini.test"
end
vim.opt.runtimepath:prepend(mini)
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false
vim.o.shadafile = "NONE"
require("mini.test").setup()
