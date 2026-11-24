-- Standalone Neovim config used to record the README GIFs in docs/media.
--
--   export DENOTE_DEMO_DIR=/tmp/denote-demo
--   nvim -u docs/media/demo/init.lua
--
-- Environment flags:
--   DEMO_SNACKS=1   Enable snacks.nvim picker and notifier
--   DEMO_ORG=1      Load org.nvim alongside denote.nvim (from $ORG_NVIM_PATH or ../orgmode)
--   DEMO_FT=org     Override default file_type (default: "markdown-yaml")
--   DEMO_SCHEME=... Override sequence scheme ("numeric" or "alphanumeric")

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h:h")
local dir = vim.env.DENOTE_DEMO_DIR or "/tmp/denote-nvim-demo"

-- Fresh copy of demo notes for every recording
vim.fn.delete(dir, "rf")
vim.fn.mkdir(dir, "p")
for _, src in ipairs(vim.fn.glob(here .. "/notes/*", false, true)) do
  if vim.fn.isdirectory(src) == 0 then
    vim.uv.fs_copyfile(src, dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
  end
end

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.opt.rtp:prepend(root)
vim.opt.termguicolors = true
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.laststatus = 3
vim.opt.showmode = false
vim.opt.showcmd = false
vim.opt.ruler = false
vim.opt.cmdheight = 1
vim.opt.shortmess:append("IF")
vim.opt.signcolumn = "no"
vim.opt.number = false
vim.opt.relativenumber = false
vim.opt.wrap = true
vim.opt.linebreak = true
vim.opt.fillchars = { eob = " " }

if vim.env.DEMO_SNACKS == "1" then
  local snacks = vim.env.SNACKS_PATH or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
  if vim.fn.isdirectory(snacks) == 1 then
    vim.opt.rtp:prepend(snacks)
    require("snacks").setup({
      picker = { ui_select = true },
      notifier = { enabled = true, style = "compact", top_down = true, timeout = 5000 },
    })
  end
end

if vim.env.DEMO_ORG == "1" then
  local org_path = vim.env.ORG_NVIM_PATH or (vim.fn.fnamemodify(root, ":h") .. "/orgmode")
  if vim.fn.isdirectory(org_path) == 1 then
    vim.opt.rtp:prepend(org_path)
    require("org").setup({
      org_directory = dir,
      agenda_files = { dir .. "/*.org" },
      ui = {
        bullets = { "◉", "○", "✸", "✿" },
        checkboxes = { " ", "◐", "✓" },
      },
    })
  end
end

require("denote").setup({
  directory = dir,
  file_type = vim.env.DEMO_FT or "markdown-yaml",
  known_keywords = { "emacs", "neovim", "org", "philosophy", "zettelkasten", "journal" },
  save_buffer_after_creation = true,
  sequence = {
    scheme = vim.env.DEMO_SCHEME or "alphanumeric",
  },
  journal = {
    directory = dir,
    keyword = "journal",
    title_format = "%A %e %B %Y",
  },
  templates = {
    review = "## Summary\n\n- \n\n## Key Takeaways\n\n- \n",
  },
  ui = {
    highlight_links = true,
    check_broken_links = true,
  },
})

-- Crisp statusline showing both the Denote human title and the actual filename on disk
vim.opt.statusline = " %t%m %= %{v:lua.require'denote'.statusline()} "

-- Key captions in the bottom-right corner (`:Cap {keys} {what}`), matching org.nvim demos
vim.api.nvim_set_hl(0, "DemoCaption", { fg = "#e0e2ea", bg = "#2c2e33" })
vim.api.nvim_set_hl(0, "DemoCaptionKey", { fg = "#fce094", bg = "#2c2e33", bold = true })
vim.api.nvim_set_hl(0, "DemoCaptionBorder", { fg = "#6b6f79", bg = "#2c2e33" })

local caption = {}
local function show_caption(args)
  if caption.win and vim.api.nvim_win_is_valid(caption.win) then
    vim.api.nvim_win_close(caption.win, true)
  end
  local keys, what = args:match("^(.-)%s+|%s+(.*)$")
  if not keys then
    keys, what = args:match("^(%S+)%s*(.*)$")
  end
  if not keys then
    return
  end
  local text = " " .. keys .. (what ~= "" and ("  " .. what) or "") .. " "
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace("demo_cap"), 0, 1, {
    end_col = 1 + #keys,
    hl_group = "DemoCaptionKey",
  })
  local width = vim.fn.strdisplaywidth(text)
  caption.win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = vim.o.lines - 5,
    col = vim.o.columns - width - 3,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 250,
  })
  vim.wo[caption.win].winhighlight = "Normal:DemoCaption,FloatBorder:DemoCaptionBorder"
end

vim.keymap.set({ "n", "x" }, "<C-g>", ":<C-u>")
vim.keymap.set("i", "<C-g>", "<C-o>:")
vim.api.nvim_create_user_command("Cap", function(o)
  show_caption(o.args)
  vim.api.nvim_echo({ { "" } }, false, {})
end, { nargs = "*" })
