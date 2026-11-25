---@mod denote.health :checkhealth denote diagnostics

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local pickers = require("denote.pickers")
local utils = require("denote.utils")

local M = {}

local VALID_PICKERS = { auto = true, snacks = true, ["fzf-lua"] = true, telescope = true, mini = true, select = true }
local VALID_LINK_STYLES = { denote = true, wiki = true, relative = true }
local VALID_INTERVALS = { daily = true, weekly = true, monthly = true, yearly = true }
local VALID_SCHEMES = { numeric = true, alphanumeric = true }

local FREEFORM_TABLES = {
  templates = true,
  file_types = true,
  file_name_slug_functions = true,
  known_keywords = true,
  prompts = true,
  file_name_components_order = true,
  excluded_directories_patterns = true,
  excluded_files_patterns = true,
  front_matter_components_present_even_if_empty = true,
  rename_confirmations = true,
  silos = true,
  ["capture.templates"] = true,
  ["journal.title_format"] = true,
}

---@param opts table
---@param defaults table
---@param prefix string
---@param unknown string[]
local function collect_unknown_keys(opts, defaults, prefix, unknown)
  for k, v in pairs(opts) do
    local full = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
    local def = defaults[k]
    if def == nil then
      unknown[#unknown + 1] = full
    elseif type(v) == "table" and type(def) == "table" and not FREEFORM_TABLES[full] and not vim.islist(def) then
      collect_unknown_keys(v, def, full, unknown)
    end
  end
end

function M.check()
  local health = vim.health
  health.start("denote.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim version >= 0.10")
  else
    health.error("Neovim >= 0.10 is required")
  end

  -- Configuration validation
  local unknown = {}
  collect_unknown_keys(config.opts, config.defaults, "", unknown)
  table.sort(unknown)
  if #unknown > 0 then
    health.warn("Unknown config option(s): " .. table.concat(unknown, ", "))
  end

  -- Denote directory
  local dir = config.directory()
  if utils.is_dir(dir) then
    local notes = files.list({ dir = dir, denote_only = true })
    health.ok(string.format("directory: %s (%d Denote file(s))", dir, #notes))
  else
    health.warn("directory does not exist yet (will be created on first note): " .. dir)
  end

  -- File type & enums
  local ft = config.opts.file_type
  local all_fts = frontmatter.file_types()
  if all_fts[ft] or ft == "markdown" or ft == "md" then
    health.info("default file_type: " .. tostring(ft))
  else
    health.warn("unknown file_type: " .. tostring(ft) .. " (falling back to markdown-yaml)")
  end

  local link_style = config.opts.markdown_link_style
  if VALID_LINK_STYLES[link_style] then
    health.info("markdown_link_style: " .. tostring(link_style))
  else
    health.warn("unknown markdown_link_style: " .. tostring(link_style))
  end

  local picker_pref = config.opts.picker or "auto"
  if not VALID_PICKERS[picker_pref] then
    health.warn("unknown picker option: " .. tostring(picker_pref))
  end
  local backend = pickers.resolve_backend()
  health.ok("picker backend: " .. backend)

  local jcfg = config.opts.journal or {}
  if jcfg.interval and not VALID_INTERVALS[jcfg.interval] then
    health.warn("unknown journal.interval: " .. tostring(jcfg.interval))
  end
  if jcfg.directory and jcfg.directory ~= "" then
    local jdir = config.directory(jcfg.directory)
    if utils.is_dir(jdir) then
      health.ok("journal directory: " .. jdir)
    else
      health.warn("journal directory does not exist yet: " .. jdir)
    end
  end

  local scfg = config.opts.sequence or {}
  if scfg.scheme and not VALID_SCHEMES[scfg.scheme] then
    health.warn("unknown sequence.scheme: " .. tostring(scfg.scheme))
  end

  -- Capture templates duplicate key check
  local ckeys, cdups = {}, {}
  for _, entry in ipairs((config.opts.capture and config.opts.capture.templates) or {}) do
    if entry.key then
      if ckeys[entry.key] then
        cdups[#cdups + 1] = entry.key
      end
      ckeys[entry.key] = true
    end
  end
  if #cdups > 0 then
    health.warn("duplicate capture template key(s): " .. table.concat(cdups, ", "))
  end

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

  -- org.nvim & completion integrations
  local org_int = require("denote.integrations.org")
  if org_int.is_attached() then
    health.ok("org.nvim integration active (denote: links + dynamic blocks registered)")
  elseif pcall(require, "org.config") then
    health.info("org.nvim detected (will attach on setup or Org buffer open)")
  else
    health.info("org.nvim not installed (standalone Org syntax & dynamic blocks still supported)")
  end

  if pcall(require, "blink.cmp") then
    health.info("blink.cmp detected (available via module 'denote.integrations.blink')")
  end
  if pcall(require, "cmp") then
    health.info("nvim-cmp detected (available via require('denote.integrations.cmp').new())")
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
