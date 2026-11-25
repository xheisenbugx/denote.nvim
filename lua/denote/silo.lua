---@mod denote.silo Isolated Denote silos (matching `denote-silo`)
---@brief [[
--- Allows keeping separate, self-contained Denote note repositories (e.g. work vs personal)
--- configured via `config.opts.silos` or discovered via `.denote.lua` / `.denote.json`
--- directory-local config files (Neovim counterpart of Emacs `.dir-locals.el` silos).
---@brief ]]

local config = require("denote.config")
local utils = require("denote.utils")

local M = {}

local warned_untrusted = {}

--- Resolve `local_opts.directory` relative to `base_dir` if relative.
---@param base_dir string
---@param local_opts table
---@return string
local function resolve_silo_dir(base_dir, local_opts)
  local d = local_opts and local_opts.directory
  if type(d) ~= "string" or d == "" then
    return base_dir
  end
  if d:sub(1, 1) == "/" or d:sub(1, 1) == "~" or d:match("^%a:[/\\]") then
    return utils.normalize(d)
  end
  return utils.normalize(base_dir .. "/" .. d)
end

--- Load a `.denote.lua` file only after Neovim's trust check (`vim.secure.read`).
---@param lua_file string
---@return table
local function read_trusted_lua(lua_file)
  local loader = rawget(_G, "loadstring") or load
  local src = vim.secure and vim.secure.read and vim.secure.read(lua_file) or nil
  if type(src) ~= "string" then
    if not warned_untrusted[lua_file] then
      warned_untrusted[lua_file] = true
      utils.warn("Ignored untrusted .denote.lua (open and run :trust to allow): " .. lua_file)
    end
    return {}
  end
  local chunk, lerr = loader(src, "@" .. lua_file)
  if not chunk then
    utils.warn("Syntax error in " .. lua_file .. ": " .. tostring(lerr))
    return {}
  end
  local ok, data = pcall(chunk)
  if not ok then
    utils.warn("Error running " .. lua_file .. ": " .. tostring(data))
    return {}
  end
  return type(data) == "table" and data or {}
end

