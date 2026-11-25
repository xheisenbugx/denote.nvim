---@mod denote.rename Renaming Denote files and syncing front matter
---@brief [[
--- Supports two-way synchronization between Denote filenames and front matter:
--- - `rename_file`: rename ANY file (including PDFs, images, non-Denote files) into
---   Denote's naming scheme and optionally update/add front matter.
--- - `rename_file_title`, `rename_file_keywords`, `rename_file_signature`, `rename_file_date`
--- - `rename_file_using_front_matter`: sync filename on disk from edits inside front matter.
--- - `add_front_matter`: prepend Denote front matter to a note lacking it.
--- - `keywords_add` / `keywords_remove`: quick keyword edits.
--- - `format_buffer_name` / `statusline`: Denote rename-buffer display formatting.
---@brief ]]

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

local uv = vim.uv or vim.loop

--- Re-entrancy guard preventing `auto_rename_on_save` from looping when rename writes a buffer.
local renaming_bufs = {}

--- Return true when `bufnr` is currently being written by `denote.rename`.
---@param bufnr integer
---@return boolean
function M.is_renaming(bufnr)
  return renaming_bufs[bufnr] == true
end

--- Save a loaded normal buffer through Neovim's `:silent write!` so `BF_NOTEDITED` is cleared,
--- file mtime stays synced with Neovim (preventing `E13` / `Overwrite existing file` / `W11`),
--- and `BufWritePost` hooks (org.reload, gitsigns, LSP) stay in sync.
---@param bufnr integer
---@param path string
local function save_loaded_buffer(bufnr, path)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return
  end
  if vim.bo[bufnr].buftype ~= "" then
    return
  end
  renaming_bufs[bufnr] = true
  local ok = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent write!")
  end)
  renaming_bufs[bufnr] = nil
  if not ok then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if utils.write_lines(path, lines) then
      pcall(function()
        vim.bo[bufnr].modified = false
      end)
    end
  end
end

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
---@return boolean ok
---@return string|nil err
---@return boolean existed_on_disk
local function rename_on_disk_and_buffer(old_path, new_path)
  local old_norm = utils.normalize(old_path)
  local new_norm = utils.normalize(new_path)
  if old_norm == new_norm then
    return true, nil, utils.exists(old_norm)
  end

  local st_old = uv.fs_stat(old_norm)
  local st_new = uv.fs_stat(new_norm)
  local is_same_inode = st_old and st_new and st_old.ino and st_new.ino and st_old.ino == st_new.ino
  local is_case_only = old_norm:lower() == new_norm:lower() and old_norm ~= new_norm
  if st_new and not (is_case_only and is_same_inode) then
    return false, "Target file already exists: " .. new_norm, false
  end

  local bufnr = utils.find_buffer(old_norm)
  local existed_on_disk = st_old ~= nil

  -- If the file exists on disk, move it with uv.fs_rename
  if existed_on_disk then
    local ok_mv, err = uv.fs_rename(old_norm, new_norm)
    if not ok_mv then
      return false, "Failed to rename file: " .. tostring(err), false
    end
    utils.notify_fs_change()
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    -- Wipe any stale unloaded buffer holding `new_norm` so `nvim_buf_set_name` never throws E95
    local existing_target = utils.find_buffer(new_norm)
    if existing_target and existing_target ~= bufnr and not vim.api.nvim_buf_is_loaded(existing_target) then
      pcall(vim.api.nvim_buf_delete, existing_target, { force = true })
    end

    local ok_set, set_err = pcall(vim.api.nvim_buf_set_name, bufnr, new_norm)
    if not ok_set then
      -- Roll back disk rename if buffer rename failed
      if existed_on_disk then
        pcall(uv.fs_rename, new_norm, old_norm)
      end
      return false, "Failed to rename buffer: " .. tostring(set_err), false
    end

    -- Remove any phantom alternate buffer created by nvim_buf_set_name pointing at the old path
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= bufnr and vim.api.nvim_buf_is_valid(b) then
        local bname = vim.api.nvim_buf_get_name(b)
        if bname ~= "" and utils.normalize(bname) == old_norm then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
  end

  frontmatter.evict_cache(old_norm)
  return true, nil, existed_on_disk
end

--- Collect all identifiers across the active Denote directory, `dir`, and open buffers (excluding `self_path`).
---@param dir string
---@param self_path? string
---@return table<string, boolean>
local function collect_existing_ids(dir, self_path)
  local existing = files.identifier_set(config.directory())
  local norm_dir = utils.normalize(dir)
  if norm_dir ~= config.directory() and utils.is_dir(norm_dir) then
    for id in pairs(files.identifier_set(norm_dir)) do
      existing[id] = true
    end
  end
  local self_norm = self_path and utils.normalize(self_path) or nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      local bname = vim.api.nvim_buf_get_name(b)
      if bname ~= "" and utils.normalize(bname) ~= self_norm then
        local bid = naming.retrieve_identifier(bname)
        if bid then
          existing[bid] = true
        end
      end
    end
  end
  return existing
