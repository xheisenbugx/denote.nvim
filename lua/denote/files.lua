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

--- In-memory index of directory trees, keyed by root.
---
--- Each entry holds every (non-excluded) file below the root plus the mtime of every
--- directory that was scanned. Adding, removing, or renaming an entry changes the mtime of
--- its parent directory, so validating an entry only needs one `stat` per directory instead
--- of a full recursive `scandir`. Operations performed by denote.nvim itself also call
--- `M.invalidate()` explicitly (covers filesystems with coarse mtime resolution).
---@class denote.IndexEntry
---@field files string[] Sorted absolute paths
---@field dirs table<string, string> Directory path -> mtime key
---@field ids? table<string, string> Identifier -> first path (built lazily)
---@field denote? table<string, boolean> Path -> is a Denote file (built lazily)
---@field text? table<string, boolean> Path -> has a text note extension (built lazily)
---@field validated_at? integer Loop time (`uv.now()`) of the last freshness check

---@type table<string, denote.IndexEntry>
local index = {}

--- Monotonic counter bumped on every invalidation (lets other caches detect staleness).
M.generation = 0

---@param st? table
---@return string
local function mtime_key(st)
  if not st or not st.mtime then
    return ""
  end
  return st.mtime.sec .. "." .. (st.mtime.nsec or 0)
end

--- Signal that note *contents* changed (e.g. a buffer was saved) without forcing a rescan of
--- directory listings. Content-derived caches (backlink indicators) refresh on next use.
function M.touch()
  M.generation = M.generation + 1
  for _, entry in pairs(index) do
    entry.validated_at = nil
  end
end

--- Drop cached directory listings (all roots, or only `dir`).
---@param dir? string
function M.invalidate(dir)
  M.generation = M.generation + 1
  if dir then
    index[utils.normalize(dir)] = nil
  else
    index = {}
  end
end