--- Return all configured silos (normalized) plus the primary directory.
---@return string[]
function M.list()
  local out = {}
  local base = config.base_opts or config.opts
  local primary = utils.normalize(type(base.directory) == "function" and base.directory() or base.directory)
  out[#out + 1] = primary
  for _, dir in ipairs(base.silos or {}) do
    local norm = utils.normalize(dir)
    if norm ~= "" and not vim.tbl_contains(out, norm) then
      out[#out + 1] = norm
    end
  end
  return out
end

--- Walk upward from `path` (default: current buffer path) looking for a `.denote.lua`
--- or `.denote.json` marker file, or checking if `path` is inside one of `config.opts.silos`.
--- Returns the silo root directory and optional local config overrides table.
---@param path? string
---@return string|nil dir
---@return table|nil local_opts
function M.detect(path)
  local target = path
  if not target or target == "" then
    target = vim.api.nvim_buf_get_name(0)
  end
  if not target or target == "" then
    return nil, nil
  end
  local norm = utils.normalize(target)
  local cur = utils.is_dir(norm) and norm or vim.fn.fnamemodify(norm, ":h")

  -- 1. Check upward for .denote.lua or .denote.json
  local dir = cur
  while dir and dir ~= "" do
    local json_file = dir .. "/.denote.json"
    if utils.is_file(json_file) then
      local raw = utils.read_file(json_file)
      local ok, data = pcall(vim.json.decode, raw or "{}")
      local local_opts = (ok and type(data) == "table") and data or {}
      return resolve_silo_dir(dir, local_opts), local_opts
    end
    local lua_file = dir .. "/.denote.lua"
    if utils.is_file(lua_file) then
      local local_opts = read_trusted_lua(lua_file)
      return resolve_silo_dir(dir, local_opts), local_opts
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end

  -- 2. Check configured silos (longest prefix match, canonicalized for symlinks)
  local norm_real = config.canonicalize(norm)
  local best = nil
  local base = config.base_opts or config.opts
  for _, s in ipairs(base.silos or {}) do
    local sn = config.canonicalize(utils.normalize(s))
    if norm_real == sn or norm_real:sub(1, #sn + 1) == sn .. "/" then
      if not best or #sn > #best then
        best = sn
      end
    end
  end
  if best then
    return best, nil
  end

  return nil, nil
end

--- Run a function `fn` with `config.active_directory` temporarily bound to `silo_dir`
--- (and any `.denote.json`/`.denote.lua` local overrides applied).
---@param silo_dir string
---@param fn fun(): any
---@return any
function M.with_silo(silo_dir, fn)
  local prev_dir = config.active_directory
  local prev_opts = config.opts
  local norm = utils.normalize(silo_dir)
  local resolved_dir, local_opts = M.detect(norm)

  config.active_directory = resolved_dir or norm
  if local_opts then
    config.opts = vim.tbl_deep_extend("force", vim.deepcopy(prev_opts), local_opts)
  end

  local ok, res = pcall(fn)
  config.active_directory = prev_dir
  config.opts = prev_opts

  if not ok then
    error(res, 0)
  end
  return res
end

--- Switch the active Denote directory for this session (applying any `.denote.json` / trusted
--- `.denote.lua` overrides on top of the base configuration).
---@param silo_dir? string Pass nil to reset to default `config.opts.directory`
function M.switch(silo_dir)
  local base = config.base_opts or config.defaults
  local files = require("denote.files")
  local backlinks = require("denote.backlinks")
  if not silo_dir or silo_dir == "" then
    config.active_directory = nil
    config.opts = vim.deepcopy(base)
    files.invalidate()
    backlinks.clear_cache()
    utils.notify("Switched to default directory: " .. config.directory())
    return
  end
  local norm = utils.normalize(silo_dir)
  local resolved_dir, local_opts = M.detect(norm)
  config.active_directory = resolved_dir or norm
  if local_opts then
    config.opts = vim.tbl_deep_extend("force", vim.deepcopy(base), local_opts)
  else
    config.opts = vim.deepcopy(base)
  end
  files.invalidate()
  backlinks.clear_cache()
  utils.notify("Switched active silo to: " .. config.directory())
end

--- Pick a silo interactively and invoke `callback(silo_dir)`.
---@param callback fun(silo_dir: string)
---@param title? string
function M.pick(callback, title)
  local silos = M.list()
  local pickers = require("denote.pickers")
  local items = {}
  local active = config.directory()
  for _, dir in ipairs(silos) do
    local is_active = config.canonicalize(dir) == active
    local marker = is_active and "● " or "  "
    items[#items + 1] = {
      display = {
        { marker, is_active and "DenoteIdentifier" or "Comment" },
        { vim.fn.fnamemodify(dir, ":~"), "DenoteTitle" },
      },
      text = dir,
      value = dir,
    }
  end
  pickers.pick({
    title = title or "Select Denote Silo",
    items = items,
    preview = false,
    on_choice = function(chosen)
      if chosen[1] then
        callback(chosen[1].value)
      end
    end,
  })
end

--- Create a note in a chosen silo (`denote-silo-create-note`).
---@param silo_dir? string
function M.create_note(silo_dir)
  local function run(dir)
    require("denote.create").note({ dir = dir, _silo_dir = dir })
  end
  if silo_dir then
    run(silo_dir)
  else
    M.pick(run, "Create Note in Silo")
  end
end

--- Open or create a note in a chosen silo (`denote-silo-open-or-create`).
---@param silo_dir? string
function M.open_or_create(silo_dir)
  local function run(dir)
    require("denote.create").open_or_create({ dir = dir, _silo_dir = dir })
  end
  if silo_dir then
    run(silo_dir)
  else
    M.pick(run, "Open or Create Note in Silo")
  end
end

--- Open the Denote Explorer in a chosen silo (`denote-silo-dired`).
---@param silo_dir? string
function M.explorer(silo_dir)
  local function run(dir)
    require("denote.explorer").open({ dir = dir })
  end
  if silo_dir then
    run(silo_dir)
  else
    M.pick(run, "Explore Silo")
  end
end

return M