end

--- Update front matter on either the loaded buffer or the file on disk.
---@param path string
---@param updates table
---@param add_if_missing? boolean
---@param force_save_loaded? boolean
---@return boolean changed
---@return boolean saved_loaded
local function sync_front_matter(path, updates, add_if_missing, force_save_loaded)
  local bufnr = utils.find_buffer(path)
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ft = frontmatter.detect_file_type(path, lines)
    if not ft then
      return false, false
    end
    local was_modified = vim.bo[bufnr].modified
    local new_lines, changed = frontmatter.rewrite_lines(lines, ft, updates, { add_if_missing = add_if_missing })
    local saved = false
    if changed and vim.bo[bufnr].modifiable then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    end
    if (changed or (force_save_loaded and not was_modified)) and utils.exists(path) then
      save_loaded_buffer(bufnr, path)
      saved = true
    end
    return changed, saved
  else
    if not utils.exists(path) then
      return false, false
    end
    local lines = utils.read_lines(path)
    local ft = frontmatter.detect_file_type(path, lines)
    if not ft then
      return false, false
    end
    local new_lines, changed = frontmatter.rewrite_lines(lines, ft, updates, { add_if_missing = add_if_missing })
    if changed then
      utils.write_lines(path, new_lines)
    end
    return changed, false
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
---@return string|nil new_path
---@return string|nil err
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
    local existing = collect_existing_ids(dir, path)
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
      id = naming.unique_identifier(base_ts, collect_existing_ids(dir, path))
    end
  end

  local title = opts.title
  if title == nil then
    title = (fm and fm.title and fm.title ~= "") and fm.title
      or (parsed.title and naming.desluggify("title", parsed.title))
      or ""
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

  local renamed_on_disk = false
  if new_path ~= path then
    if not confirm_action("modify_file_name", string.format("Rename %s -> %s?", parsed.filename, new_name)) then
      return path, nil
    end
    local ok_mv, err, existed_on_disk = rename_on_disk_and_buffer(path, new_path)
    if not ok_mv then
      return nil, err
    end
    renamed_on_disk = existed_on_disk
  end

  local saved_loaded = false
  if opts.rewrite_front_matter ~= false and frontmatter.detect_file_type(new_path) then
    local fm_now = frontmatter.parse_file(new_path)
    local should_add = opts.add_front_matter == true
    if fm_now and fm_now.has_front_matter then
      if confirm_action("rewrite_front_matter", "Rewrite front matter in " .. new_name .. "?") then
        local _, did_save = sync_front_matter(new_path, {
          title = title,
          date = ts,
          keywords = keywords,
          signature = signature,
          identifier = id,
        }, false, renamed_on_disk)
        saved_loaded = did_save
      end
    elseif should_add then
      if confirm_action("add_front_matter", "Add front matter to " .. new_name .. "?") then
        local _, did_save = sync_front_matter(new_path, {
          title = title,
          keywords = keywords,
          signature = signature,
          identifier = id,
          date = ts or naming.identifier_to_time(id) or os.time(),
        }, true, renamed_on_disk)
        saved_loaded = did_save
      end
    end
  end

  -- Ensure a loaded buffer renamed on disk clears BF_NOTEDITED even when front matter was untouched
  if renamed_on_disk and not saved_loaded then
    local loaded_buf = utils.find_buffer(new_path)
    if loaded_buf and vim.api.nvim_buf_is_loaded(loaded_buf) then
      if not vim.bo[loaded_buf].modified then
        save_loaded_buffer(loaded_buf, new_path)
      else
        utils.warn("Renamed file on disk; buffer has unsaved edits — run :w to save")
      end
    end
  end

  local hook = config.opts.after_rename_file_hook
  local event_data =
    { old_path = path, new_path = new_path, identifier = id, title = title, keywords = keywords, signature = signature }
  if type(hook) == "function" then
    pcall(hook, new_path, path, event_data)
  elseif type(hook) == "table" then
    for _, fn in ipairs(hook) do
      if type(fn) == "function" then
        pcall(fn, new_path, path, event_data)
      end
    end
  end
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "DenoteRenameFile", data = event_data })

  return new_path, nil
end

--- Interactively rename a file (title, keywords, signature) matching `denote-rename-file`.
---@param file? string Target file path (default: current buffer)
---@param on_done? fun(new_path: string|nil, err: string|nil) Optional callback after completion
function M.rename_file(file, on_done)
  local path = file or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  path = utils.normalize(path)
  local parsed = naming.parse_filename(path)
  local fm = frontmatter.parse_file(path)

  local cur_title = (fm and fm.title and fm.title ~= "") and fm.title
    or (parsed.title and naming.desluggify("title", parsed.title))
    or ""
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
        if on_done then
          on_done(new_path, err)
        end
      end)
    end)
  end)
