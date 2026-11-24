---@mod denote.silo Isolated Denote silos (matching `denote-silo`)
---@brief [[
--- Allows keeping separate, self-contained Denote note repositories (e.g. work vs personal)
--- configured via `config.opts.silos` or discovered via `.denote.lua` / `.denote.json`
--- directory-local config files (Neovim counterpart of Emacs `.dir-locals.el` silos).
---@brief ]]

local config = require("denote.config")
local utils = require("denote.utils")

local M = {}

--- Return all configured silos (normalized) plus the primary directory.
---@return string[]
function M.list()
  local out = {}
  local primary =
    utils.normalize(type(config.opts.directory) == "function" and config.opts.directory() or config.opts.directory)
  out[#out + 1] = primary
  for _, dir in ipairs(config.opts.silos or {}) do
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
      local silo_dir = local_opts.directory and utils.normalize(local_opts.directory) or dir
      return silo_dir, local_opts
    end
    local lua_file = dir .. "/.denote.lua"
    if utils.is_file(lua_file) then
      local ok, data = pcall(dofile, lua_file)
      local local_opts = (ok and type(data) == "table") and data or {}
      local silo_dir = local_opts.directory and utils.normalize(local_opts.directory) or dir
      return silo_dir, local_opts
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end

  -- 2. Check configured silos (longest prefix match)
  local best = nil
  for _, s in ipairs(config.opts.silos or {}) do
    local sn = utils.normalize(s)
    if norm == sn or norm:sub(1, #sn + 1) == sn .. "/" then
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
---@param fn fun()
---@return any
function M.with_silo(silo_dir, fn)
  local prev_dir = config.active_directory
  local prev_opts = config.opts
  local norm = utils.normalize(silo_dir)
  local _, local_opts = M.detect(norm)

  config.active_directory = norm
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

--- Switch the active Denote directory for this session.
---@param silo_dir? string Pass nil to reset to default `config.opts.directory`
function M.switch(silo_dir)
  if not silo_dir or silo_dir == "" then
    config.active_directory = nil
    utils.notify("Switched to default directory: " .. config.directory())
    return
  end
  local norm = utils.normalize(silo_dir)
  config.active_directory = norm
  utils.notify("Switched active silo to: " .. norm)
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
    local marker = dir == active and "● " or "  "
    items[#items + 1] = {
      display = {
        { marker, dir == active and "DenoteIdentifier" or "Comment" },
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
