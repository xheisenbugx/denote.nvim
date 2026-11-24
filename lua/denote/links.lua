---@mod denote.links Creating, parsing, following, finding, and converting Denote links
---
--- Full syntax support for:
--- - Org mode:      `[[denote:ID][Description]]`, `[[denote:ID]]`,
---                  `[[denote:ID::*Heading][Description]]`, `[[denote:ID::#custom-id][Description]]`,
---                  `[[denote:query-contents:QUERY][Description]]`, `[[denote:query-filenames:QUERY][Description]]`
--- - Markdown:      `[Description](denote:ID)`, `[Description](denote:ID::#heading-slug)`,
---                  `[[denote:ID|Description]]`, `[[denote:ID]]`,
---                  `[Description](denote:query-contents:QUERY)`, `[Description](denote:query-filenames:QUERY)`
--- - Plain text:    `[[denote:ID][Description]]`, `denote:ID`

local config = require("denote.config")
local create = require("denote.create")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local pickers = require("denote.pickers")
local sort = require("denote.sort")
local utils = require("denote.utils")

local M = {}

---@class denote.Link
---@field kind "id"|"query-contents"|"query-filenames"
---@field target string Raw target after `denote:` (e.g. `20261123T191500` or `20261123T191500::*Heading`)
---@field identifier? string 15-char Denote identifier (when kind == "id")
---@field search? string Optional search suffix after `::` (e.g. `*Heading`, `#custom-id`, `/regex/`)
---@field query? string Search query (when kind is query-contents or query-filenames)
---@field description? string Link display text
---@field syntax "org"|"markdown"|"wiki"|"plain"
---@field start_col integer 1-based inclusive column
---@field end_col integer 1-based inclusive column
---@field lnum? integer 1-based line number
---@field raw string Full matched link string