end

--- Interactively rename only the title (`denote-rename-file-title`).
---@param file? string
---@param on_done? fun(new_path: string|nil, err: string|nil)
function M.rename_file_title(file, on_done)
  local path = file or vim.api.nvim_buf_get_name(0)
  if path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  local parsed = naming.parse_filename(path)
  local fm = frontmatter.parse_file(path)
  local cur = (fm and fm.title and fm.title ~= "") and fm.title
    or (parsed.title and naming.desluggify("title", parsed.title))
    or ""
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
    if on_done then
      on_done(new_path, err)
    end
  end)
end

--- Interactively rename only the keywords (`denote-rename-file-keywords`).
---@param file? string
---@param on_done? fun(new_path: string|nil, err: string|nil)
function M.rename_file_keywords(file, on_done)
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
    if on_done then
      on_done(new_path, err)
    end
  end)
end

--- Interactively rename only the signature (`denote-rename-file-signature`).
---@param file? string
---@param on_done? fun(new_path: string|nil, err: string|nil)
function M.rename_file_signature(file, on_done)
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
    if on_done then
      on_done(new_path, err)
    end
  end)
end

--- Interactively change the date / identifier (`denote-rename-file-date`).
---@param file? string
---@param on_done? fun(new_path: string|nil, err: string|nil)
function M.rename_file_date(file, on_done)
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
      if on_done then
        on_done(new_path, err)
      end
    end
  )
end

--- Rename a file on disk using the metadata currently in its front matter
--- (`denote-rename-file-using-front-matter`).
---@param file? string
---@return string|nil new_path
---@return string|nil err
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
---@return boolean
---@return string|nil
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
    or naming.unique_identifier(os.time(), collect_existing_ids(vim.fn.fnamemodify(path, ":h"), path))
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
---@return string|nil
---@return string|nil
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
---@return string|nil
---@return string|nil
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

--- Interactively change the identifier directly (`denote-rename-file-identifier`).
---@param file? string
---@param on_done? fun(new_path: string|nil, err: string|nil)
function M.rename_file_identifier(file, on_done)
  local path = file or vim.api.nvim_buf_get_name(0)
  if path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  local parsed = naming.parse_filename(path)
  vim.ui.input({
    prompt = "New identifier (YYYYMMDDTHHMMSS): ",
    default = parsed.identifier or naming.format_identifier(),
  }, function(input)
    if input == nil or vim.trim(input) == "" then
      return
    end
    local id = vim.trim(input)
    if not id:match("^" .. naming.ID_PATTERN .. "$") then
      utils.error("Invalid Denote identifier (expected YYYYMMDDTHHMMSS): " .. id)
      return
    end
    local new_path, err = M.rename_sync({ file = path, identifier = id })
    if err then
      utils.error(err)
    elseif new_path then
      utils.notify("Renamed to " .. vim.fn.fnamemodify(new_path, ":t"))
    end
    if on_done then
      on_done(new_path, err)
    end
  end)
end

