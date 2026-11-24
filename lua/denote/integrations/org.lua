---@mod denote.integrations.org Seamless integration with org.nvim (and standalone Org dynamic blocks)
---
--- When `xheisenbugx/org.nvim` is installed, automatically registers:
--- 1. The `denote:` custom link type (`links.types.denote`):
---    - `follow(path, link, arg)`: opens Denote notes by ID, heading (`::*Heading`),
---      custom ID (`::#custom-id`), or live query (`query-contents:`, `query-filenames:`).
---    - `store(interactive)`: `<leader>ols` / `C-c l` in any Denote file stores a
---      `denote:ID` link (or `denote:ID::#custom-id` when on an Org heading with `:CUSTOM_ID:`).
---    - `export(path, desc, backend, info)`: exports `denote:` links cleanly across
---      `org.nvim`'s HTML, Markdown/GFM, LaTeX/Beamer, ASCII, and Org exporters.
---    - `face = "DenoteLink"`: native link highlighting & concealment in `org.nvim`.
--- 2. Org dynamic blocks (matching `denote-org`):
---    - `denote-links` (`:regexp`, `:not-regexp`, `:excluded-dirs-regexp`, `:sort-by-component`, `:reverse-sort`, `:id-only`, `:include-date`)
---    - `denote-backlinks` (`:not-regexp`, `:excluded-dirs-regexp`, `:sort-by-component`, `:reverse-sort`, `:id-only`, `:include-date`)
---    - `denote-files` (`:regexp`, `:not-regexp`, `:excluded-dirs-regexp`, `:sort-by-component`, `:reverse-sort`, `:no-front-matter`, `:file-separator`, `:add-links`)
---
--- All dynamic block builders and insert/update commands also work standalone without `org.nvim`.

local backlinks = require("denote.backlinks")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")
local sort = require("denote.sort")
local utils = require("denote.utils")

local M = {}

local registered = false

--- Strip leading quote symbol from Emacs Lisp symbol values like `'title` -> `title`.
---@param v any
---@return string|nil
local function clean_sym(v)
  if type(v) ~= "string" then
    return nil
  end
  local s = vim.trim(v):gsub("^'", "")
  if s == "" or s == "nil" then
    return nil
  end
  return s
end

