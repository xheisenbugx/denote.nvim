---@mod denote.query Full-text grep and Denote 4.0 query links
---@brief [[
--- Implements:
--- - `grep(query, opts)`: fast full-text search across Denote notes (uses `rg` if installed,
---   with pure-Lua fallback so it works with zero external binaries).
--- - Interactive `*Denote query*` buffer matching Emacs `denote-query-mode`:
---   `<CR>` jump, `o` other window, `f` narrow/filter, `x` exclude matches, `c` clear filters,
---   `r` refresh, `q` close.
--- - `query_contents_link` (`denote-query-contents-link`): inserts `denote:query-contents:...`
--- - `query_filenames_link` (`denote-query-filenames-link`): inserts `denote:query-filenames:...`
---@brief ]]

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")
local pickers = require("denote.pickers")
local sort = require("denote.sort")
local utils = require("denote.utils")

local M = {}

---@class denote.GrepMatch
---@field file string
---@field lnum integer
---@field col integer
---@field text string

--- Search contents of Denote text files in `dir` (or explicit `opts.files`) matching `query`.
--- Uses `rg` when available with a pure-Lua fallback so it works with zero external binaries
--- (see `denote.search`). Pass `on_done` to search asynchronously.
---@param query string
---@param opts? { dir?: string, files?: string[], file_regexp?: string, case_sensitive?: boolean, fixed?: boolean }
---@param on_done? fun(matches: denote.GrepMatch[])
---@return denote.GrepMatch[]|denote.SearchHandle
function M.search_contents(query, opts, on_done)
  opts = opts or {}
  local root = config.directory(opts.dir)
  local candidates = opts.files
    or files.list({
      dir = root,
      denote_only = true,
      text_only = true,
      regexp = opts.file_regexp,
    })
  return require("denote.search").run({
    pattern = query or "",
    files = candidates,
    root = not opts.files and root or nil,
    fixed = opts.fixed,
    case = opts.case_sensitive and "sensitive" or "smart",
  }, on_done)
end

local ns = vim.api.nvim_create_namespace("denote_query")

