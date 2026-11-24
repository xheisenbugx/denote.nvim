---@mod denote.rename Renaming Denote files and syncing front matter
---
--- Supports two-way synchronization between Denote filenames and front matter:
--- - `rename_file`: rename ANY file (including PDFs, images, non-Denote files) into
---   Denote's naming scheme and optionally update/add front matter.
--- - `rename_file_title`, `rename_file_keywords`, `rename_file_signature`, `rename_file_date`
--- - `rename_file_using_front_matter`: sync filename on disk from edits inside front matter.
--- - `add_front_matter`: prepend Denote front matter to a note lacking it.
--- - `keywords_add` / `keywords_remove`: quick keyword edits.
--- - `format_buffer_name` / `statusline`: Denote rename-buffer display formatting.

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

local uv = vim.uv or vim.loop

--- Check whether a confirmation key is enabled in `config.opts.rename_confirmations`.
---@param key string
---@return boolean
local function needs_confirm(key)
  return vim.tbl_contains(config.opts.rename_confirmations or {}, key)
end

--- Ask yes/no confirmation when needed.
---@param key string
---@param prompt string
---@return boolean
local function confirm_action(key, prompt)
  if not needs_confirm(key) then
    return true
  end
  local choice = vim.fn.confirm(prompt, "&Yes\n&No", 1)
  return choice == 1
end

--- Rename a file on disk and update its loaded Neovim buffer (if any) cleanly
--- without losing undo history or leaving a stale buffer behind.
---@param old_path string
---@param new_path string
---@return boolean, string|nil
local function rename_on_disk_and_buffer(old_path, new_path)
  local old_norm = utils.normalize(old_path)
  local new_norm = utils.normalize(new_path)
  if old_norm == new_norm then
    return true, nil
  end
  if utils.exists(new_norm) then
    return false, "Target file already exists: " .. new_norm
  end

  local bufnr = utils.find_buffer(old_norm)

  -- If the file exists on disk, move it with uv.fs_rename
  if utils.exists(old_norm) then
    local ok_mv, err = uv.fs_rename(old_norm, new_norm)
    if not ok_mv then
      return false, "Failed to rename file: " .. tostring(err)
    end
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_set_name(bufnr, new_norm)
    -- Remove any phantom alternate buffer pointing at the old path
    local old_buf = vim.fn.bufnr("^" .. vim.fn.escape(old_norm, "\\.*[]^$~/") .. "$")
    if old_buf ~= -1 and old_buf ~= bufnr then
      pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
    end
  end

  return true, nil
end

--- Update front matter on either the loaded buffer or the file on disk.
---@param path string
---@param updates table
---@param add_if_missing? boolean
---@return boolean changed
local function sync_front_matter(path, updates, add_if_missing)
  local ft = frontmatter.detect_file_type(path)
  if not ft then
    return false
  end

  local bufnr = utils.find_buffer(path)
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_lines, changed = frontmatter.rewrite_lines(lines, ft, updates, { add_if_missing = add_if_missing })
    if changed then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
      if utils.exists(path) then
        utils.write_lines(path, new_lines)
        vim.bo[bufnr].modified = false
      end
    end
    return changed
  else
    if not utils.exists(path) then
      return false
    end
    local lines = utils.read_lines(path)
    local new_lines, changed = frontmatter.rewrite_lines(lines, ft, updates, { add_if_missing = add_if_missing })
    if changed then
      utils.write_lines(path, new_lines)
    end
    return changed
  end
end

---@class denote.RenameOpts
---@field file? string Target file path (default: current buffer)
---@field title? string New title (pass "" to remove title)
---@field keywords? string[]|string New keywords (pass {} to remove keywords)
---@field signature? string New signature (pass "" to remove signature)
---@field identifier? string New identifier (keeps existing or generates from mtime/now)
---@field date? string|integer New date (recomputes identifier)
---@field rewrite_front_matter? boolean Default true for supported text file types
---@field add_front_matter? boolean Add front matter if missing (default false)