--- Determine the link syntax to use for a buffer or file path.
---@param bufnr? integer
---@return "org"|"markdown"|"text"
function M.buffer_syntax(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  if ft == "org" then
    return "org"
  elseif ft == "markdown" or ft == "md" or ft == "mdx" then
    return "markdown"
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    local dft = frontmatter.detect_file_type(name)
    if dft == "org" then
      return "org"
    elseif dft == "markdown-yaml" or dft == "markdown-toml" then
      return "markdown"
    end
  end
  local def = config.opts.file_type or "markdown-yaml"
  if def == "org" then
    return "org"
  elseif def == "markdown-yaml" or def == "markdown-toml" then
    return "markdown"
  end
  return "text"
end

--- Compute default description text for a Denote file.
---@param path string
---@return string
function M.default_description(path)
  if type(config.opts.link_description_function) == "function" then
    local parsed = naming.parse_filename(path)
    local res = config.opts.link_description_function(path, parsed)
    if res and res ~= "" then
      return res
    end
  end
  local parsed = naming.parse_filename(path)
  local title = frontmatter.extract_title(path)
  if parsed.signature and parsed.signature ~= "" then
    return parsed.signature .. "  " .. title
  end
  return title
end

--- Format a Denote link string for `syntax` ("org", "markdown", "text").
---@param target string Target after `denote:` (e.g. "20261123T191500" or "20261123T191500::#sec")
---@param description? string
---@param opts? { syntax?: "org"|"markdown"|"text", id_only?: boolean, file_path?: string, from_dir?: string }
---@return string
function M.format_link(target, description, opts)
  opts = opts or {}
  local syntax = opts.syntax or M.buffer_syntax()
  local id_only = opts.id_only == true
  local desc = description or target

  if syntax == "org" then
    if id_only or not description or description == "" then
      return string.format("[[denote:%s]]", target)
    end
    return string.format("[[denote:%s][%s]]", target, desc)
  elseif syntax == "markdown" then
    local style = config.opts.markdown_link_style or "denote"
    if id_only then
      if style == "wiki" then
        return string.format("[[denote:%s]]", target)
      end
      return string.format("[%s](denote:%s)", target, target)
    end
    if style == "wiki" then
      return string.format("[[denote:%s|%s]]", target, desc)
    elseif style == "relative" and opts.file_path then
      local from_dir = opts.from_dir or config.directory()
      local rel = utils.relpath(opts.file_path, from_dir)
      return string.format("[%s](%s)", desc, rel)
    end
    return string.format("[%s](denote:%s)", desc, target)
  else
    -- Plain text follows Denote's org-style bracket syntax
    if id_only or not description or description == "" then
      return string.format("[[denote:%s]]", target)
    end
    return string.format("[[denote:%s][%s]]", target, desc)
  end
end

--- Classify a raw `denote:` target string into `{ kind, identifier, search, query }`.
---@param target string
---@return { kind: "id"|"query-contents"|"query-filenames", identifier?: string, search?: string, query?: string }
function M.parse_target(target)
  local qc = target:match("^query%-contents:(.*)$")
  if qc then
    return { kind = "query-contents", query = qc }
  end
  local qf = target:match("^query%-filenames:(.*)$")
  if qf then
    return { kind = "query-filenames", query = qf }
  end
  local id, search = target:match("^(" .. naming.ID_PATTERN .. ")::(.*)$")
  if id then
    return { kind = "id", identifier = id, search = search }
  end
  local plain_id = target:match("^(" .. naming.ID_PATTERN .. ")$")
  if plain_id then
    return { kind = "id", identifier = plain_id }
  end
  -- Fallback: treat non-ID denote: target as a query-contents search (Denote 4.0 shorthand)
  return { kind = "query-contents", query = target }
end

--- Parse all Denote links on a single line.
---@param line string
---@param lnum? integer
---@return denote.Link[]
function M.parse_line(line, lnum)
  local links = {}
  local occupied = {}

  local function is_occupied(s, e)
    for _, span in ipairs(occupied) do
      if not (e < span[1] or s > span[2]) then
        return true
      end
    end
    return false
  end

  local function add(s, e, raw, target, desc, syntax)
    if is_occupied(s, e) then
      return
    end
    occupied[#occupied + 1] = { s, e }
    local info = M.parse_target(target)
    links[#links + 1] = {
      kind = info.kind,
      target = target,
      identifier = info.identifier,
      search = info.search,
      query = info.query,
      description = desc,
      syntax = syntax,
      start_col = s,
      end_col = e,
      lnum = lnum,
      raw = raw,
    }
  end

  -- 1. Org bracket link with description: [[denote:TARGET][DESC]]
  local init = 1
  while true do
    local s, e, target, desc = line:find("%[%[denote:([^%]]+)%]%[([^%]]*)%]%]", init)
    if not s then
      break
    end
    add(s, e, line:sub(s, e), target, desc, "org")
    init = e + 1
  end

  -- 2. Wikilink with pipe description: [[denote:TARGET|DESC]]
  init = 1
  while true do
    local s, e, target, desc = line:find("%[%[denote:([^%]|]+)|([^%]]*)%]%]", init)
    if not s then
      break
    end
    add(s, e, line:sub(s, e), target, desc, "wiki")
    init = e + 1
  end

  -- 3. Org/Wiki bare bracket link: [[denote:TARGET]]
  init = 1
  while true do
    local s, e, target = line:find("%[%[denote:([^%]]+)%]%]", init)
    if not s then
      break
    end
    add(s, e, line:sub(s, e), target, nil, "org")
    init = e + 1
  end

  -- 4. Markdown link: [DESC](denote:TARGET)
  init = 1
  while true do
    local s, e, desc, target = line:find("%[([^%]]*)%]%(denote:([^%)]+)%)", init)
    if not s then
      break
    end
    add(s, e, line:sub(s, e), target, desc, "markdown")
    init = e + 1
  end

  -- 5. Plain bare link: denote:ID or denote:ID::search
  init = 1
  while true do
    local s, e, target = line:find("denote:([^%s%[%]%(%)<>\"']+)", init)
    if not s then
      break
    end
    add(s, e, line:sub(s, e), target, nil, "plain")
    init = e + 1
  end

  table.sort(links, function(a, b)
    return a.start_col < b.start_col
  end)
  return links
end

--- Find the Denote link under the cursor (or at `lnum`, 1-based `col`), or nil.
---@param bufnr? integer
---@param lnum? integer
---@param col? integer 1-based column
---@return denote.Link|nil
function M.link_at_cursor(bufnr, lnum, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not lnum or not col then
    local pos = vim.api.nvim_win_get_cursor(0)
    lnum = lnum or pos[1]
    col = col or (pos[2] + 1)
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  for _, link in ipairs(M.parse_line(line, lnum)) do
    if col >= link.start_col and col <= link.end_col then
      return link
    end
  end
  return nil
end

--- Collect all Denote links in a buffer.
---@param bufnr? integer
---@return denote.Link[]
function M.links_in_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all = {}
  for lnum, line in ipairs(lines) do
    if line:find("denote:", 1, true) then
      for _, link in ipairs(M.parse_line(line, lnum)) do
        all[#all + 1] = link
      end
    end
  end
  return all
end

--- Insert `text` at the cursor position in `bufnr` (replacing visual selection if active).
---@param text string
---@param bufnr? integer
local function insert_at_cursor(text, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local insert_col = math.min(col, #line)
  local new_line = line:sub(1, insert_col) .. text .. line:sub(insert_col + 1)
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })
  vim.api.nvim_win_set_cursor(0, { row + 1, insert_col + #text })
end

--- Jump to a search target (`*Heading`, `#custom-id`, `#heading-slug`, `/regex/`, line number)
--- inside the currently open buffer.
---@param search string
---@return boolean
function M.jump_to_search(search)
  if not search or search == "" then
    return true
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- 1. Line number
  local num = tonumber(search)
  if num and num >= 1 and num <= #lines then
    vim.api.nvim_win_set_cursor(0, { num, 0 })
    return true
  end

  -- 2. Custom ID or Markdown heading slug: `#foo`
  local hash_target = search:match("^#(.+)$")
  if hash_target then
    local headings = frontmatter.extract_headings(path)
    local target_slug = naming.sluggify_title(hash_target)
    for _, h in ipairs(headings) do
      if (h.custom_id and h.custom_id == hash_target) or h.slug == hash_target or h.slug == target_slug then
        vim.api.nvim_win_set_cursor(0, { h.lnum, 0 })
        return true
      end
    end
  end

  -- 3. Heading title: `*Heading`
  local heading_target = search:match("^%*(.+)$")
  if heading_target then
    local headings = frontmatter.extract_headings(path)
    local want = vim.trim(heading_target):lower()
    for _, h in ipairs(headings) do
      if h.text:lower() == want then
        vim.api.nvim_win_set_cursor(0, { h.lnum, 0 })
        return true
      end
    end
  end

  -- 4. Regex or plain text search: `/pattern/` or `pattern`
  local pat = search:match("^/(.*)/$") or search
  for i, line in ipairs(lines) do
    if utils.matches_pattern(line, pat) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return true
    end
  end

  utils.warn("Search target not found in note: " .. search)
  return false
end

--- Follow a Denote target string (the part after `denote:`).
--- Works for direct IDs, IDs with `::search`, `query-contents:...`, and `query-filenames:...`.
---@param target string
---@param opts? { how?: string }
---@return boolean
function M.follow_target(target, opts)
  opts = opts or {}
  local parsed = M.parse_target(target)
  if parsed.kind == "query-contents" then
    require("denote.query").grep(parsed.query)
    return true
  elseif parsed.kind == "query-filenames" then
    require("denote.explorer").open({ regexp = parsed.query })
    return true
  end

  local file = files.find_by_id(parsed.identifier)
  if not file then
    utils.warn("Cannot find Denote file with identifier: " .. tostring(parsed.identifier))
    return false
  end

  -- Record jump in jumplist before navigating
  vim.cmd("normal! m'")
  utils.open_file(file, opts.how)
  if parsed.search and parsed.search ~= "" then
    M.jump_to_search(parsed.search)
  end
  return true
end

--- Follow the Denote link under the cursor.
--- Returns true if a Denote link was found and followed, false otherwise.
---@param opts? { how?: string }
---@return boolean
function M.follow_link(opts)
  local link = M.link_at_cursor()
  if not link then
    return false
  end
  return M.follow_target(link.target, opts)
end

--- Insert a link to an existing Denote file (`denote-link`).
---@param opts? { target?: string, description?: string, id_only?: boolean, dir?: string }
function M.link(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local syntax = M.buffer_syntax(bufnr)
  local from_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h")

  local function do_insert(target_path, desc)
    local id = naming.retrieve_identifier(target_path)
    if not id then
      utils.warn("Target file has no Denote identifier: " .. target_path)
      return
    end
    local final_desc = desc
    if not opts.id_only and not final_desc then
      final_desc = M.default_description(target_path)
    end
    local formatted = M.format_link(id, final_desc, {
      syntax = syntax,
      id_only = opts.id_only,
      file_path = target_path,
      from_dir = from_dir,
    })
    insert_at_cursor(formatted, bufnr)
  end

  if opts.target then
    do_insert(opts.target, opts.description)
    return
  end

  local root = config.directory(opts.dir)
  local all_files = sort.sort_files(files.list({ dir = root, denote_only = true }), "identifier", true)
  local items = {}
  for i, p in ipairs(all_files) do
    items[i] = pickers.file_item(p, { dir = root })
  end

  pickers.pick({
    title = opts.id_only and "Denote Link (ID only)" or "Denote Link",
    items = items,
    on_choice = function(chosen)
      if chosen[1] then
        local target_path = chosen[1].value
        if opts.id_only or opts.description then
          do_insert(target_path, opts.description)
        else
          vim.ui.input({
            prompt = "Link description: ",
            default = M.default_description(target_path),
          }, function(desc)
            if desc ~= nil then
              do_insert(target_path, desc)
            end
          end)
        end
      end
    end,
  })
end

--- Link to an existing note or create a new note and insert a link to it
--- (`denote-link-or-create`).
---@param opts? { id_only?: boolean, dir?: string }
function M.link_or_create(opts)
  opts = opts or {}
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  local syntax = M.buffer_syntax(origin_buf)
  local root = config.directory(opts.dir)

  local all_files = sort.sort_files(files.list({ dir = root, denote_only = true }), "identifier", true)
  local items = {}
  for i, p in ipairs(all_files) do
    items[i] = pickers.file_item(p, { dir = root })
  end

  pickers.pick({
    title = "Denote Link or Create",
    items = items,
    allow_query = true,
    create_label = "+ Create and link new note...",
    on_choice = function(chosen, query)
      if chosen[1] then
        M.link({ target = chosen[1].value, id_only = opts.id_only })
      else
        create.note({
          dir = root,
          _initial_title = query and vim.trim(query) ~= "" and vim.trim(query) or nil,
          open = false,
          save = true,
          on_created = function(new_path, meta)
            if vim.api.nvim_win_is_valid(origin_win) then
              vim.api.nvim_set_current_win(origin_win)
            end
            local desc = meta.title ~= "" and meta.title or M.default_description(new_path)
            local formatted = M.format_link(meta.identifier, desc, {
              syntax = syntax,
              id_only = opts.id_only,
              file_path = new_path,
            })
            insert_at_cursor(formatted, origin_buf)
            utils.notify("Created and linked: " .. vim.fn.fnamemodify(new_path, ":t"))
          end,
        })
      end
    end,
  })
end

--- Create a new note, insert a link to it in the current buffer, and open the new note
--- (`denote-link-after-creating`).
---@param opts? { id_only?: boolean, dir?: string }
function M.link_after_creating(opts)
  opts = opts or {}
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_pos = vim.api.nvim_win_get_cursor(0)
  local syntax = M.buffer_syntax(origin_buf)

  create.note({
    dir = opts.dir,
    save = true,
    open = true,
    on_created = function(new_path, meta)
      if vim.api.nvim_buf_is_valid(origin_buf) then
        local desc = meta.title ~= "" and meta.title or M.default_description(new_path)
        local formatted = M.format_link(meta.identifier, desc, {
          syntax = syntax,
          id_only = opts.id_only,
          file_path = new_path,
        })
        local row = origin_pos[1] - 1
        local col = origin_pos[2]
        local line = vim.api.nvim_buf_get_lines(origin_buf, row, row + 1, false)[1] or ""
        local ins = math.min(col, #line)
        vim.api.nvim_buf_set_lines(
          origin_buf,
          row,
          row + 1,
          false,
          { line:sub(1, ins) .. formatted .. line:sub(ins + 1) }
        )
      end
    end,
  })
end

--- Link directly to a specific heading inside an Org or Markdown Denote note
--- (`denote-org-link-to-heading`, also works for Markdown `#` headings).
---@param opts? { target?: string, dir?: string }
function M.link_to_heading(opts)
  opts = opts or {}
  local origin_buf = vim.api.nvim_get_current_buf()
  local syntax = M.buffer_syntax(origin_buf)

  local function pick_heading(target_path)
    local headings = frontmatter.extract_headings(target_path)
    if #headings == 0 then
      utils.warn("No headings found in " .. vim.fn.fnamemodify(target_path, ":t"))
      return
    end
    local items = {}
    for _, h in ipairs(headings) do
      local indent = string.rep("  ", math.max(0, h.level - 1))
      local tag = h.custom_id and (" [#" .. h.custom_id .. "]") or ""
      items[#items + 1] = {
        display = {
          { indent .. h.text, "DenoteTitle" },
          { tag, "DenoteKeywords" },
        },
        text = h.text .. " " .. (h.custom_id or ""),
        filename = target_path,
        lnum = h.lnum,
        value = h,
      }
    end
    pickers.pick({
      title = "Select Heading",
      items = items,
      on_choice = function(chosen)
        if not chosen[1] then
          return
        end
        local h = chosen[1].value
        local id = naming.retrieve_identifier(target_path)
        local target_ft = frontmatter.detect_file_type(target_path)
        local search_opt
        if h.custom_id then
          search_opt = "#" .. h.custom_id
        elseif target_ft == "org" then
          search_opt = "*" .. h.text
        else
          search_opt = "#" .. h.slug
        end
        local desc = frontmatter.extract_title(target_path) .. "::" .. h.text
        local formatted = M.format_link(id .. "::" .. search_opt, desc, {
          syntax = syntax,
          file_path = target_path,
        })
        insert_at_cursor(formatted, origin_buf)
      end,
    })
  end

  if opts.target then
    pick_heading(opts.target)
    return
  end

  local root = config.directory(opts.dir)
  local all_files =
    sort.sort_files(files.list({ dir = root, denote_only = true, text_only = true }), "identifier", true)
  local items = {}
  for i, p in ipairs(all_files) do
    items[i] = pickers.file_item(p, { dir = root })
  end
  pickers.pick({
    title = "Select Note for Heading Link",
    items = items,
    on_choice = function(chosen)
      if chosen[1] then
        pick_heading(chosen[1].value)
      end
    end,
  })
end

--- Insert a typographic list of links to all Denote files matching `regexp`
--- (`denote-add-links`).
---@param regexp? string
---@param opts? { id_only?: boolean, sort_by?: string, reverse?: boolean, dir?: string, include_date?: boolean }
---@return string[]|nil inserted_lines
function M.add_links(regexp, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cur_path = utils.normalize(vim.api.nvim_buf_get_name(bufnr))
  local syntax = M.buffer_syntax(bufnr)
  local root = config.directory(opts.dir)

  local function insert_for(pat)
    local matched = files.list({
      dir = root,
      denote_only = true,
      regexp = pat,
    })
    -- Exclude current file
    matched = vim.tbl_filter(function(p)
      return utils.normalize(p) ~= cur_path
    end, matched)
    matched = sort.sort_files(matched, opts.sort_by or "identifier", opts.reverse)

    if #matched == 0 then
      utils.notify("No matching Denote files for: " .. tostring(pat))
      return {}
    end

    local out = {}
    for _, path in ipairs(matched) do
      local id = naming.retrieve_identifier(path)
      local desc = M.default_description(path)
      if opts.include_date and id then
        local ts = naming.identifier_to_time(id)
        if ts then
          desc = tostring(os.date("%Y-%m-%d", ts)) .. "  " .. desc
        end
      end
      out[#out + 1] = "- " .. M.format_link(id, desc, { syntax = syntax, id_only = opts.id_only, file_path = path })
    end

    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, out)
    return out
  end

  if regexp ~= nil then
    return insert_for(regexp)
  end

  vim.ui.input({ prompt = "Add links matching regexp: " }, function(input)
    if input ~= nil then
      insert_for(vim.trim(input))
    end
  end)
end

--- Pick from all outbound Denote links in the current buffer and jump to the target
--- (`denote-find-link`).
function M.find_link()
  local bufnr = vim.api.nvim_get_current_buf()
  local links = M.links_in_buffer(bufnr)
  if #links == 0 then
    utils.notify("No Denote links in current buffer")
    return
  end

  local seen, items = {}, {}
  for _, link in ipairs(links) do
    local key = link.target .. ":" .. tostring(link.lnum)
    if not seen[key] then
      seen[key] = true
      local target_file = link.identifier and files.find_by_id(link.identifier) or nil
      local label = link.description or (target_file and frontmatter.extract_title(target_file)) or link.target
      items[#items + 1] = {
        display = {
          { link.target, link.kind == "id" and "DenoteIdentifier" or "DenoteQueryLink" },
          { "  " .. label, "DenoteTitle" },
          { string.format("  (line %d)", link.lnum or 1), "Comment" },
        },
        text = link.target .. " " .. label,
        filename = target_file,
        value = link,
      }
    end
  end

  pickers.pick({
    title = "Denote Outbound Links",
    items = items,
    on_choice = function(chosen, _, how)
      if chosen[1] then
        M.follow_target(chosen[1].value.target, { how = how })
      end
    end,
  })
end

--- Convert `denote:ID` links in the current buffer into relative file links
--- (matching `denote-markdown-convert-links-to-file-paths`, also supports Org).
---@param bufnr? integer
---@return integer count Number of converted links
function M.convert_links_to_file_paths(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cur_path = vim.api.nvim_buf_get_name(bufnr)
  local base_dir = cur_path ~= "" and vim.fn.fnamemodify(utils.normalize(cur_path), ":h") or config.directory()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local count = 0

  for i, line in ipairs(lines) do
    if line:find("denote:", 1, true) then
      -- Markdown: [desc](denote:ID) -> [desc](relpath)
      local new_line = line:gsub("%[([^%]]*)%]%(denote:(" .. naming.ID_PATTERN .. ")%)", function(desc, id)
        local target = files.find_by_id(id)
        if target then
          count = count + 1
          return string.format("[%s](%s)", desc, utils.relpath(target, base_dir))
        end
      end)
      -- Org: [[denote:ID][desc]] -> [[file:relpath][desc]]
      new_line = new_line:gsub("%[%[denote:(" .. naming.ID_PATTERN .. ")%]%[([^%]]*)%]%]", function(id, desc)
        local target = files.find_by_id(id)
        if target then
          count = count + 1
          return string.format("[[file:%s][%s]]", utils.relpath(target, base_dir), desc)
        end
      end)
      lines[i] = new_line
    end
  end

  if count > 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end
  return count
end

--- Convert relative file links pointing to Denote files back into `denote:ID` links
--- (matching `denote-markdown-convert-links-to-denote-paths`, also supports Org).
---@param bufnr? integer
---@return integer count Number of converted links
function M.convert_links_to_denote_paths(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local count = 0

  for i, line in ipairs(lines) do
    -- Markdown: [desc](path/to/2026...md) -> [desc](denote:ID)
    local new_line = line:gsub("%[([^%]]*)%]%(([^%)]+)%)", function(desc, href)
      if href:match("^denote:") or href:match("^https?://") then
        return nil
      end
      local id = naming.retrieve_identifier(href)
      if id then
        count = count + 1
        return string.format("[%s](denote:%s)", desc, id)
      end
    end)
    -- Org: [[file:path/to/2026...org][desc]] -> [[denote:ID][desc]]
    new_line = new_line:gsub("%[%[file:([^%]]+)%]%[([^%]]*)%]%]", function(href, desc)
      local id = naming.retrieve_identifier(href)
      if id then
        count = count + 1
        return string.format("[[denote:%s][%s]]", id, desc)
      end
    end)
    lines[i] = new_line
  end

  if count > 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end
  return count
end

return M
