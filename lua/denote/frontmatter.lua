---@mod denote.frontmatter Front matter generation, parsing, and in-place rewriting
---@brief [[
--- Supports all four canonical Emacs Denote file types:
--- - `org` (`.org`): `#+title:`, `#+date:`, `#+filetags:`, `#+identifier:`, `#+signature:`
--- - `markdown-yaml` (`.md`): YAML front matter delimited by `---`
--- - `markdown-toml` (`.md`): TOML front matter delimited by `+++`
--- - `text` (`.txt`): plain text key/value header terminated by `---------------------------`
--- Plus user-defined custom file types in `config.opts.file_types`.
---@brief ]]

local config = require("denote.config")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

--- Built-in file type specifications.
M.BUILTINS = {
  org = {
    extension = ".org",
    date_format = "org",
  },
  ["markdown-yaml"] = {
    extension = ".md",
    date_format = "iso8601",
  },
  ["markdown-toml"] = {
    extension = ".md",
    date_format = "iso8601",
  },
  text = {
    extension = ".txt",
    date_format = "date",
  },
}

--- Return all configured file types (built-ins merged with user overrides).
---@return table<string, table>
function M.file_types()
  return vim.tbl_deep_extend("force", vim.deepcopy(M.BUILTINS), config.opts.file_types or {})
end

--- Return the file type spec for `file_type` (defaults to `config.opts.file_type`).
---@param file_type? string
---@return table
---@return string
function M.get_spec(file_type)
  local ft = file_type or config.opts.file_type or "markdown-yaml"
  local all = M.file_types()
  if all[ft] then
    return all[ft], ft
  end
  -- Accept short aliases like "markdown" or "md"
  if ft == "markdown" or ft == "md" then
    return all["markdown-yaml"], "markdown-yaml"
  end
  return all["markdown-yaml"], "markdown-yaml"
end

--- Return the extension for a given file type.
---@param file_type? string
---@return string
function M.extension_for(file_type)
  local spec = M.get_spec(file_type)
  return spec.extension or ".md"
end

--- Detect the Denote file type from a file path and optional lines.
---@param path string
---@param lines? string[]
---@return string|nil
function M.detect_file_type(path, lines)
  local _, ext = naming.split_extension(vim.fn.fnamemodify(path, ":t"))
  -- Strip compound encryption suffix if any (e.g. ".org.gpg" -> ".org")
  local primary = ext:match("^(%.[^%.]+)") or ext
  primary = primary:lower()

  if primary == ".org" then
    return "org"
  elseif primary == ".md" or primary == ".markdown" then
    lines = lines or utils.read_lines(path, 5)
    for _, line in ipairs(lines) do
      if line:match("^%+%+%+%s*$") then
        return "markdown-toml"
      elseif line:match("^%-%-%-%s*$") then
        return "markdown-yaml"
      elseif line:match("%S") then
        break
      end
    end
    if config.opts.file_type == "markdown-toml" then
      return "markdown-toml"
    end
    return "markdown-yaml"
  elseif primary == ".txt" then
    return "text"
  end

  -- Check custom file types
  for name, spec in pairs(config.opts.file_types or {}) do
    if spec.extension and spec.extension:lower() == primary then
      return name
    end
  end

  return nil
end

--- Format a Unix timestamp according to a file type's date format.
---@param ts integer
---@param file_type string
---@return string
function M.format_date(ts, file_type)
  local spec = M.get_spec(file_type)
  local fmt = config.opts.date_format or spec.date_format or "iso8601"
  if fmt == "org" then
    return tostring(os.date("[%Y-%m-%d %a %H:%M]", ts))
  elseif fmt == "iso8601" then
    return tostring(os.date("%Y-%m-%dT%H:%M:%S", ts)) .. utils.tz_offset(ts)
  elseif fmt == "date" then
    return tostring(os.date("%Y-%m-%d", ts))
  else
    return tostring(os.date(fmt, ts))
  end
end

--- Check whether a component should be written even when empty.
---@param comp string
---@return boolean
local function keep_empty(comp)
  return vim.tbl_contains(config.opts.front_matter_components_present_even_if_empty or {}, comp)
end

