---@mod denote.backlinks Backlinks discovery and interactive backlinks buffer
---
--- Mirrors Emacs `denote-backlinks` and `denote-find-backlink`:
--- - Finds every note in the Denote directory referencing the current note's identifier.
--- - Works with zero external dependencies (pure Lua scanner) and accelerates with `rg` when available.
--- - Opens an interactive split buffer showing file headers + matching context lines
---   with `<CR>` to jump, `o` other window, `f` toggle context/filenames-only, `r` refresh, `q` close.

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

--- Collect all backlinks referencing `identifier` across `dir` (excluding `exclude_file`).
---@param identifier string
---@param opts? { dir?: string, exclude_file?: string, not_regexp?: string, excluded_dirs_regexp?: string }
---@return denote.BacklinkMatch[]
function M.find(identifier, opts)
  opts = opts or {}
  if not identifier or identifier == "" then
    return {}
  end
  local root = config.directory(opts.dir)
  local exclude = opts.exclude_file and utils.normalize(opts.exclude_file) or nil
  local candidates = files.list({
    dir = root,
    denote_only = true,
    text_only = true,
    not_regexp = opts.not_regexp,
    excluded_dirs_regexp = opts.excluded_dirs_regexp,
  })

  local matches = {}
  local id_escaped = utils.escape_lua_pattern(identifier)
  -- Match either `denote:ID` or a direct reference to ID in the body (skipping front matter identifier line)
  for _, path in ipairs(candidates) do
    if utils.normalize(path) ~= exclude then
      local bufnr = utils.find_buffer(path)
      local lines = (bufnr and vim.api.nvim_buf_is_loaded(bufnr)) and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        or utils.read_lines(path)
      local ft = frontmatter.detect_file_type(path, lines)
      local fm = ft and frontmatter.parse_lines(lines, ft) or nil
      local fm_end = (fm and fm.has_front_matter) and fm.end_line or 0

      for lnum = fm_end + 1, #lines do
        local line = lines[lnum]
        local col = line:find(id_escaped)
        if col then
          matches[#matches + 1] = {
            file = path,
            lnum = lnum,
            col = col,
            text = vim.trim(line),
          }
        end
      end
    end
  end

  return matches
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

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "denote-backlinks"
  pcall(vim.api.nvim_buf_set_name, buf, "denote://backlinks/" .. id)

  local line_targets = {}

  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local matches = M.find(id, { dir = opts.dir, exclude_file = target_file })
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
      local unique_files = M.files_for(id, { dir = opts.dir, exclude_file = target_file })
      for _, f in ipairs(unique_files) do
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
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, h[4], h[1], h[2], h[3])
    end
  end

  vim.cmd(config.opts.window_cmd or "botright 15split")
  vim.api.nvim_win_set_buf(0, buf)
  render()
  if vim.api.nvim_buf_line_count(buf) >= 3 then
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
  end

  local function jump(how)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local target = line_targets[row]
    if not target then
      return
    end
    utils.open_file(target.file, how)
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
  map("r", render, "refresh backlinks")
  map("g", render, "refresh backlinks")
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
