if vim.g.loaded_denote_nvim then
  return
end
vim.g.loaded_denote_nvim = 1

require("denote.commands").register()
