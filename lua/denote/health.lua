---@mod denote.health :checkhealth denote diagnostics

local config = require("denote.config")
local files = require("denote.files")
local pickers = require("denote.pickers")
local utils = require("denote.utils")

local M = {}

function M.check()
  local health = vim.health
  health.start("denote.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim version >= 0.10")
  else
    health.error("Neovim >= 0.10 is required")
  end

  -- Denote directory
  local dir = config.directory()
  if utils.is_dir(dir) then
    local notes = files.list({ dir = dir, denote_only = true })
    health.ok(string.format("directory: %s (%d Denote file(s))", dir, #notes))
  else
    health.warn("directory does not exist yet (will be created on first note): " .. dir)
  end

  -- File type
  health.info("default file_type: " .. tostring(config.opts.file_type))
  health.info("markdown_link_style: " .. tostring(config.opts.markdown_link_style))

  -- Picker backend
  local backend = pickers.resolve_backend()
  health.ok("picker backend: " .. backend)

  -- Optional ripgrep
  local search_opts = config.opts.search or {}
  if vim.fn.executable("rg") == 1 then
    if search_opts.ripgrep == false then
      health.info("ripgrep (rg) found but disabled (search.ripgrep = false): using pure Lua search")
    else
      health.ok("ripgrep (rg) found: grep, backlinks, and reports use it")
    end
  else
    health.info("ripgrep (rg) not found: using built-in pure Lua search")
  end

  -- Diagnostics
  if config.opts.ui and config.opts.ui.diagnostics ~= false and config.opts.ui.check_broken_links ~= false then
    health.ok("broken links reported via vim.diagnostic")
  else
    health.info("broken-link diagnostics disabled (ui.diagnostics / ui.check_broken_links)")
  end

  -- org.nvim integration
  local org_int = require("denote.integrations.org")
  if org_int.is_attached() then
    health.ok("org.nvim integration active (denote: links + dynamic blocks registered)")
  elseif pcall(require, "org.config") then
    health.info("org.nvim detected (will attach on setup or Org buffer open)")
  else
    health.info("org.nvim not installed (standalone Org syntax & dynamic blocks still supported)")
  end

  -- Silos
  local silos = config.opts.silos or {}
  if #silos > 0 then
    for _, s in ipairs(silos) do
      local norm = utils.normalize(s)
      if utils.is_dir(norm) then
        health.ok("silo: " .. norm)
      else
        health.warn("silo directory missing: " .. norm)
      end
    end
  end
end

return M