--- Render lines for `#+BEGIN: denote-links ... #+END:`.
---@param params table<string, any>
---@param ctx { bufnr: integer }
---@return string[]
function M.dblock_links(params, ctx)
  params = params or {}
  local regexp = type(params.regexp) == "string" and params.regexp or nil
  local not_regexp = type(params["not-regexp"]) == "string" and params["not-regexp"] or nil
  local excluded_dirs = type(params["excluded-dirs-regexp"]) == "string" and params["excluded-dirs-regexp"] or nil
  local sort_by = clean_sym(params["sort-by-component"]) or "identifier"
  local reverse = params["reverse-sort"] == true
  local id_only = params["id-only"] == true
  local include_date = params["include-date"] == true

  local cur_path = ctx and ctx.bufnr and utils.normalize(vim.api.nvim_buf_get_name(ctx.bufnr)) or ""
  local matched = files.list({
    denote_only = true,
    regexp = regexp,
    not_regexp = not_regexp,
    excluded_dirs_regexp = excluded_dirs,
  })
  matched = vim.tbl_filter(function(p)
    return utils.normalize(p) ~= cur_path
  end, matched)
  matched = sort.sort_files(matched, sort_by, reverse)

  local out = {}
  for _, path in ipairs(matched) do
    local id = naming.retrieve_identifier(path)
    if id then
      local desc = links.default_description(path)
      if include_date then
        local ts = naming.identifier_to_time(id)
        if ts then
          desc = tostring(os.date("%Y-%m-%d", ts)) .. "  " .. desc
        end
      end
      out[#out + 1] = "- " .. links.format_link(id, desc, { syntax = "org", id_only = id_only })
    end
  end
  return out
end

--- Render lines for `#+BEGIN: denote-backlinks ... #+END:`.
---@param params table<string, any>
---@param ctx { bufnr: integer }
---@return string[]
function M.dblock_backlinks(params, ctx)
  params = params or {}
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  local cur_path = utils.normalize(vim.api.nvim_buf_get_name(bufnr))
  local id = naming.retrieve_identifier(cur_path)
  if not id then
    return {}
  end

  local not_regexp = type(params["not-regexp"]) == "string" and params["not-regexp"] or nil
  local excluded_dirs = type(params["excluded-dirs-regexp"]) == "string" and params["excluded-dirs-regexp"] or nil
  local sort_by = clean_sym(params["sort-by-component"]) or "identifier"
  local reverse = params["reverse-sort"] == true
  local id_only = params["id-only"] == true
  local include_date = params["include-date"] == true

  local backlink_files = backlinks.files_for(id, {
    exclude_file = cur_path,
    not_regexp = not_regexp,
    excluded_dirs_regexp = excluded_dirs,
    sort_by = sort_by,
    reverse = reverse,
  })

  local out = {}
  for _, path in ipairs(backlink_files) do
    local bid = naming.retrieve_identifier(path)
    if bid then
      local desc = links.default_description(path)
      if include_date then
        local ts = naming.identifier_to_time(bid)
        if ts then
          desc = tostring(os.date("%Y-%m-%d", ts)) .. "  " .. desc
        end
      end
      out[#out + 1] = "- " .. links.format_link(bid, desc, { syntax = "org", id_only = id_only })
    end
  end
  return out
end

--- Render lines for `#+BEGIN: denote-files ... #+END:`.
---@param params table<string, any>
---@param ctx { bufnr: integer }
---@return string[]
function M.dblock_files(params, ctx)
  params = params or {}
  local regexp = type(params.regexp) == "string" and params.regexp or nil
  local not_regexp = type(params["not-regexp"]) == "string" and params["not-regexp"] or nil
  local excluded_dirs = type(params["excluded-dirs-regexp"]) == "string" and params["excluded-dirs-regexp"] or nil
  local sort_by = clean_sym(params["sort-by-component"]) or "identifier"
  local reverse = params["reverse-sort"] == true
  local no_fm = params["no-front-matter"] == true
  local add_links = params["add-links"] == true
  local sep = type(params["file-separator"]) == "string" and params["file-separator"] or "-----"

  local cur_path = ctx and ctx.bufnr and utils.normalize(vim.api.nvim_buf_get_name(ctx.bufnr)) or ""
  local matched = files.list({
    denote_only = true,
    text_only = true,
    regexp = regexp,
    not_regexp = not_regexp,
    excluded_dirs_regexp = excluded_dirs,
  })
  matched = vim.tbl_filter(function(p)
    return utils.normalize(p) ~= cur_path
  end, matched)
  matched = sort.sort_files(matched, sort_by, reverse)

  local out = {}
  for idx, path in ipairs(matched) do
    if idx > 1 and sep ~= "" then
      out[#out + 1] = ""
      out[#out + 1] = sep
      out[#out + 1] = ""
    end
    local id = naming.retrieve_identifier(path)
    if add_links and id then
      out[#out + 1] = "* " .. links.format_link(id, frontmatter.extract_title(path), { syntax = "org" })
    end
    local flines = utils.read_lines(path)
    if no_fm then
      local ft = frontmatter.detect_file_type(path, flines)
      flines = frontmatter.strip_front_matter(flines, ft)
    end
    for _, l in ipairs(flines) do
      out[#out + 1] = l
    end
  end
  return out
end

--- Export a `denote:` link for `org.nvim`'s export engine (`html`, `latex`, `beamer`, `markdown`, `gfm`, `ascii`, `org`).
---@param path string Link path after `denote:`
---@param desc string|nil
---@param backend_name string
---@param info table|nil
---@return string|nil
function M.export_link(path, desc, backend_name, info)
  local parsed = links.parse_target(path)
  if parsed.kind ~= "id" or not parsed.identifier then
    return desc or path
  end
  local target_file = files.find_by_id(parsed.identifier)
  local label = desc or (target_file and frontmatter.extract_title(target_file)) or parsed.identifier
  if not target_file then
    return label
  end

  local src_file = info and info.input_file
  local base_dir = src_file and vim.fn.fnamemodify(utils.normalize(src_file), ":h") or nil
  local rel = base_dir and utils.relpath(target_file, base_dir) or vim.fn.fnamemodify(target_file, ":t")
  local stem = naming.split_extension(rel)

  if backend_name == "html" then
    local href = stem .. ".html"
    if parsed.search and parsed.search:sub(1, 1) == "#" then
      href = href .. parsed.search
    end
    return string.format('<a href="%s">%s</a>', href, label)
  elseif backend_name == "markdown" or backend_name == "gfm" then
    return string.format("[%s](%s.md)", label, stem)
  elseif backend_name == "latex" or backend_name == "beamer" then
    return string.format("\\href{%s.pdf}{%s}", stem, label)
  elseif backend_name == "ascii" then
    return label
  elseif backend_name == "org" then
    return string.format("[[denote:%s][%s]]", path, label)
  end
  return label
end

--- Store a `denote:` link for `org.nvim`'s `<leader>ols` / `org-store-link`.
---@return { link: string, desc: string }|nil
function M.store_link()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local id = naming.retrieve_identifier(path)
  if not id then
    return nil
  end
  local title = frontmatter.extract_title(path)

  -- If cursor is on an Org heading with a :CUSTOM_ID:, link directly to that heading
  if vim.bo[bufnr].filetype == "org" then
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local headings = frontmatter.extract_headings(path)
    local cur_h = nil
    for _, h in ipairs(headings) do
      if h.lnum <= lnum then
        cur_h = h
      else
        break
      end
    end
    if cur_h and cur_h.custom_id then
      return {
        link = "denote:" .. id .. "::#" .. cur_h.custom_id,
        desc = title .. "::" .. cur_h.text,
      }
    end
  end

  return {
    link = "denote:" .. id,
    desc = title,
  }
end

--- Register `denote:` link type and dynamic blocks with `org.nvim` if installed.
--- Safe to call multiple times (idempotent).
---@return boolean attached True when `org.nvim` was found and hooked
function M.attach()
  local ok_cfg, org_config = pcall(require, "org.config")
  if not ok_cfg or type(org_config) ~= "table" or type(org_config.opts) ~= "table" then
    return false
  end

  org_config.opts.links = org_config.opts.links or {}
  org_config.opts.links.types = org_config.opts.links.types or {}
  org_config.opts.links.types.denote = {
    follow = function(path)
      return links.follow_target(path)
    end,
    store = M.store_link,
    export = M.export_link,
    complete = function()
      local out = {}
      for _, p in ipairs(files.list({ denote_only = true })) do
        local id = naming.retrieve_identifier(p)
        if id then
          out[#out + 1] = "denote:" .. id
        end
      end
      return out
    end,
    face = "DenoteLink",
  }

  local ok_dblock, dblock = pcall(require, "org.dblock")
  if ok_dblock and type(dblock.register) == "function" then
    dblock.register("denote-links", M.dblock_links)
    dblock.register("denote-backlinks", M.dblock_backlinks)
    dblock.register("denote-files", M.dblock_files)
  end

  registered = true
  return true
end

--- Return whether `org.nvim` integration is currently registered.
---@return boolean
function M.is_attached()
  return registered
end

--- Parse simple `:key value` dynamic block params (standalone fallback when org.nvim is not loaded).
---@param str string
---@return table<string, any>
local function parse_dblock_params(str)
  local ok_db, dblock = pcall(require, "org.dblock")
  if ok_db and type(dblock.parse_params) == "function" then
    return dblock.parse_params(str)
  end
  local params = {}
  local i, n = 1, #(str or "")
  while i <= n do
    local ks, ke, key = str:find("^%s*:([%w_%-]+)", i)
    if not ks then
      break
    end
    i = ke + 1
    local ws = str:sub(i):match("^(%s*)") or ""
    local j = i + #ws
    local c = str:sub(j, j)
    local val
    if c == '"' then
      local close = str:find('"', j + 1, true)
      if close then
        val = str:sub(j + 1, close - 1)
        i = close + 1
      else
        break
      end
    else
      local vs, ve = str:find("^[^%s]+", j)
      if vs then
        val = str:sub(vs, ve)
        i = ve + 1
        if val == "nil" then
          val = false
        elseif val == "t" then
          val = true
        end
      else
        val = true
      end
    end
    params[key:lower()] = val
  end
  return params
end

--- Update all `denote-*` Org dynamic blocks in `bufnr` (uses `org.dblock` if available,
--- otherwise updates directly in pure Lua).
---@param bufnr? integer
---@return integer updated_count
function M.update_dblocks(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local writers = {
    ["denote-links"] = M.dblock_links,
    ["denote-backlinks"] = M.dblock_backlinks,
    ["denote-files"] = M.dblock_files,
  }
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local i = 1
  while i <= #lines do
    local name, raw = lines[i]:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:%s+(%S+)%s*(.-)%s*$")
    if name and writers[name:lower()] then
      for j = i + 1, #lines do
        if lines[j]:match("^%s*#%+[Ee][Nn][Dd]:%s*$") then
          blocks[#blocks + 1] = { start_line = i, end_line = j, name = name:lower(), params = parse_dblock_params(raw) }
          i = j
          break
        end
      end
    end
    i = i + 1
  end

  -- Update bottom to top so line numbers stay valid
  for k = #blocks, 1, -1 do
    local b = blocks[k]
    local content = writers[b.name](b.params, { bufnr = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, b.start_line, b.end_line - 1, false, content or {})
  end
  return #blocks
end

--- Insert a `#+BEGIN: denote-links ... #+END:` block and populate it (`denote-org-dblock-insert-links`).
---@param regexp? string
function M.dblock_insert_links(regexp)
  local function insert(pat)
    local bufnr = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local header = string.format('#+BEGIN: denote-links :regexp "%s"', pat)
    vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { header, "#+END:" })
    M.update_dblocks(bufnr)
  end
  if regexp ~= nil then
    insert(regexp)
    return
  end
  vim.ui.input({ prompt = "Dynamic block regexp: " }, function(input)
    if input ~= nil then
      insert(vim.trim(input))
    end
  end)
end

--- Insert a `#+BEGIN: denote-backlinks #+END:` block and populate it (`denote-org-dblock-insert-backlinks`).
function M.dblock_insert_backlinks()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { "#+BEGIN: denote-backlinks", "#+END:" })
  M.update_dblocks(bufnr)
end

--- Insert a `#+BEGIN: denote-files ... #+END:` block and populate it (`denote-org-dblock-insert-files`).
---@param regexp? string
function M.dblock_insert_files(regexp)
  local function insert(pat)
    local bufnr = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local header = string.format('#+BEGIN: denote-files :regexp "%s" :no-front-matter t', pat)
    vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { header, "#+END:" })
    M.update_dblocks(bufnr)
  end
  if regexp ~= nil then
    insert(regexp)
    return
  end
  vim.ui.input({ prompt = "Dynamic block files regexp: " }, function(input)
    if input ~= nil then
      insert(vim.trim(input))
    end
  end)
end

return M