--- Change the file type (extension) and rewrite front matter into the new format
--- (`denote-change-file-type-and-front-matter`).
--- Converts e.g. Markdown (YAML/TOML) <-> Org <-> Plain Text without losing metadata or body.
---@param file? string
---@param new_file_type? string
---@return string|nil new_path
---@return string|nil err
function M.change_file_type_and_front_matter(file, new_file_type)
  local path = file or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    return nil, "Current buffer has no file name"
  end
  path = utils.normalize(path)

  local function apply(target_ft)
    local _, ft = frontmatter.get_spec(target_ft)
    local new_ext = frontmatter.extension_for(ft)
    local parsed = naming.parse_filename(path)
    local bufnr = utils.find_buffer(path)
    local lines
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    else
      lines = utils.read_lines(path)
    end

    local old_ft = frontmatter.detect_file_type(path, lines)
    local old_fm = old_ft and frontmatter.parse_lines(lines, old_ft) or nil
    local body_lines = frontmatter.strip_front_matter(lines, old_ft)

    local dir = vim.fn.fnamemodify(path, ":h")
    local id = (old_fm and old_fm.identifier and old_fm.identifier:match("^" .. naming.ID_PATTERN .. "$"))
        and old_fm.identifier
      or parsed.identifier
      or naming.unique_identifier(os.time(), collect_existing_ids(dir, path))
    local title = (old_fm and old_fm.title and old_fm.title ~= "") and old_fm.title
      or (parsed.title and naming.desluggify("title", parsed.title))
      or naming.split_extension(parsed.filename)
    local keywords = (old_fm and old_fm.keywords) or parsed.keywords or {}
    local signature = (old_fm and old_fm.signature and old_fm.signature ~= "") and old_fm.signature
      or (parsed.signature or "")
    local ts = naming.identifier_to_time(id) or os.time()

    local new_name = naming.format_filename({
      identifier = id,
      signature = signature,
      title = title,
      keywords = keywords,
      extension = new_ext,
      sluggify = true,
    })
    local new_path = dir .. "/" .. new_name

    if new_path ~= path then
      local ok_mv, mv_err = rename_on_disk_and_buffer(path, new_path)
      if not ok_mv then
        return nil, mv_err
      end
    end

    local new_fm = frontmatter.format({
      title = title,
      date = ts,
      keywords = keywords,
      identifier = id,
      signature = signature,
      file_type = ft,
    })
    local fm_lines = vim.split(new_fm, "\n", { plain = true })
    if #fm_lines > 0 and fm_lines[#fm_lines] == "" then
      table.remove(fm_lines)
    end
    local final_lines = vim.list_extend(fm_lines, body_lines)

    local target_buf = utils.find_buffer(new_path)
    if target_buf and vim.api.nvim_buf_is_loaded(target_buf) then
      if vim.bo[target_buf].modifiable then
        vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, final_lines)
      end
      save_loaded_buffer(target_buf, new_path)
      -- Re-detect Neovim filetype for the new extension
      pcall(vim.api.nvim_buf_call, target_buf, function()
        vim.cmd("filetype detect")
      end)
    else
      utils.write_lines(new_path, final_lines)
    end

    return new_path, nil
  end

  if new_file_type then
    return apply(new_file_type)
  end

  local types = vim.tbl_keys(frontmatter.file_types())
  table.sort(types)
  local items = {}
  for _, ft in ipairs(types) do
    local ext = frontmatter.extension_for(ft)
    items[#items + 1] = {
      display = { { ft, "DenoteTitle" }, { " (" .. ext .. ")", "DenoteExtension" } },
      text = ft .. " " .. ext,
      value = ft,
    }
  end
  require("denote.pickers").pick({
    title = "Change File Type & Front Matter",
    items = items,
    preview = false,
    on_choice = function(chosen)
      if chosen[1] then
        local np, err = apply(chosen[1].value)
        if err then
          utils.error(err)
        elseif np then
          utils.notify("Converted to " .. vim.fn.fnamemodify(np, ":t"))
        end
      end
    end,
  })
end

--- Format a human-friendly buffer label (matching `denote-rename-buffer-format`).
--- Specifiers:
---   %t  front matter title (or filename title)
---   %T  filename title (desluggified)
---   %i  identifier (`YYYYMMDDTHHMMSS`)
---   %I  human date from identifier (`Mon, 23 Nov 2026`)
---   %d  identifier (DATE mnemonic, same as %i)
---   %D  DWIM: %t if non-empty, else %I, else %i (upstream default)
---   %s  signature
---   %k  keywords
---   %b  backlinks indicator (`rename_buffer_backlinks_indicator`) if note has backlinks
---   %%  literal `%`
---@param bufnr? integer
---@param fmt? string
---@return string
function M.format_buffer_name(bufnr, fmt)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return ""
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return ""
  end
  local parsed = naming.parse_filename(path)
  if not parsed.is_denote then
    return ""
  end
  local fm_title = frontmatter.extract_title(path)
  local file_title = parsed.title and naming.desluggify("title", parsed.title) or ""
  local ts = naming.identifier_to_time(parsed.identifier)
  local human_date = ts and tostring(os.date("%a, %d %b %Y", ts)) or ""
  local dwim = (fm_title ~= "" and fm_title) or (human_date ~= "" and human_date) or (parsed.identifier or "")
  local template = fmt or config.opts.rename_buffer_format or "%D"

  local rendered = (
    template:gsub("%%([tTiIdDskb%%])", function(c)
      if c == "%" then
        return "%"
      elseif c == "t" then
        return fm_title
      elseif c == "T" then
        return file_title
      elseif c == "i" or c == "d" then
        return parsed.identifier or ""
      elseif c == "I" then
        return human_date
      elseif c == "D" then
        return dwim
      elseif c == "s" then
        return parsed.signature or ""
      elseif c == "k" then
        return table.concat(parsed.keywords or {}, ",")
      elseif c == "b" then
        local has = require("denote.backlinks").has_backlinks(parsed.identifier, path)
        return has and (config.opts.rename_buffer_backlinks_indicator or " <-->") or ""
      end
      return ""
    end)
  )

  local prefix = config.opts.buffer_name_prefix or ""
  return prefix .. rendered
end

return M