--- Open the interactive Denote grep / query results buffer (`denote-grep`).
--- Supports all Denote 4.3.1 query refinement commands:
---   f: include files matching regexp (`denote-query-only-include-files`)
---   x: exclude files matching regexp (`denote-query-exclude-files`)
---   k: include files with keyword(s) (`denote-query-only-include-files-with-keywords`)
---   K: exclude files with keyword(s) (`denote-query-exclude-files-with-keywords`)
---   /: focus search — grep new query only in currently matched files (`denote-query-focus-last-search`)
---   S: sort matched files by component (`denote-query-sort-last-search`)
---   c: clear all filters (`denote-query-clear-all-filters`)
---@param query? string
---@param opts? { dir?: string, files?: string[], file_regexp?: string }
function M.grep(query, opts)
  opts = opts or {}
  local origin_win = vim.api.nvim_get_current_win()
  local function open_results(q)
    if not q or vim.trim(q) == "" then
      return
    end
    require("denote.ui").ensure_highlights()
    local current_query = vim.trim(q)
    local root = config.directory(opts.dir)
    local scoped_files = opts.files
    local all_matches = {}
    local loading = true
    local handle = nil
    local include_filters = {}
    local exclude_filters = {}
    local include_keywords = {}
    local exclude_keywords = {}
    local sort_by = nil
    local reverse_sort = false
    local line_targets = {}

    local buf_name = "denote://query/" .. current_query
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
    vim.bo[buf].filetype = "denote-query"

    local function filtered_matches()
      local out = {}
      local need_kw = #include_keywords > 0 or #exclude_keywords > 0
      local root_prefix = root .. "/"
      for _, m in ipairs(all_matches) do
        local keep = true
        local rel = m.file:sub(1, #root_prefix) == root_prefix and m.file:sub(#root_prefix + 1)
          or utils.relpath(m.file, root)
        local hay = rel .. " " .. m.text
        local parsed = need_kw and naming.parse_filename(m.file) or nil
        for _, f in ipairs(include_filters) do
          if not utils.matches_pattern(hay, f) then
            keep = false
            break
          end
        end
        if keep then
          for _, ex in ipairs(exclude_filters) do
            if utils.matches_pattern(hay, ex) then
              keep = false
              break
            end
          end
        end
        if keep and parsed and #include_keywords > 0 then
          for _, kw in ipairs(include_keywords) do
            if not vim.tbl_contains(parsed.keywords or {}, kw) then
              keep = false
              break
            end
          end
        end
        if keep and parsed and #exclude_keywords > 0 then
          for _, kw in ipairs(exclude_keywords) do
            if vim.tbl_contains(parsed.keywords or {}, kw) then
              keep = false
              break
            end
          end
        end
        if keep then
          out[#out + 1] = m
        end
      end
      return out
    end

    local function current_file_list()
      local seen, out = {}, {}
      for _, m in ipairs(filtered_matches()) do
        if not seen[m.file] then
          seen[m.file] = true
          out[#out + 1] = m.file
        end
      end
      return out
    end

    local function render()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.b[buf].denote_loading = loading
      if loading then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
          string.format("Denote Query: %q  (searching…)", current_query),
          string.rep("─", 60),
        })
        vim.bo[buf].modifiable = false
        return
      end
      local shown = filtered_matches()
      line_targets = {}
      local lines, hls = {}, {}

      local filter_info = ""
      if #include_filters > 0 then
        filter_info = filter_info .. "  +[" .. table.concat(include_filters, ", ") .. "]"
      end
      if #exclude_filters > 0 then
        filter_info = filter_info .. "  -[" .. table.concat(exclude_filters, ", ") .. "]"
      end
      if #include_keywords > 0 then
        filter_info = filter_info .. "  +kw:[" .. table.concat(include_keywords, ",") .. "]"
      end
      if #exclude_keywords > 0 then
        filter_info = filter_info .. "  -kw:[" .. table.concat(exclude_keywords, ",") .. "]"
      end
      if sort_by then
        filter_info = filter_info .. "  sort:" .. sort_by .. (reverse_sort and "↓" or "↑")
      end

      lines[1] = string.format(
        "Denote Query: %q  [%d match%s]%s  (g? help)",
        current_query,
        #shown,
        #shown == 1 and "" or "es",
        filter_info
      )
      hls[#hls + 1] = { 0, 0, -1, "DenoteBacklinksHeader" }
      lines[2] = string.rep("─", 60)
      hls[#hls + 1] = { 1, 0, -1, "DenoteDelimiter" }

      if #shown == 0 then
        lines[3] = "  (no matches)"
        hls[#hls + 1] = { 2, 0, -1, "Comment" }
      else
        local order, grouped = {}, {}
        for _, m in ipairs(shown) do
          if not grouped[m.file] then
            grouped[m.file] = {}
            order[#order + 1] = m.file
          end
          grouped[m.file][#grouped[m.file] + 1] = m
        end
        if sort_by then
          order = sort.sort_files(order, sort_by, reverse_sort)
        end

        for _, f in ipairs(order) do
          local parsed = naming.parse_filename(f)
          local title = frontmatter.extract_title(f)
          local row = #lines + 1
          local id_str = parsed.identifier or ""
          lines[row] = string.format("%s  %s", id_str, title)
          line_targets[row] = { file = f, lnum = grouped[f][1].lnum, col = grouped[f][1].col }
          hls[#hls + 1] = { row - 1, 0, #id_str, "DenoteIdentifier" }
          hls[#hls + 1] = { row - 1, #id_str + 2, -1, "DenoteBacklinksFile" }

          for _, m in ipairs(grouped[f]) do
            local mrow = #lines + 1
            local prefix = string.format("  %4d: ", m.lnum)
            lines[mrow] = prefix .. m.text
            line_targets[mrow] = { file = f, lnum = m.lnum, col = m.col }
            hls[#hls + 1] = { mrow - 1, 0, #prefix, "DenoteBacklinksLineNr" }
            hls[#hls + 1] = { mrow - 1, #prefix, -1, "DenoteBacklinksMatch" }
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

    --- (Re)run the search asynchronously and re-render when results arrive.
    ---@param search_opts table
    local function refresh(search_opts)
      if handle then
        handle.cancel()
      end
      loading = true
      render()
      handle = M.search_contents(current_query, search_opts, function(matches)
        handle = nil
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        all_matches = matches
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
    refresh(opts)

    local function jump(how)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local t = line_targets[row]
      if not t then
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
        utils.open_file(t.file, "edit")
      else
        utils.open_file(t.file, how)
      end
      local max_lnum = math.max(1, vim.api.nvim_buf_line_count(0))
      vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(t.lnum, max_lnum)), math.max(0, t.col - 1) })
    end

    local map = function(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "denote: " .. desc })
    end
    map("<CR>", function()
      jump("other")
    end, "jump to match")
    map("o", function()
      jump("other")
    end, "jump to match")
    map("v", function()
      jump("vsplit")
    end, "open match in vsplit")
    map("s", function()
      jump("split")
    end, "open match in split")
    map("f", function()
      vim.ui.input({ prompt = "Keep matches matching: " }, function(pat)
        if pat and vim.trim(pat) ~= "" then
          include_filters[#include_filters + 1] = vim.trim(pat)
          render()
        end
      end)
    end, "keep matching lines")
    map("x", function()
      vim.ui.input({ prompt = "Exclude matches matching: " }, function(pat)
        if pat and vim.trim(pat) ~= "" then
          exclude_filters[#exclude_filters + 1] = vim.trim(pat)
          render()
        end
      end)
    end, "exclude matching lines")
    map("k", function()
      vim.ui.input({ prompt = "Only include files with keywords: " }, function(input)
        if input and vim.trim(input) ~= "" then
          for _, kw in ipairs(naming.sluggify_keywords(input)) do
            include_keywords[#include_keywords + 1] = kw
          end
          render()
        end
      end)
    end, "only include files with keywords")
    map("K", function()
      vim.ui.input({ prompt = "Exclude files with keywords: " }, function(input)
        if input and vim.trim(input) ~= "" then
          for _, kw in ipairs(naming.sluggify_keywords(input)) do
            exclude_keywords[#exclude_keywords + 1] = kw
          end
          render()
        end
      end)
    end, "exclude files with keywords")
    map("/", function()
      local matched_files = current_file_list()
      if #matched_files == 0 then
        utils.notify("No files in current query to focus on")
        return
      end
      vim.ui.input({ prompt = string.format("Focus search in %d matched file(s): ", #matched_files) }, function(nq)
        if nq and vim.trim(nq) ~= "" then
          current_query = vim.trim(nq)
          scoped_files = matched_files
          include_filters, exclude_filters, include_keywords, exclude_keywords = {}, {}, {}, {}
          refresh({ dir = opts.dir, files = scoped_files })
        end
      end)
    end, "focus search in matched files")
    map("S", function()
      local items = {}
      for _, comp in ipairs(sort.COMPONENTS) do
        items[#items + 1] = { display = { { comp, "DenoteTitle" } }, text = comp, value = comp }
      end
      pickers.pick({
        title = "Sort Query Results By",
        items = items,
        preview = false,
        on_choice = function(chosen)
          if chosen[1] then
            sort_by = chosen[1].value
            reverse_sort = (sort_by == "identifier" or sort_by == "last-modified")
            render()
          end
        end,
      })
    end, "sort matched files")
    map("c", function()
      include_filters = {}
      exclude_filters = {}
      include_keywords = {}
      exclude_keywords = {}
      scoped_files = opts.files
      refresh(opts)
    end, "clear all filters")
    map("r", function()
      refresh({
        dir = opts.dir,
        files = scoped_files,
        file_regexp = opts.file_regexp,
      })
    end, "refresh results")
    map("q", "<Cmd>bwipeout<CR>", "close query results")
    map("g?", function()
      require("denote.ui").show_help("Denote Query Results", {
        { "<CR> / o", "Jump to match in other window" },
        { "v / s", "Open in vertical / horizontal split" },
        { "f / x", "Include / exclude matches by regexp" },
        { "k / K", "Include / exclude files by keyword" },
        { "/", "Focus search: new grep within matched files" },
        { "S", "Sort matched files by component" },
        { "c", "Clear all active filters" },
        { "r / q", "Refresh / close query buffer" },
      })
    end, "help")

    return buf
  end

  if query ~= nil then
    return open_results(query)
  end

  vim.ui.input({ prompt = "Denote grep: " }, function(input)
    if input and vim.trim(input) ~= "" then
      open_results(input)
    end
  end)
end

--- Search `query` only inside Denote files referenced between `line1` and `line2`
--- (`denote-grep-files-referenced-in-region`).
---@param query? string
---@param opts? { line1?: integer, line2?: integer, bufnr?: integer }
function M.grep_files_referenced_in_region(query, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line1 = opts.line1 or vim.fn.line("'<")
  local line2 = opts.line2 or vim.fn.line("'>")
  if line1 > line2 then
    line1, line2 = line2, line1
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, math.max(0, line1 - 1), line2, false)
  local seen, ref_files = {}, {}
  for _, line in ipairs(lines) do
    for id in line:gmatch(naming.ID_PATTERN) do
      if not seen[id] then
        seen[id] = true
        local path = files.find_by_id(id)
        if path then
          ref_files[#ref_files + 1] = path
        end
      end
    end
  end
  if #ref_files == 0 then
    utils.notify("No Denote identifiers referenced in selected region")
    return nil
  end
  return M.grep(query, { files = ref_files })
end

--- Insert a `query-contents` link at cursor (`denote-query-contents-link`).
---@param query? string
---@param description? string
function M.query_contents_link(query, description)
  local bufnr = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  local origin_pos = vim.api.nvim_win_get_cursor(origin_win)
  local syntax = links.buffer_syntax(bufnr)
  local function insert(q, desc)
    local text = links.format_link("query-contents:" .. q, desc or q, { syntax = syntax })
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
      pcall(vim.api.nvim_win_set_cursor, origin_win, origin_pos)
    end
    links.insert_text(text, bufnr)
  end

  if query then
    insert(query, description)
    return
  end
  vim.ui.input({ prompt = "Query contents regexp: " }, function(q)
    if not q or vim.trim(q) == "" then
      return
    end
    vim.ui.input({ prompt = "Link description: ", default = q }, function(desc)
      if desc ~= nil then
        insert(vim.trim(q), desc ~= "" and desc or vim.trim(q))
      end
    end)
  end)
end

--- Insert a `query-filenames` link at cursor (`denote-query-filenames-link`).
---@param query? string
---@param description? string
function M.query_filenames_link(query, description)
  local bufnr = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  local origin_pos = vim.api.nvim_win_get_cursor(origin_win)
  local syntax = links.buffer_syntax(bufnr)
  local function insert(q, desc)
    local text = links.format_link("query-filenames:" .. q, desc or q, { syntax = syntax })
    if vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
      pcall(vim.api.nvim_win_set_cursor, origin_win, origin_pos)
    end
    links.insert_text(text, bufnr)
  end

  if query then
    insert(query, description)
    return
  end
  vim.ui.input({ prompt = "Query filenames regexp: " }, function(q)
    if not q or vim.trim(q) == "" then
      return
    end
    vim.ui.input({ prompt = "Link description: ", default = q }, function(desc)
      if desc ~= nil then
        insert(vim.trim(q), desc ~= "" and desc or vim.trim(q))
      end
    end)
  end)
end

return M
