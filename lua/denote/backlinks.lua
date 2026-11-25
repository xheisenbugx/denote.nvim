---@mod denote.backlinks Backlinks discovery and interactive backlinks buffer
---@brief [[
--- Mirrors Emacs `denote-backlinks` and `denote-find-backlink`:
--- - Finds every note in the Denote directory referencing the current note's identifier.
--- - Works with zero external dependencies (pure Lua scanner) and accelerates with `rg` when available.
--- - Opens an interactive split buffer showing file headers + matching context lines
---   with `<CR>` to jump, `o` other window, `f` toggle context/filenames-only, `r` refresh, `q` close.
---@brief ]]

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local pickers = require("denote.pickers")
local sort = require("denote.sort")
local utils = require("denote.utils")

local M = {}

---@class denote.BacklinkMatch
---@field file string Absolute path of linking file
---@field lnum integer 1-based line number of reference
---@field col integer 1-based column of reference
---@field text string Trimmed line text

--- Build the search spec for backlinks to `identifier`.
---@param identifier string
---@param opts table
---@return denote.SearchSpec
local function backlink_spec(identifier, opts)
  local exclude = opts.exclude_file and utils.normalize(opts.exclude_file) or nil
  local exclude_real = exclude and config.canonicalize(exclude) or nil
  local dirs = opts.dir and { config.directory(opts.dir) } or files.search_dirs()
  local seen_paths, candidates = {}, {}
  for _, d in ipairs(dirs) do
    for _, path in
      ipairs(files.list({
        dir = d,
        denote_only = true,
        text_only = true,
        not_regexp = opts.not_regexp,
        excluded_dirs_regexp = opts.excluded_dirs_regexp,
      }))
    do
      local norm = utils.normalize(path)
      if norm ~= exclude and norm ~= exclude_real and not seen_paths[norm] then
        seen_paths[norm] = true
        candidates[#candidates + 1] = path
      end
    end
  end
  local root = (#dirs == 1) and dirs[1] or nil
  return { pattern = identifier, fixed = true, case = "sensitive", files = candidates, root = root }
end

--- Drop matches that are inside a file's own front matter (e.g. its `identifier:` line).
---@param matches denote.SearchMatch[]
---@return denote.BacklinkMatch[]
local function drop_front_matter(matches)
  local fm_end = {}
  local out = {}
  for _, m in ipairs(matches) do
    if fm_end[m.file] == nil then
      local fm = frontmatter.parse_file(m.file)
      fm_end[m.file] = (fm and fm.has_front_matter) and fm.end_line or 0
    end
    if m.lnum > fm_end[m.file] then
      out[#out + 1] = m
    end
  end
  return out
end

--- Collect all backlinks referencing `identifier` across `dir` (excluding `exclude_file`).
--- Uses `rg` when available (see `denote.search`); pass `on_done` to run asynchronously.
---@param identifier string
---@param opts? { dir?: string, exclude_file?: string, not_regexp?: string, excluded_dirs_regexp?: string }
---@param on_done? fun(matches: denote.BacklinkMatch[])
---@return denote.BacklinkMatch[]|denote.SearchHandle
function M.find(identifier, opts, on_done)
  opts = opts or {}
  local search = require("denote.search")
  if not identifier or identifier == "" then
    return search.run({ pattern = "", files = {} }, on_done)
  end
  local spec = backlink_spec(identifier, opts)
  if on_done then
    return search.run(spec, function(matches)
      on_done(drop_front_matter(matches))
    end)
  end
  return drop_front_matter(search.run(spec) --[[@as denote.SearchMatch[] ]])
end

---@type table<string, { value: boolean, pending?: boolean, time?: integer, generation?: integer }>
local has_cache = {}

--- Clear the cached backlink presence indicators (`%b` statusline cache).
function M.clear_cache()
  has_cache = {}
end

--- Return true if any note links to `identifier`. The answer is cached per directory & identifier and
--- refreshed asynchronously, so this is cheap enough to call from a statusline.
---@param identifier string
---@param path? string The note itself (excluded from the search)
---@return boolean
function M.has_backlinks(identifier, path)
  if not identifier or identifier == "" then
    return false
  end
  local cache_key = config.directory() .. "\0" .. identifier
  local entry = has_cache[cache_key]
  local now = (vim.uv or vim.loop).now()
  local ttl = (config.opts.search and config.opts.search.backlinks_indicator_ttl) or 10000
  if not entry or (not entry.pending and (now - entry.time > ttl or entry.generation ~= files.generation)) then
    entry = entry or { value = false }
    entry.pending = true
    has_cache[cache_key] = entry
    -- Record the generation the search started at: changes made while it runs trigger a re-check.
    local started_generation = files.generation
    M.find(identifier, { exclude_file = path }, function(matches)
      local changed = entry.value ~= (#matches > 0)
      entry.value = #matches > 0
      entry.pending = false
      entry.time = (vim.uv or vim.loop).now()
      entry.generation = started_generation
      if changed then
        pcall(vim.cmd.redrawstatus)
      end
    end)
  end
  return entry.value
end

--- Return deduplicated list of files that link to `identifier`.
---@param identifier string
---@param opts? { dir?: string, exclude_file?: string, sort_by?: string, reverse?: boolean, not_regexp?: string, excluded_dirs_regexp?: string }
---@return string[]
function M.files_for(identifier, opts)
  opts = opts or {}
  local raw = M.find(identifier, opts)
  local seen, out = {}, {}
  for _, m in ipairs(raw) do
    if not seen[m.file] then
      seen[m.file] = true
      out[#out + 1] = m.file
    end
  end
  return sort.sort_files(out, opts.sort_by or "identifier", opts.reverse)
end

--- Jump to a backlink file via fuzzy picker (`denote-find-backlink`).
---@param file? string
function M.find_backlink(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  local id = naming.retrieve_identifier(path)
  if not id then
    utils.warn("Current file is not a Denote note (no identifier)")
    return
  end

  local backlink_files = M.files_for(id, { exclude_file = path })
  if #backlink_files == 0 then
    utils.notify("No backlinks found for " .. id)
    return
  end

  local items = {}
  for i, f in ipairs(backlink_files) do
    items[i] = pickers.file_item(f)
  end

  pickers.pick({
    title = "Backlinks to " .. frontmatter.extract_title(path),
    items = items,
    on_choice = function(chosen, _, how)
      if chosen[1] then
        utils.open_file(chosen[1].value, how)
      end
    end,
  })
end

--- Jump directly to the exact line of a backlink via fuzzy picker
--- (`denote-find-backlink-with-location`).
---@param file? string
function M.find_backlink_with_location(file)
  local path = file or vim.api.nvim_buf_get_name(0)
  local id = naming.retrieve_identifier(path)
  if not id then
    utils.warn("Current file is not a Denote note (no identifier)")
    return
  end

  local matches = M.find(id, { exclude_file = path })
  if #matches == 0 then
    utils.notify("No backlinks found for " .. id)
    return
  end

  local items = {}
  for _, m in ipairs(matches) do
    local title = frontmatter.extract_title(m.file)
    items[#items + 1] = {
      display = {
        { title, "DenoteTitle" },
        { string.format(":%d  ", m.lnum), "DenoteBacklinksLineNr" },
        { m.text, "DenoteBacklinksMatch" },
      },
      text = title .. " " .. m.text,
      filename = m.file,
      lnum = m.lnum,
      value = m,
    }
  end

  pickers.pick({
    title = "Backlink Locations for " .. frontmatter.extract_title(path),
    items = items,
    on_choice = function(chosen, _, how)
      if chosen[1] then
        local m = chosen[1].value
        utils.open_file(m.file, how)
        vim.api.nvim_win_set_cursor(0, { m.lnum, math.max(0, m.col - 1) })
      end
    end,
  })
end

local ns = vim.api.nvim_create_namespace("denote_backlinks")

--- Open the interactive Backlinks buffer for `file` (default: current buffer),
--- matching Emacs `denote-backlinks`.
---@param opts? { file?: string, show_context?: boolean, dir?: string }
function M.open(opts)
  opts = opts or {}
  require("denote.ui").ensure_highlights()
  local origin_win = vim.api.nvim_get_current_win()
  local target_file = utils.normalize(opts.file or vim.api.nvim_buf_get_name(0))
  local id = naming.retrieve_identifier(target_file)
  if not id then
    utils.warn("Current file is not a Denote note (no identifier)")
    return
  end

  local title = frontmatter.extract_title(target_file)
  local show_context = opts.show_context
  if show_context == nil then
    show_context = config.opts.backlinks_show_context ~= false
  end

  local buf_name = "denote://backlinks/" .. id
  local old_bufs = {}
  local existing_win
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == buf_name then
      local w = vim.fn.bufwinid(b)
      if w ~= -1 and vim.api.nvim_win_is_valid(w) then
        existing_win = w
      end
      old_bufs[#old_bufs + 1] = b
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "denote-backlinks"

  local line_targets = {}
  local matches = {}
  local loading = true
  local handle = nil

  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.b[buf].denote_loading = loading
    if loading then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        string.format('Backlinks for "%s" (%s)  (searching…)', title, id),
        string.rep("─", 60),
      })
      vim.bo[buf].modifiable = false
      return
    end
    line_targets = {}
    local lines = {}
    local hls = {}

    lines[1] = string.format(
      'Backlinks for "%s" (%s)  [%d match%s]  (g? help)',
      title,
      id,
      #matches,
      #matches == 1 and "" or "es"
    )
    hls[#hls + 1] = { 0, 0, -1, "DenoteBacklinksHeader" }
    lines[2] = string.rep("─", 60)
    hls[#hls + 1] = { 1, 0, -1, "DenoteDelimiter" }

    if #matches == 0 then
      lines[3] = "  (no backlinks found)"
      hls[#hls + 1] = { 2, 0, -1, "Comment" }
    elseif show_context then
      -- Group by file
      local order, grouped = {}, {}
      for _, m in ipairs(matches) do
        if not grouped[m.file] then
          grouped[m.file] = {}
          order[#order + 1] = m.file
        end
        grouped[m.file][#grouped[m.file] + 1] = m
      end

      for _, f in ipairs(order) do
        local f_title = frontmatter.extract_title(f)
        local parsed = naming.parse_filename(f)
        local row = #lines + 1
        lines[row] = string.format("%s  %s", parsed.identifier or "", f_title)
        line_targets[row] = { file = f, lnum = grouped[f][1].lnum, col = grouped[f][1].col }
        hls[#hls + 1] = { row - 1, 0, #(parsed.identifier or ""), "DenoteIdentifier" }
        hls[#hls + 1] = { row - 1, #(parsed.identifier or "") + 2, -1, "DenoteBacklinksFile" }

        for _, m in ipairs(grouped[f]) do
          local mrow = #lines + 1
          local prefix = string.format("  %4d: ", m.lnum)
          lines[mrow] = prefix .. m.text
          line_targets[mrow] = { file = f, lnum = m.lnum, col = m.col }
          hls[#hls + 1] = { mrow - 1, 0, #prefix, "DenoteBacklinksLineNr" }
          hls[#hls + 1] = { mrow - 1, #prefix, -1, "DenoteBacklinksMatch" }
        end
      end
    else
      local seen, unique_files = {}, {}
      for _, m in ipairs(matches) do
        if not seen[m.file] then
          seen[m.file] = true
          unique_files[#unique_files + 1] = m.file
        end
      end
      for _, f in ipairs(sort.sort_files(unique_files, "identifier")) do
        local parsed = naming.parse_filename(f)
        local f_title = frontmatter.extract_title(f)
        local kws = #parsed.keywords > 0 and ("  [" .. table.concat(parsed.keywords, ", ") .. "]") or ""
        local row = #lines + 1
        lines[row] = string.format("%s  %s%s", parsed.identifier or "", f_title, kws)
        line_targets[row] = { file = f, lnum = 1, col = 1 }
        local id_len = #(parsed.identifier or "")
        hls[#hls + 1] = { row - 1, 0, id_len, "DenoteIdentifier" }
        hls[#hls + 1] = { row - 1, id_len + 2, id_len + 2 + #f_title, "DenoteTitle" }
        if kws ~= "" then
          hls[#hls + 1] = { row - 1, id_len + 2 + #f_title, -1, "DenoteKeywords" }
        end
      end
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      utils.add_highlight(buf, ns, h[4], h[1], h[2], h[3])
    end
  end

  local function refresh()
    if handle then
      handle.cancel()
    end
    loading = true
    render()
    handle = M.find(id, { dir = opts.dir, exclude_file = target_file }, function(found)
      handle = nil
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      matches = found
      loading = false
      render()
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_get_cursor(win)[1] < 3 and vim.api.nvim_buf_line_count(buf) >= 3 then
          pcall(vim.api.nvim_win_set_cursor, win, { 3, 0 })
        end
      end
    end)
  end

  if existing_win and vim.api.nvim_win_is_valid(existing_win) then
    vim.api.nvim_set_current_win(existing_win)
    vim.api.nvim_win_set_buf(existing_win, buf)
  else
    vim.cmd(config.opts.window_cmd or "botright 15split")
    vim.api.nvim_win_set_buf(0, buf)
  end
  for _, old_b in ipairs(old_bufs) do
    if vim.api.nvim_buf_is_valid(old_b) then
      pcall(vim.api.nvim_buf_delete, old_b, { force = true })
    end
  end
  pcall(vim.api.nvim_buf_set_name, buf, buf_name)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if handle then
        handle.cancel()
      end
    end,
  })
  refresh()

  local function jump(how)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local target = line_targets[row]
    if not target then
      return
    end
    if
      how == "other"
      and origin_win ~= vim.api.nvim_get_current_win()
      and vim.api.nvim_win_is_valid(origin_win)
      and vim.api.nvim_win_get_config(origin_win).relative == ""
      and vim.bo[vim.api.nvim_win_get_buf(origin_win)].buftype == ""
    then
      vim.api.nvim_set_current_win(origin_win)
      utils.open_file(target.file, "edit")
    else
      utils.open_file(target.file, how)
    end
    local max_lnum = math.max(1, vim.api.nvim_buf_line_count(0))
    vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(target.lnum, max_lnum)), math.max(0, target.col - 1) })
  end

  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "denote: " .. desc })
  end
  map("<CR>", function()
    jump("other")
  end, "open backlink in other window")
  map("o", function()
    jump("other")
  end, "open backlink in other window")
  map("v", function()
    jump("vsplit")
  end, "open backlink in vsplit")
  map("s", function()
    jump("split")
  end, "open backlink in split")
  map("f", function()
    show_context = not show_context
    render()
  end, "toggle context / filenames-only")
  map("r", refresh, "refresh backlinks")
  map("g", refresh, "refresh backlinks")
  map("q", "<Cmd>bwipeout<CR>", "close backlinks")
  map("g?", function()
    require("denote.ui").show_help("Denote Backlinks", {
      { "<CR> / o", "Jump to backlink in other window" },
      { "v / s", "Open in vertical / horizontal split" },
      { "f", "Toggle matching context lines vs filenames-only" },
      { "r / g", "Refresh backlinks" },
      { "q", "Close backlinks window" },
    })
  end, "help")

  return buf
end

return M