--- Quote a string safely for YAML / TOML double-quoted strings.
---@param s string
---@return string
local function quote_double(s)
  return '"' .. (s or ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- Unquote a YAML/TOML string value.
---@param s string
---@return string
local function unquote(s)
  s = vim.trim(s or "")
  if #s >= 2 then
    local first, last = s:sub(1, 1), s:sub(-1)
    if first == '"' and last == '"' then
      return (s:sub(2, -2):gsub('\\"', '"'):gsub("\\\\", "\\"))
    elseif first == "'" and last == "'" then
      return (s:sub(2, -2):gsub("''", "'"))
    end
  end
  return s
end

--- Format keywords for each built-in front matter format.
---@param keywords string[]
---@param file_type string
---@return string
function M.format_keywords(keywords, file_type)
  local kws = naming.sluggify_keywords(keywords or {})
  if file_type == "org" then
    if #kws == 0 then
      return ""
    end
    return ":" .. table.concat(kws, ":") .. ":"
  elseif file_type == "markdown-yaml" or file_type == "markdown-toml" then
    if #kws == 0 then
      return "[]"
    end
    local quoted = {}
    for i, kw in ipairs(kws) do
      quoted[i] = quote_double(kw)
    end
    return "[" .. table.concat(quoted, ", ") .. "]"
  elseif file_type == "text" then
    return table.concat(kws, "  ")
  end
  return table.concat(kws, ", ")
end

---@class denote.FrontMatterMeta
---@field title? string
---@field date? integer|string Unix timestamp or preformatted string
---@field keywords? string[]
---@field identifier? string
---@field signature? string
---@field file_type? string

--- Build the front matter string (including trailing blank line) for a file type.
---@param meta denote.FrontMatterMeta
---@return string
function M.format(meta)
  local spec, ft = M.get_spec(meta.file_type)
  local title = meta.title or ""
  local ts = (
    type(meta.date) == "number" and meta.date
    or (meta.identifier and naming.identifier_to_time(meta.identifier))
    or os.time()
  ) --[[@as integer]]
  local date_str = type(meta.date) == "string" and meta.date or M.format_date(ts, ft)
  local kws = naming.sluggify_keywords(meta.keywords or {})
  local id = meta.identifier or naming.format_identifier(ts)
  local sig = meta.signature or ""

  if type(spec.front_matter) == "function" then
    return spec.front_matter({
      title = title,
      date = date_str,
      keywords = kws,
      identifier = id,
      signature = sig,
    })
  elseif type(spec.front_matter) == "string" then
    return string.format(spec.front_matter, title, date_str, M.format_keywords(kws, ft), id, sig)
  end

  local lines = {}
  if ft == "org" then
    lines[#lines + 1] = "#+title:      " .. title
    lines[#lines + 1] = "#+date:       " .. date_str
    lines[#lines + 1] = "#+filetags:   " .. M.format_keywords(kws, ft)
    lines[#lines + 1] = "#+identifier: " .. id
    if sig ~= "" or keep_empty("signature") then
      lines[#lines + 1] = "#+signature:  " .. sig
    end
    lines[#lines + 1] = ""
  elseif ft == "markdown-yaml" then
    lines[#lines + 1] = "---"
    lines[#lines + 1] = "title:      " .. quote_double(title)
    lines[#lines + 1] = "date:       " .. date_str
    lines[#lines + 1] = "tags:       " .. M.format_keywords(kws, ft)
    lines[#lines + 1] = "identifier: " .. quote_double(id)
    if sig ~= "" or keep_empty("signature") then
      lines[#lines + 1] = "signature:  " .. quote_double(sig)
    end
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
  elseif ft == "markdown-toml" then
    lines[#lines + 1] = "+++"
    lines[#lines + 1] = "title      = " .. quote_double(title)
    lines[#lines + 1] = "date       = " .. date_str
    lines[#lines + 1] = "tags       = " .. M.format_keywords(kws, ft)
    lines[#lines + 1] = "identifier = " .. quote_double(id)
    if sig ~= "" or keep_empty("signature") then
      lines[#lines + 1] = "signature  = " .. quote_double(sig)
    end
    lines[#lines + 1] = "+++"
    lines[#lines + 1] = ""
  elseif ft == "text" then
    lines[#lines + 1] = "title:      " .. title
    lines[#lines + 1] = "date:       " .. date_str
    lines[#lines + 1] = "tags:       " .. M.format_keywords(kws, ft)
    lines[#lines + 1] = "identifier: " .. id
    if sig ~= "" or keep_empty("signature") then
      lines[#lines + 1] = "signature:  " .. sig
    end
    lines[#lines + 1] = "---------------------------"
    lines[#lines + 1] = ""
  end

  return table.concat(lines, "\n") .. "\n"
end

--- Parse inline YAML/TOML array string like `["a", "b"]` or `[a, b]`.
---@param s string
---@return string[]
local function parse_inline_list(s)
  local inner = vim.trim(s or ""):match("^%[(.*)%]$")
  if not inner then
    return {}
  end
  local out = {}
  for item in inner:gmatch("[^,]+") do
    local v = unquote(item)
    if v ~= "" then
      out[#out + 1] = v
    end
  end
  return out
end

--- Parse Org filetags string like `:emacs:neovim:`.
---@param s string
---@return string[]
local function parse_org_tags(s)
  local out = {}
  for tag in (s or ""):gmatch("[^:%s]+") do
    if tag ~= "" then
      out[#out + 1] = tag
    end
  end
  return out
end

---@class denote.ParsedFrontMatter
---@field title? string
---@field date? string
---@field keywords? string[]
---@field identifier? string
---@field signature? string
---@field file_type string
---@field start_line integer 1-based start line of front matter (0 if none)
---@field end_line integer 1-based end line of front matter (0 if none)
---@field has_front_matter boolean

--- Parse front matter from `lines` for the given `file_type`.
---@param lines string[]
---@param file_type string
---@return denote.ParsedFrontMatter
function M.parse_lines(lines, file_type)
  local res = {
    title = nil,
    date = nil,
    keywords = nil,
    identifier = nil,
    signature = nil,
    file_type = file_type,
    start_line = 0,
    end_line = 0,
    has_front_matter = false,
  }

  if not lines or #lines == 0 then
    return res
  end

  if file_type == "org" then
    local first_lnum, last_lnum = nil, nil
    for i, line in ipairs(lines) do
      local key, val = line:match("^#%+(%w+):%s*(.-)%s*$")
      if key then
        first_lnum = first_lnum or i
        last_lnum = i
        local low = key:lower()
        if low == "title" then
          res.title = val
        elseif low == "date" then
          res.date = val
        elseif low == "filetags" then
          res.keywords = parse_org_tags(val)
        elseif low == "identifier" then
          res.identifier = unquote(val)
        elseif low == "signature" then
          res.signature = unquote(val)
        end
      elseif line:match("^%s*$") then
        if first_lnum then
          break
        end
      else
        break
      end
    end
    if first_lnum then
      res.has_front_matter = true
      res.start_line = first_lnum
      res.end_line = last_lnum
    end
    return res
  end

  if file_type == "markdown-yaml" then
    local start_idx = nil
    for i = 1, math.min(#lines, 5) do
      if lines[i]:match("^%-%-%-%s*$") then
        start_idx = i
        break
      elseif lines[i]:match("%S") then
        return res
      end
    end
    if not start_idx then
      return res
    end
    local end_idx = nil
    for i = start_idx + 1, #lines do
      if lines[i]:match("^%-%-%-%s*$") or lines[i]:match("^%.%.%.%s*$") then
        end_idx = i
        break
      end
    end
    if not end_idx then
      return res
    end
    res.has_front_matter = true
    res.start_line = start_idx
    res.end_line = end_idx

    local in_tags_list = false
    for i = start_idx + 1, end_idx - 1 do
      local line = lines[i]
      if in_tags_list then
        local item = line:match("^%s*%-%s+(.+)$")
        if item then
          res.keywords = res.keywords or {}
          local v = unquote(item)
          if v ~= "" then
            res.keywords[#res.keywords + 1] = v
          end
        elseif line:match("^%S") then
          in_tags_list = false
        end
      end
      if not in_tags_list then
        local key, val = line:match("^([%w_%-]+):%s*(.-)%s*$")
        if key then
          local low = key:lower()
          if low == "title" then
            res.title = unquote(val)
          elseif low == "date" then
            res.date = unquote(val)
          elseif low == "tags" or low == "keywords" then
            if val == "" then
              res.keywords = {}
              in_tags_list = true
            elseif val:match("^%[") then
              res.keywords = parse_inline_list(val)
            else
              res.keywords = utils.parse_keywords_input(unquote(val))
            end
          elseif low == "identifier" then
            res.identifier = unquote(val)
          elseif low == "signature" then
            res.signature = unquote(val)
          end
        end
      end
    end
    return res
  end

  if file_type == "markdown-toml" then
    local start_idx = nil
    for i = 1, math.min(#lines, 5) do
      if lines[i]:match("^%+%+%+%s*$") then
        start_idx = i
        break
      elseif lines[i]:match("%S") then
        return res
      end
    end
    if not start_idx then
      return res
    end
    local end_idx = nil
    for i = start_idx + 1, #lines do
      if lines[i]:match("^%+%+%+%s*$") then
        end_idx = i
        break
      end
    end
    if not end_idx then
      return res
    end
    res.has_front_matter = true
    res.start_line = start_idx
    res.end_line = end_idx

    for i = start_idx + 1, end_idx - 1 do
      local key, val = lines[i]:match("^([%w_%-]+)%s*=%s*(.-)%s*$")
      if key then
        local low = key:lower()
        if low == "title" then
          res.title = unquote(val)
        elseif low == "date" then
          res.date = unquote(val)
        elseif low == "tags" or low == "keywords" then
          res.keywords = parse_inline_list(val)
        elseif low == "identifier" then
          res.identifier = unquote(val)
        elseif low == "signature" then
          res.signature = unquote(val)
        end
      end
    end
    return res
  end

  if file_type == "text" then
    local end_idx = nil
    local has_key = false
    for i = 1, math.min(#lines, 30) do
      if lines[i]:match("^%-%-%-%-%-+%s*$") then
        end_idx = i
        break
      elseif lines[i]:match("^[%w_%-]+:%s*") then
        has_key = true
      end
    end
    if not end_idx or not has_key then
      return res
    end
    res.has_front_matter = true
    res.start_line = 1
    res.end_line = end_idx
    for i = 1, end_idx - 1 do
      local key, val = lines[i]:match("^([%w_%-]+):%s*(.-)%s*$")
      if key then
        local low = key:lower()
        if low == "title" then
          res.title = val
        elseif low == "date" then
          res.date = val
        elseif low == "tags" or low == "keywords" then
          res.keywords = utils.parse_keywords_input(val)
        elseif low == "identifier" then
          res.identifier = unquote(val)
        elseif low == "signature" then
          res.signature = unquote(val)
        end
      end
    end
    return res
  end

  return res
end

--- Parse front matter from a file on disk (or its loaded buffer if modified).
---@param path string
---@return denote.ParsedFrontMatter|nil
function M.parse_file(path)
  local bufnr = utils.find_buffer(path)
  local lines
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)
  else
    lines = utils.read_lines(path, 50)
  end
  local ft = M.detect_file_type(path, lines)
  if not ft then
    return nil
  end
  return M.parse_lines(lines, ft)
end

local uv = vim.uv or vim.loop

--- Cache of on-disk titles: path -> { key = "mtime:size", title = string|false }.
---@type table<string, { key: string, title: string|false }>
local title_cache = {}

--- Clear the front matter title cache.
function M.clear_cache()
  title_cache = {}
end

---@param path string
---@return string|nil
local function front_matter_title(path)
  local bufnr = utils.find_buffer(path)
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    -- Live buffer contents may differ from disk: never cache.
    local fm = M.parse_file(path)
    return fm and fm.title ~= "" and fm.title or nil
  end
  local st = uv.fs_stat(path)
  local key = st and (st.mtime.sec .. "." .. (st.mtime.nsec or 0) .. ":" .. st.size) or ""
  local hit = title_cache[path]
  if hit and hit.key == key then
    return hit.title or nil
  end
  local fm = M.parse_file(path)
  local title = fm and fm.title ~= "" and fm.title or nil
  title_cache[path] = { key = key, title = title or false }
  return title
end

--- Extract the human-readable title of a Denote file:
--- front matter `title` if present and non-empty, otherwise desluggified filename title,
--- otherwise filename stem.
---@param path string
---@return string
function M.extract_title(path)
  local title = front_matter_title(path)
  if title then
    return title
  end
  local parsed = naming.parse_filename(path)
  if parsed.title and parsed.title ~= "" then
    return naming.desluggify("title", parsed.title)
  end
  local stem = naming.split_extension(parsed.filename)
  return stem
end

--- Rewrite front matter fields (`title`, `keywords`, `signature`, `identifier`) in `lines`
--- in place, preserving all other user-defined front matter lines and body content.
--- If the file has no front matter and `opts.add_if_missing` is true, prepends front matter.
---@param lines string[]
---@param file_type string
---@param updates { title?: string, keywords?: string[], signature?: string, identifier?: string, date?: integer|string }
---@param opts? { add_if_missing?: boolean }
---@return string[] new_lines
---@return boolean changed
function M.rewrite_lines(lines, file_type, updates, opts)
  opts = opts or {}
  local fm = M.parse_lines(lines, file_type)
  if not fm.has_front_matter then
    if not opts.add_if_missing then
      return lines, false
    end
    local block = M.format({
      title = updates.title or "",
      date = updates.date,
      keywords = updates.keywords or {},
      identifier = updates.identifier,
      signature = updates.signature or "",
      file_type = file_type,
    })
    local block_lines = vim.split(block, "\n", { plain = true })
    -- remove trailing empty element from final newline
    if block_lines[#block_lines] == "" then
      table.remove(block_lines)
    end
    local out = vim.list_extend(block_lines, lines)
    return out, true
  end

  local out = vim.deepcopy(lines)
  local changed = false

  -- Helper to format one field line in the target syntax
  local function format_field(key, value)
    if file_type == "org" then
      if key == "title" then
        return "#+title:      " .. tostring(value or "")
      elseif key == "keywords" then
        return "#+filetags:   " .. M.format_keywords(value or {}, "org")
      elseif key == "identifier" then
        return "#+identifier: " .. tostring(value or "")
      elseif key == "signature" then
        return "#+signature:  " .. tostring(value or "")
      end
    elseif file_type == "markdown-yaml" then
      if key == "title" then
        return "title:      " .. quote_double(tostring(value or ""))
      elseif key == "keywords" then
        return "tags:       " .. M.format_keywords(value or {}, "markdown-yaml")
      elseif key == "identifier" then
        return "identifier: " .. quote_double(tostring(value or ""))
      elseif key == "signature" then
        return "signature:  " .. quote_double(tostring(value or ""))
      end
    elseif file_type == "markdown-toml" then
      if key == "title" then
        return "title      = " .. quote_double(tostring(value or ""))
      elseif key == "keywords" then
        return "tags       = " .. M.format_keywords(value or {}, "markdown-toml")
      elseif key == "identifier" then
        return "identifier = " .. quote_double(tostring(value or ""))
      elseif key == "signature" then
        return "signature  = " .. quote_double(tostring(value or ""))
      end
    elseif file_type == "text" then
      if key == "title" then
        return "title:      " .. tostring(value or "")
      elseif key == "keywords" then
        return "tags:       " .. M.format_keywords(value or {}, "text")
      elseif key == "identifier" then
        return "identifier: " .. tostring(value or "")
      elseif key == "signature" then
        return "signature:  " .. tostring(value or "")
      end
    end
  end

  local function key_pattern(key)
    if file_type == "org" then
      local name = key == "keywords" and "filetags" or key
      return "^#%+" .. name .. ":"
    elseif file_type == "markdown-yaml" or file_type == "text" then
      if key == "keywords" then
        return "^tags:"
      end
      return "^" .. key .. ":"
    elseif file_type == "markdown-toml" then
      if key == "keywords" then
        return "^tags%s*="
      end
      return "^" .. key .. "%s*="
    end
  end

  local range_start = (file_type == "markdown-yaml" or file_type == "markdown-toml") and (fm.start_line + 1)
    or fm.start_line
  local range_end = (file_type == "markdown-yaml" or file_type == "markdown-toml" or file_type == "text")
      and (fm.end_line - 1)
    or fm.end_line

  local function upsert_field(key, value)
    if value == nil then
      return
    end
    local pat = key_pattern(key)
    local new_line = format_field(key, value)
    if not pat or not new_line then
      return
    end

    -- Search within front matter range
    local found_idx = nil
    for i = range_start, range_end do
      local low = out[i]:lower()
      if low:match(pat) or (key == "keywords" and low:match("^keywords[:%s=]")) then
        found_idx = i
        break
      end
    end

    -- If signature is being cleared and not kept when empty, remove the line
    if key == "signature" and value == "" and not keep_empty("signature") then
      if found_idx then
        table.remove(out, found_idx)
        range_end = range_end - 1
        changed = true
      end
      return
    end

    if found_idx then
      -- For YAML block list tags (lines starting with `  - `), remove continuation lines
      if key == "keywords" and file_type == "markdown-yaml" then
        while found_idx + 1 <= range_end and out[found_idx + 1]:match("^%s*%-%s+") do
          table.remove(out, found_idx + 1)
          range_end = range_end - 1
          changed = true
        end
      end
      if out[found_idx] ~= new_line then
        out[found_idx] = new_line
        changed = true
      end
    else
      -- Insert at the end of front matter
      if key == "signature" and value == "" and not keep_empty("signature") then
        return
      end
      table.insert(out, range_end + 1, new_line)
      range_end = range_end + 1
      changed = true
    end
  end

  upsert_field("title", updates.title)
  upsert_field("keywords", updates.keywords)
  upsert_field("identifier", updates.identifier)
  upsert_field("signature", updates.signature)

  return out, changed
end

--- Strip front matter from `lines` (used by `denote-files` dynamic block `:no-front-matter t`).
---@param lines string[]
---@param file_type string|nil
---@return string[]
function M.strip_front_matter(lines, file_type)
  if not file_type then
    return lines
  end
  local fm = M.parse_lines(lines, file_type)
  if not fm.has_front_matter then
    return lines
  end
  local start = fm.end_line + 1
  while start <= #lines and lines[start]:match("^%s*$") do
    start = start + 1
  end
  local out = {}
  for i = start, #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

---@class denote.Heading
---@field text string Heading title text
---@field level integer Heading level (1+)
---@field lnum integer 1-based line number
---@field custom_id? string Org `:CUSTOM_ID:` property if present
---@field slug string URL/anchor slug for Markdown headings

--- Extract all headings from an Org or Markdown file (for `DenoteLinkToHeading` and following `::*Heading` / `::#id`).
---@param path string
---@return denote.Heading[]
function M.extract_headings(path)
  local bufnr = utils.find_buffer(path)
  local lines
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  else
    lines = utils.read_lines(path)
  end

  local ft = M.detect_file_type(path, lines)
  local headings = {}

  if ft == "org" then
    local i = 1
    while i <= #lines do
      local stars, text = lines[i]:match("^(%*+)%s+(.+)$")
      if stars then
        -- Strip trailing Org tags like `  :tag1:tag2:`
        local clean = vim.trim(text:gsub("%s+:[^%s:]+:$", ""):gsub("%s+:[^%s]+:$", ""))
        local custom_id = nil
        -- Look ahead for :PROPERTIES: drawer immediately below heading
        local j = i + 1
        if lines[j] and lines[j]:match("^%s*:PROPERTIES:%s*$") then
          j = j + 1
          while j <= #lines and not lines[j]:match("^%s*:END:%s*$") do
            local cid = lines[j]:match("^%s*:CUSTOM_ID:%s*(.-)%s*$")
            if cid and cid ~= "" then
              custom_id = cid
            end
            j = j + 1
          end
        end
        headings[#headings + 1] = {
          text = clean,
          level = #stars,
          lnum = i,
          custom_id = custom_id,
          slug = naming.sluggify_title(clean),
        }
      end
      i = i + 1
    end
  else
    -- Markdown headings (skipping fenced code blocks and front matter)
    local in_fence = false
    local fm = ft and M.parse_lines(lines, ft) or nil
    local start_line = (fm and fm.has_front_matter) and (fm.end_line + 1) or 1
    for i = start_line, #lines do
      local line = lines[i]
      if line:match("^%s*```") or line:match("^%s*~~~") then
        in_fence = not in_fence
      elseif not in_fence then
        local hashes, text = line:match("^(#+)%s+(.+)$")
        if hashes then
          local clean = vim.trim(text:gsub("%s+#+%s*$", ""))
          headings[#headings + 1] = {
            text = clean,
            level = #hashes,
            lnum = i,
            custom_id = nil,
            slug = naming.sluggify_title(clean),
          }
        end
      end
    end
  end

  return headings
end

return M