---@param root string
---@return denote.IndexEntry
local function scan(root)
  local entry = { files = {}, dirs = {} }
  local function walk(current)
    local handle = uv.fs_scandir(current)
    entry.dirs[current] = mtime_key(uv.fs_stat(current))
    if not handle then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local full = current .. "/" .. name
      if typ == "link" or typ == nil or typ == "unknown" then
        local st = uv.fs_stat(full)
        typ = st and st.type or typ
      end
      if typ == "directory" then
        if not is_excluded_dir(name) then
          walk(full)
        end
      elseif typ == "file" then
        if not is_excluded_file(name) then
          entry.files[#entry.files + 1] = full
        end
      end
    end
  end
  walk(root)
  table.sort(entry.files)
  return entry
end

---@param entry denote.IndexEntry
---@return boolean
local function is_fresh(entry)
  for d, key in pairs(entry.dirs) do
    if mtime_key(uv.fs_stat(d)) ~= key then
      return false
    end
  end
  return true
end

--- Return the (possibly cached) index entry for `root`.
---@param root string
---@return denote.IndexEntry
local function get_index(root)
  local entry = index[root]
  -- `uv.now()` is the cached loop time: it only advances between event-loop iterations, so a
  -- burst of synchronous lookups (e.g. resolving every link in a buffer) validates once.
  local tick = uv.now()
  if entry and (entry.validated_at == tick or is_fresh(entry)) then
    entry.validated_at = tick
    return entry
  end
  entry = scan(root)
  entry.validated_at = tick
  index[root] = entry
  return entry
end

local text_exts_base = { [".org"] = true, [".md"] = true, [".markdown"] = true, [".txt"] = true }

---@return table<string, boolean>
local function text_extensions()
  local exts = vim.deepcopy(text_exts_base)
  for _, spec in pairs(config.opts.file_types or {}) do
    if spec.extension then
      exts[spec.extension:lower()] = true
    end
  end
  return exts
end

--- Return true if `path` has a text note extension (`.org`, `.md`, `.txt`, or a custom file type).
---@param path string
---@param exts? table<string, boolean>
---@return boolean
function M.is_text_file(path, exts)
  exts = exts or text_extensions()
  local _, ext = naming.split_extension(vim.fs.basename(path))
  local primary = (ext:match("^(%.[^%.]+)") or ext):lower()
  return exts[primary] == true
end

--- Return true if any directory component of `rel` matches `pattern`.
---@param rel string
---@param pattern string
---@return boolean
local function rel_dir_excluded(rel, pattern)
  local parts = vim.split(rel, "/", { plain = true })
  for i = 1, #parts - 1 do
    if utils.matches_pattern(parts[i], pattern) then
      return true
    end
  end
  return false
end

--- Recursively list all files in `dir` (default: active Denote directory).
--- Results come from a cached index that is revalidated cheaply on every call.
---@param opts? { dir?: string, denote_only?: boolean, text_only?: boolean, regexp?: string, not_regexp?: string, excluded_dirs_regexp?: string }
---@return string[]
function M.list(opts)
  opts = opts or {}
  local root = config.directory(opts.dir)
  if not utils.is_dir(root) then
    return {}
  end

  local entry = get_index(root)
  if not entry.denote then
    local exts_all = text_extensions()
    local denote, text = {}, {}
    for _, full in ipairs(entry.files) do
      denote[full] = naming.is_denote_file(full)
      text[full] = M.is_text_file(full, exts_all)
    end
    entry.denote, entry.text = denote, text
  end
  local text_only = opts.text_only
  local extra_dirs = opts.excluded_dirs_regexp ~= "" and opts.excluded_dirs_regexp or nil
  local regexp = opts.regexp ~= "" and opts.regexp or nil
  local not_regexp = opts.not_regexp ~= "" and opts.not_regexp or nil
  local need_rel = extra_dirs or regexp or not_regexp

  local results = {}
  for _, full in ipairs(entry.files) do
    local include = true
    if opts.denote_only ~= false and not entry.denote[full] then
      include = false
    end
    if include and text_only and not entry.text[full] then
      include = false
    end
    local rel = (include and need_rel) and utils.relpath(full, root) or nil
    if include and extra_dirs and rel_dir_excluded(rel, extra_dirs) then
      include = false
    end
    if include and regexp and not utils.matches_pattern(rel, regexp) then
      include = false
    end
    if include and not_regexp and utils.matches_pattern(rel, not_regexp) then
      include = false
    end
    if include then
      results[#results + 1] = full
    end
  end
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

--- Return the `identifier -> path` map for `dir` (cached with the directory index).
---@param dir? string
---@return table<string, string>
local function id_map(dir)
  local root = config.directory(dir)
  if not utils.is_dir(root) then
    return {}
  end
  local entry = get_index(root)
  if not entry.ids then
    local ids = {}
    for _, path in ipairs(entry.files) do
      local id = naming.retrieve_identifier(path)
      if id and not ids[id] then
        ids[id] = path
      end
    end
    entry.ids = ids
  end
  return entry.ids
end

--- Return a set `{ [identifier] = true }` of all identifiers currently present in `dir`.
---@param dir? string
---@return table<string, boolean>
function M.identifier_set(dir)
  local ids = {}
  for id in pairs(id_map(dir)) do
    ids[id] = true
  end
  return ids
end

--- Directories searched when resolving a link identifier: the given/active directory,
--- then every configured silo and the journal directory (deduplicated).
---@param dir? string
---@return string[]
function M.search_dirs(dir)
  local dirs = { config.directory(dir) }
  if dir then
    return dirs
  end
  local function add(d)
    local norm = config.directory(d)
    if not vim.tbl_contains(dirs, norm) then
      dirs[#dirs + 1] = norm
    end
  end
  for _, s in ipairs(config.opts.silos or {}) do
    add(s)
  end
  if config.opts.journal and config.opts.journal.directory then
    add(config.opts.journal.directory)
  end
  return dirs
end

--- Return true if `id` resolves to an existing file (same lookup rules as `find_by_id`).
---@param id string
---@param dir? string
---@return boolean
function M.has_id(id, dir)
  return M.find_by_id(id, dir) ~= nil
end

--- Find a Denote file by its unique identifier across the active directory (and silos if not found).
---@param id string
---@param dir? string
---@return string|nil
function M.find_by_id(id, dir)
  if not id or id == "" then
    return nil
  end
  for _, d in ipairs(M.search_dirs(dir)) do
    local path = id_map(d)[id]
    if path then
      return path
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