--- Synchronously rename `file` with the provided component updates and sync front matter.
---@param opts denote.RenameOpts
---@return string|nil new_path, string|nil err
function M.rename_sync(opts)
  opts = opts or {}
  local path = opts.file
  if not path or path == "" then
    path = vim.api.nvim_buf_get_name(0)
  end
  if not path or path == "" then
    return nil, "Current buffer has no file name"
  end
  path = utils.normalize(path)

  local parsed = naming.parse_filename(path)
  local fm = frontmatter.parse_file(path)
  local dir = vim.fn.fnamemodify(path, ":h")

  -- Determine identifier: explicit > date > existing > unique from mtime/now
  local id = opts.identifier
  local ts = nil
  if not id and opts.date then
    local parsed_ts, derr = utils.parse_date(opts.date)
    if not parsed_ts then
      return nil, derr
    end
    ts = parsed_ts
    local existing = files.identifier_set(dir)
    if parsed.identifier then
      existing[parsed.identifier] = nil
    end
    id = naming.unique_identifier(ts, existing)
  elseif not id then
    if parsed.identifier then
      id = parsed.identifier
    else
      local st = uv.fs_stat(path)
      local base_ts = (st and st.mtime and st.mtime.sec) or os.time()
      id = naming.unique_identifier(base_ts, files.identifier_set(dir))
    end
  end

  local title = opts.title
  if title == nil then
    title = (fm and fm.title) or (parsed.title and naming.desluggify("title", parsed.title)) or ""
  end

  local keywords
  if opts.keywords ~= nil then
    keywords = naming.sluggify_keywords(opts.keywords)
  else
    keywords = parsed.keywords or {}
  end

  local signature
  if opts.signature ~= nil then
    signature = naming.sluggify_signature(opts.signature)
  else
    signature = parsed.signature or ""
  end

  local new_name = naming.format_filename({
    identifier = id,
    signature = signature,
    title = title,
    keywords = keywords,
    extension = parsed.extension,
    sluggify = true,
  })
  local new_path = dir .. "/" .. new_name

  if new_path ~= path then
    if not confirm_action("modify_file_name", string.format("Rename %s -> %s?", parsed.filename, new_name)) then
      return path, nil
    end
    local ok_mv, err = rename_on_disk_and_buffer(path, new_path)
    if not ok_mv then
      return nil, err
    end
  end

  if opts.rewrite_front_matter ~= false and frontmatter.detect_file_type(new_path) then
    local fm_now = frontmatter.parse_file(new_path)
    local should_add = opts.add_front_matter == true
    if fm_now and fm_now.has_front_matter then
      if confirm_action("rewrite_front_matter", "Rewrite front matter in " .. new_name .. "?") then
        sync_front_matter(new_path, {
          title = title,
          keywords = keywords,
          signature = signature,
          identifier = id,
        }, false)
      end
    elseif should_add then
      if confirm_action("add_front_matter", "Add front matter to " .. new_name .. "?") then
        sync_front_matter(new_path, {
          title = title,
          keywords = keywords,
          signature = signature,
          identifier = id,
          date = ts or naming.identifier_to_time(id) or os.time(),
        }, true)
      end
    end
  end

  return new_path, nil
end

