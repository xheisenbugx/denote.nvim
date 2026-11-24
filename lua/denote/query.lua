---@mod denote.query Full-text grep and Denote 4.0 query links
---
--- Implements:
--- - `grep(query, opts)`: fast full-text search across Denote notes (uses `rg` if installed,
---   with pure-Lua fallback so it works with zero external binaries).
--- - Interactive `*Denote query*` buffer matching Emacs `denote-query-mode`:
---   `<CR>` jump, `o` other window, `f` narrow/filter, `x` exclude matches, `c` clear filters,
---   `r` refresh, `q` close.
--- - `query_contents_link` (`denote-query-contents-link`): inserts `denote:query-contents:...`
--- - `query_filenames_link` (`denote-query-filenames-link`): inserts `denote:query-filenames:...`

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

---@class denote.GrepMatch
---@field file string
---@field lnum integer
---@field col integer
---@field text string

--- Search contents of Denote text files in `dir` matching `query`.
--- Uses pure Lua (or `rg` when available and no custom Lua-only options are needed).
---@param query string
---@param opts? { dir?: string, file_regexp?: string, case_sensitive?: boolean }
---@return denote.GrepMatch[]
function M.search_contents(query, opts)
  opts = opts or {}
  if not query or query == "" then
    return {}
  end
  local root = config.directory(opts.dir)
  local candidates = files.list({
    dir = root,
    denote_only = true,
    text_only = true,
    regexp = opts.file_regexp,
  })
  if #candidates == 0 then
    return {}
  end

  local matches = {}

  -- Fast path with ripgrep when available and searching all notes in root
  if not opts.file_regexp and vim.fn.executable("rg") == 1 then
    local cmd = {
      "rg",
      "--vimgrep",
      "--no-heading",
      "--color=never",
      opts.case_sensitive and "--case-sensitive" or "--smart-case",
      "--",
      query,
      root,
    }
    local res = vim.system(cmd, { text = true }):wait()
    if res.code == 0 and res.stdout then
      local allowed = {}
      for _, p in ipairs(candidates) do
        allowed[utils.normalize(p)] = true
      end
      local seen_line = {}
      for line in res.stdout:gmatch("[^\r\n]+") do
        local fpath, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
        if fpath then
          local norm = utils.normalize(fpath)
          local key = norm .. ":" .. lnum
          if allowed[norm] and not seen_line[key] then
            seen_line[key] = true
            matches[#matches + 1] = {
              file = norm,
              lnum = tonumber(lnum) or 1,
              col = tonumber(col) or 1,
              text = vim.trim(text),
            }
          end
        end
      end
      return matches
    end
  end

  -- Pure-Lua fallback (zero external dependencies)
  for _, path in ipairs(candidates) do
    local lines = utils.read_lines(path)
    for lnum, line in ipairs(lines) do
      local matched = false
      local col = 1
      if opts.case_sensitive then
        local s = line:find(query, 1, true)
        if s then
          matched, col = true, s
        end
      else
        local ok_m, idx = pcall(vim.fn.match, line, query)
        if ok_m and idx >= 0 then
          matched, col = true, idx + 1
        else
          local s = line:lower():find(query:lower(), 1, true)
          if s then
            matched, col = true, s
          end
        end
      end
      if matched then
        matches[#matches + 1] = {
          file = path,
          lnum = lnum,
          col = col,
          text = vim.trim(line),
        }
      end
    end
  end

  return matches
end

local ns = vim.api.nvim_create_namespace("denote_query")

--- Open the interactive Denote grep / query results buffer (`denote-grep`).
---@param query? string
---@param opts? { dir?: string, file_regexp?: string }
function M.grep(query, opts)
  opts = opts or {}
  local function open_results(q)
    if not q or vim.trim(q) == "" then
      return
    end
    q = vim.trim(q)
    local all_matches = M.search_contents(q, opts)
    local include_filters = {}
    local exclude_filters = {}
    local line_targets = {}

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "denote-query"
    pcall(vim.api.nvim_buf_set_name, buf, "denote://query/" .. q)

    local function filtered_matches()
      local out = {}
      for _, m in ipairs(all_matches) do
        local keep = true
        local hay = m.file .. " " .. m.text
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
        if keep then
          out[#out + 1] = m
        end
      end
      return out
    end

    local function render()
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

      lines[1] =
        string.format("Denote Query: %q  [%d match%s]%s  (g? help)", q, #shown, #shown == 1 and "" or "es", filter_info)
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
      local t = line_targets[row]
      if not t then
        return
      end
      utils.open_file(t.file, how)
      vim.api.nvim_win_set_cursor(0, { t.lnum, math.max(0, t.col - 1) })
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
    map("c", function()
      include_filters = {}
      exclude_filters = {}
      render()
    end, "clear filters")
    map("r", function()
      all_matches = M.search_contents(q, opts)
      render()
    end, "refresh results")
    map("q", "<Cmd>bwipeout<CR>", "close query results")
    map("g?", function()
      require("denote.ui").show_help("Denote Query Results", {
        { "<CR> / o", "Jump to match in other window" },
        { "v / s", "Open in vertical / horizontal split" },
        { "f", "Filter (keep matches matching pattern)" },
        { "x", "Exclude matches matching pattern" },
        { "c", "Clear all active filters" },
        { "r", "Re-run search" },
        { "q", "Close query buffer" },
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

--- Insert a `query-contents` link at cursor (`denote-query-contents-link`).
---@param query? string
---@param description? string
function M.query_contents_link(query, description)
  local bufnr = vim.api.nvim_get_current_buf()
  local syntax = links.buffer_syntax(bufnr)
  local function insert(q, desc)
    local text = links.format_link("query-contents:" .. q, desc or q, { syntax = syntax })
    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col = pos[1] - 1, pos[2]
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local ins = math.min(col, #line)
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { line:sub(1, ins) .. text .. line:sub(ins + 1) })
    vim.api.nvim_win_set_cursor(0, { row + 1, ins + #text })
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
  local syntax = links.buffer_syntax(bufnr)
  local function insert(q, desc)
    local text = links.format_link("query-filenames:" .. q, desc or q, { syntax = syntax })
    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col = pos[1] - 1, pos[2]
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local ins = math.min(col, #line)
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { line:sub(1, ins) .. text .. line:sub(ins + 1) })
    vim.api.nvim_win_set_cursor(0, { row + 1, ins + #text })
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
