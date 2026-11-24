---@mod denote.files Fast directory scanning, file lookup, and keyword discovery

local config = require("denote.config")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

local uv = vim.uv or vim.loop

--- Check whether a directory basename should be excluded.
---@param name string
---@param extra_exclude_pattern? string
---@return boolean
local function is_excluded_dir(name, extra_exclude_pattern)
  for _, pat in ipairs(config.opts.excluded_directories_patterns or {}) do
    if name:match(pat) then
      return true
    end
  end
  if extra_exclude_pattern and extra_exclude_pattern ~= "" then
    if utils.matches_pattern(name, extra_exclude_pattern) then
      return true
    end
  end
  return false
end

--- Check whether a file basename should be excluded.
---@param name string
---@return boolean
local function is_excluded_file(name)
  for _, pat in ipairs(config.opts.excluded_files_patterns or {}) do
    if name:match(pat) then
      return true
    end
  end
  return false
end

--- Recursively list all files in `dir` (default: active Denote directory).
---@param opts? { dir?: string, denote_only?: boolean, text_only?: boolean, regexp?: string, not_regexp?: string, excluded_dirs_regexp?: string }
---@return string[]
function M.list(opts)
  opts = opts or {}
  local root = config.directory(opts.dir)
  if not utils.is_dir(root) then
    return {}
  end

  local results = {}
  local text_exts = { [".org"] = true, [".md"] = true, [".markdown"] = true, [".txt"] = true }
  for _, spec in pairs(config.opts.file_types or {}) do
    if spec.extension then
      text_exts[spec.extension:lower()] = true
    end
  end

  local function walk(current)
    local handle = uv.fs_scandir(current)
    if not handle then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local full = current .. "/" .. name
      if typ == "link" then
        local st = uv.fs_stat(full)
        typ = st and st.type or typ
      end
      if typ == "directory" then
        if not is_excluded_dir(name, opts.excluded_dirs_regexp) then
          walk(full)
        end
      elseif typ == "file" then
        if not is_excluded_file(name) then
          local include = true
          if opts.denote_only ~= false and not naming.is_denote_file(full) then
            include = false
          end
          if include and opts.text_only then
            local _, ext = naming.split_extension(name)
            local primary = (ext:match("^(%.[^%.]+)") or ext):lower()
            if not text_exts[primary] then
              include = false
            end
          end
          if include and opts.regexp and opts.regexp ~= "" then
            local rel = utils.relpath(full, root)
            if not utils.matches_pattern(rel, opts.regexp) then
              include = false
            end
          end
          if include and opts.not_regexp and opts.not_regexp ~= "" then
            local rel = utils.relpath(full, root)
            if utils.matches_pattern(rel, opts.not_regexp) then
              include = false
            end
          end
          if include then
            results[#results + 1] = full
          end
        end
      end
    end
  end

  walk(root)
  table.sort(results)
  return results
end

--- List all subdirectories inside `dir` (including `dir` itself as `"."` if `include_root` is true).
---@param dir? string
---@param include_root? boolean
---@return string[] Absolute paths
function M.subdirectories(dir, include_root)
  local root = config.directory(dir)
  if not utils.is_dir(root) then
    return include_root and { root } or {}
  end

  local dirs = include_root and { root } or {}
  local function walk(current)
    local handle = uv.fs_scandir(current)
    if not handle then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if typ == "directory" and not is_excluded_dir(name) then
        local full = current .. "/" .. name
        dirs[#dirs + 1] = full
        walk(full)
      end
    end
  end
  walk(root)
  table.sort(dirs)
  return dirs
end

--- Return a set `{ [identifier] = true }` of all identifiers currently present in `dir`.
---@param dir? string
---@return table<string, boolean>
function M.identifier_set(dir)
  local ids = {}
  for _, path in ipairs(M.list({ dir = dir, denote_only = true })) do
    local id = naming.retrieve_identifier(path)
    if id then
      ids[id] = true
    end
  end
  return ids
end

--- Find a Denote file by its unique identifier across the active directory (and silos if not found).
---@param id string
---@param dir? string
---@return string|nil
function M.find_by_id(id, dir)
  if not id or id == "" then
    return nil
  end
  local search_dirs = { config.directory(dir) }
  if not dir then
    for _, s in ipairs(config.opts.silos or {}) do
      local norm = utils.normalize(s)
      if not vim.tbl_contains(search_dirs, norm) then
        search_dirs[#search_dirs + 1] = norm
      end
    end
    if config.opts.journal and config.opts.journal.directory then
      local jdir = utils.normalize(config.opts.journal.directory)
      if not vim.tbl_contains(search_dirs, jdir) then
        search_dirs[#search_dirs + 1] = jdir
      end
    end
  end

  for _, d in ipairs(search_dirs) do
    for _, path in ipairs(M.list({ dir = d, denote_only = true })) do
      if naming.retrieve_identifier(path) == id then
        return path
      end
    end
  end
  return nil
end

--- Collect all known + inferred keywords from Denote files in `dir`.
---@param dir? string
---@return string[]
function M.keywords(dir)
  local list = {}
  for _, kw in ipairs(config.opts.known_keywords or {}) do
    local slug = naming.sluggify_keyword(kw)
    if slug ~= "" then
      list[#list + 1] = slug
    end
  end
  if config.opts.infer_keywords ~= false then
    local exclude_pat = config.opts.keywords_to_not_infer_pattern
    for _, path in ipairs(M.list({ dir = dir, denote_only = true })) do
      local parsed = naming.parse_filename(path)
      for _, kw in ipairs(parsed.keywords) do
        if not (exclude_pat and exclude_pat ~= "" and utils.matches_pattern(kw, exclude_pat)) then
          list[#list + 1] = kw
        end
      end
    end
  end
  return utils.unique_strings(list, true)
end

--- Return file mtime (seconds) for sorting.
---@param path string
---@return integer
function M.mtime(path)
  local st = uv.fs_stat(path)
  return st and st.mtime and st.mtime.sec or 0
end

return M