--- Interactively rename a file (title, keywords, signature) matching `denote-rename-file`.
---@param file? string Target file path (default: current buffer)
function M.rename_file(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  path = utils.normalize(path)
  local parsed = naming.parse_filename(path)
  local fm = frontmatter.parse_file(path)

  local cur_title = (fm and fm.title) or (parsed.title and naming.desluggify("title", parsed.title)) or ""
  local cur_kws = table.concat(parsed.keywords or {}, ", ")
  local cur_sig = parsed.signature or ""

  vim.ui.input({ prompt = "Rename title: ", default = cur_title }, function(new_title)
    if new_title == nil then
      return
    end
    vim.ui.input({ prompt = "Rename keywords: ", default = cur_kws }, function(new_kws)
      if new_kws == nil then
        return
      end
      vim.ui.input({ prompt = "Rename signature: ", default = cur_sig }, function(new_sig)
        if new_sig == nil then
          return
        end
        local new_path, err = M.rename_sync({
          file = path,
          title = vim.trim(new_title),
          keywords = utils.parse_keywords_input(new_kws),
          signature = vim.trim(new_sig),
        })
        if err then
          utils.error(err)
        elseif new_path then
          utils.notify("Renamed to " .. vim.fn.fnamemodify(new_path, ":t"))
        end
      end)
    end)
  end)
end

--- Interactively rename only the title (`denote-rename-file-title`).
---@param file? string
function M.rename_file_title(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  local parsed = naming.parse_filename(path)
  local fm = frontmatter.parse_file(path)
  local cur = (fm and fm.title) or (parsed.title and naming.desluggify("title", parsed.title)) or ""
  vim.ui.input({ prompt = "New title: ", default = cur }, function(input)
    if input == nil then
      return
    end
    local new_path, err = M.rename_sync({ file = path, title = vim.trim(input) })
    if err then
      utils.error(err)
    elseif new_path then
      utils.notify("Renamed to " .. vim.fn.fnamemodify(new_path, ":t"))
    end
  end)
end

--- Interactively rename only the keywords (`denote-rename-file-keywords`).
---@param file? string
function M.rename_file_keywords(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  local parsed = naming.parse_filename(path)
  vim.ui.input({ prompt = "New keywords: ", default = table.concat(parsed.keywords or {}, ", ") }, function(input)
    if input == nil then
      return
    end
    local new_path, err = M.rename_sync({ file = path, keywords = utils.parse_keywords_input(input) })
    if err then
      utils.error(err)
    elseif new_path then
      utils.notify("Renamed to " .. vim.fn.fnamemodify(new_path, ":t"))
    end
  end)
end

--- Interactively rename only the signature (`denote-rename-file-signature`).
---@param file? string
function M.rename_file_signature(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  local parsed = naming.parse_filename(path)
  vim.ui.input({ prompt = "New signature: ", default = parsed.signature or "" }, function(input)
    if input == nil then
      return
    end
    local new_path, err = M.rename_sync({ file = path, signature = vim.trim(input) })
    if err then
      utils.error(err)
    elseif new_path then
      utils.notify("Renamed to " .. vim.fn.fnamemodify(new_path, ":t"))
    end
  end)
end

--- Interactively change the date / identifier (`denote-rename-file-date`).
---@param file? string
function M.rename_file_date(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  local parsed = naming.parse_filename(path)
  local ts = (parsed.identifier and naming.identifier_to_time(parsed.identifier)) or os.time()
  vim.ui.input(
    { prompt = "New date (YYYY-MM-DD HH:MM:SS): ", default = tostring(os.date("%Y-%m-%d %H:%M:%S", ts)) },
    function(input)
      if input == nil or vim.trim(input) == "" then
        return
      end
      local new_path, err = M.rename_sync({ file = path, date = vim.trim(input) })
      if err then
        utils.error(err)
      elseif new_path then
        utils.notify("Renamed to " .. vim.fn.fnamemodify(new_path, ":t"))
      end
    end
  )
end

--- Rename a file on disk using the metadata currently in its front matter
--- (`denote-rename-file-using-front-matter`).
---@param file? string
---@return string|nil new_path, string|nil err
function M.rename_file_using_front_matter(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    return nil, "Current buffer has no file name"
  end
  path = utils.normalize(path)
  local fm = frontmatter.parse_file(path)
  if not fm or not fm.has_front_matter then
    local err = "No front matter found in " .. vim.fn.fnamemodify(path, ":t")
    if not file then
      utils.warn(err)
    end
    return nil, err
  end

  local parsed = naming.parse_filename(path)
  local id = (fm.identifier and fm.identifier:match("^" .. naming.ID_PATTERN .. "$")) and fm.identifier
    or parsed.identifier

  local new_path, err = M.rename_sync({
    file = path,
    title = fm.title or "",
    keywords = fm.keywords or {},
    signature = fm.signature ~= nil and fm.signature or (parsed.signature or ""),
    identifier = id,
    rewrite_front_matter = false,
  })
  if err and not file then
    utils.error(err)
  elseif new_path and new_path ~= path and not file then
    utils.notify("Synced filename to " .. vim.fn.fnamemodify(new_path, ":t"))
  end
  return new_path, err
end

--- Add Denote front matter to a file that doesn't have one (`denote-add-front-matter`).
---@param file? string
---@return boolean, string|nil
function M.add_front_matter(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    return false, "Current buffer has no file name"
  end
  path = utils.normalize(path)
  local ft = frontmatter.detect_file_type(path)
  if not ft then
    local err = "Unsupported file type for front matter: " .. path
    if not file then
      utils.warn(err)
    end
    return false, err
  end
  local fm = frontmatter.parse_file(path)
  if fm and fm.has_front_matter then
    local err = "File already has front matter"
    if not file then
      utils.notify(err)
    end
    return false, err
  end
  local parsed = naming.parse_filename(path)
  local id = parsed.identifier
    or naming.unique_identifier(os.time(), files.identifier_set(vim.fn.fnamemodify(path, ":h")))
  local title = parsed.title and naming.desluggify("title", parsed.title) or naming.split_extension(parsed.filename)
  local changed = sync_front_matter(path, {
    title = title,
    keywords = parsed.keywords or {},
    signature = parsed.signature or "",
    identifier = id,
    date = naming.identifier_to_time(id) or os.time(),
  }, true)
  return changed, nil
end

--- Add keywords to `file` (updating filename and front matter) (`denote-keywords-add`).
---@param keywords string[]|string|nil Pass nil to prompt interactively
---@param file? string
---@return string|nil, string|nil
function M.keywords_add(keywords, file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    return nil, "Current buffer has no file name"
  end
  local function apply(add_kws)
    local parsed = naming.parse_filename(path)
    local merged = vim.list_extend(vim.deepcopy(parsed.keywords or {}), utils.parse_keywords_input(add_kws))
    return M.rename_sync({ file = path, keywords = merged })
  end
  if keywords ~= nil then
    return apply(keywords)
  end
  vim.ui.input({ prompt = "Add keywords: " }, function(input)
    if input and vim.trim(input) ~= "" then
      local new_path, err = apply(input)
      if err then
        utils.error(err)
      elseif new_path then
        utils.notify("Updated keywords: " .. vim.fn.fnamemodify(new_path, ":t"))
      end
    end
  end)
end

--- Remove keywords from `file` (updating filename and front matter) (`denote-keywords-remove`).
---@param keywords string[]|string|nil Pass nil to prompt interactively
---@param file? string
---@return string|nil, string|nil
function M.keywords_remove(keywords, file)
  local path = file or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    return nil, "Current buffer has no file name"
  end
  local function apply(rem_kws)
    local parsed = naming.parse_filename(path)
    local to_remove = {}
    for _, kw in ipairs(naming.sluggify_keywords(rem_kws)) do
      to_remove[kw] = true
    end
    local kept = {}
    for _, kw in ipairs(parsed.keywords or {}) do
      if not to_remove[kw] then
        kept[#kept + 1] = kw
      end
    end
    return M.rename_sync({ file = path, keywords = kept })
  end
  if keywords ~= nil then
    return apply(keywords)
  end
  local parsed = naming.parse_filename(path)
  if #parsed.keywords == 0 then
    utils.notify("File has no keywords to remove")
    return
  end
  vim.ui.input({
    prompt = "Remove keywords (" .. table.concat(parsed.keywords, ", ") .. "): ",
  }, function(input)
    if input and vim.trim(input) ~= "" then
      local new_path, err = apply(input)
      if err then
        utils.error(err)
      elseif new_path then
        utils.notify("Updated keywords: " .. vim.fn.fnamemodify(new_path, ":t"))
      end
    end
  end)
end

--- Format a human-friendly buffer label (matching `denote-rename-buffer-format`).
--- Tokens: `%t` title, `%i` identifier, `%s` signature, `%k` keywords, `%d` date (YYYY-MM-DD).
---@param bufnr? integer
---@param fmt? string
---@return string
function M.format_buffer_name(bufnr, fmt)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return ""
  end
  local parsed = naming.parse_filename(path)
  if not parsed.is_denote then
    return ""
  end
  local title = frontmatter.extract_title(path)
  local ts = naming.identifier_to_time(parsed.identifier)
  local date_str = ts and tostring(os.date("%Y-%m-%d", ts)) or ""
  local template = fmt or config.opts.rename_buffer_format or "%t"
  local map = {
    t = title,
    i = parsed.identifier or "",
    s = parsed.signature or "",
    k = table.concat(parsed.keywords or {}, ","),
    d = date_str,
  }
  return (template:gsub("%%([tiskd])", function(c)
    return map[c] or ""
  end))
end

return M
