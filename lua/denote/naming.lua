---@mod denote.naming Denote file-naming scheme, parser, sluggifier, and identifier generator
---@brief [[
--- Implements the canonical Emacs Denote file-naming scheme:
---   DATE==SIGNATURE--TITLE__KEYWORDS.EXTENSION
--- as well as Denote 3.x/4.x reordered components (`@@DATE` when identifier is not first),
--- partial Denote filenames, compound extensions (e.g. `.org.gpg`), sluggification,
--- desluggification, and collision-free identifier generation.
---@brief ]]

local config = require("denote.config")
local utils = require("denote.utils")

local M = {}

--- Canonical Denote identifier pattern: YYYYMMDDTHHMMSS
M.ID_PATTERN = "%d%d%d%d%d%d%d%dT%d%d%d%d%d%d"

--- Common compound encryption/compression secondary extensions (e.g. .org.gpg, .md.age)
local COMPOUND_EXT = {
  gpg = true,
  age = true,
  asc = true,
  enc = true,
  gz = true,
}

--- Remove excluded punctuation from `str`.
---@param str string
---@return string
function M.remove_punctuation(str)
  local pat = config.opts.excluded_punctuation_pattern
  if not pat or pat == "" then
    return str
  end
  return (str:gsub(pat, ""))
end

--- Sluggify a title string into kebab-case (matching `denote-sluggify-title`).
---@param str string
---@return string
function M.sluggify_title(str)
  if not str or str == "" then
    return ""
  end
  local custom = config.opts.file_name_slug_functions and config.opts.file_name_slug_functions.title
  if type(custom) == "function" then
    return custom(str)
  end
  local s = vim.trim(str)
  s = M.remove_punctuation(s)
  if not config.opts.preserve_case then
    s = s:lower()
  end
  -- Convert whitespace and underscores to hyphens, collapse consecutive hyphens
  s = s:gsub("[%s_]+", "-")
  s = s:gsub("%-+", "-")
  s = s:gsub("^%-+", ""):gsub("%-+$", "")
  return s
end

--- Sluggify a signature string using `=` as word separator (matching `denote-sluggify-signature`).
---@param str string
---@return string
function M.sluggify_signature(str)
  if not str or str == "" then
    return ""
  end
  local custom = config.opts.file_name_slug_functions and config.opts.file_name_slug_functions.signature
  if type(custom) == "function" then
    return custom(str)
  end
  local s = vim.trim(str)
  -- Preserve `=` while removing other punctuation
  s = s:gsub("[%[%]{}!@#$%%^&*()+%-'\"?,%.|;:~`‘’“”/\\<>]", "")
  if not config.opts.preserve_case then
    s = s:lower()
  end
  s = s:gsub("[%s_]+", "=")
  s = s:gsub("=+", "=")
  s = s:gsub("^=+", ""):gsub("=+$", "")
  return s
end

--- Sluggify a single keyword (matching `denote-sluggify-keyword`).
--- In Denote, keywords have no spaces, hyphens, or underscores.
---@param str string
---@return string
function M.sluggify_keyword(str)
  if not str or str == "" then
    return ""
  end
  local custom = config.opts.file_name_slug_functions and config.opts.file_name_slug_functions.keyword
  if type(custom) == "function" then
    return custom(str)
  end
  local s = vim.trim(str)
  s = M.remove_punctuation(s)
  if not config.opts.preserve_case then
    s = s:lower()
  end
  s = s:gsub("[%s_%-]+", "")
  return s
end

--- Sluggify a list of keywords (deduplicating and optionally sorting).
---@param keywords string[]|string|nil
---@return string[]
function M.sluggify_keywords(keywords)
  local raw = utils.parse_keywords_input(keywords)
  local out = {}
  for _, kw in ipairs(raw) do
    local slug = M.sluggify_keyword(kw)
    if slug ~= "" then
      out[#out + 1] = slug
    end
  end
  return utils.unique_strings(out, config.opts.sort_keywords ~= false)
end

--- General sluggify dispatcher (`component` is "title", "signature", or "keyword").
---@param component 'title'|'signature'|'keyword'
---@param str string
---@return string
function M.sluggify(component, str)
  if component == "title" then
    return M.sluggify_title(str)
  elseif component == "signature" then
    return M.sluggify_signature(str)
  elseif component == "keyword" then
    return M.sluggify_keyword(str)
  end
  return M.sluggify_title(str)
end

--- Convert a slug back into a human-readable string (matching `denote-desluggify`).
---@param component 'title'|'signature'|'keyword'
---@param str string
---@return string
function M.desluggify(component, str)
  if not str or str == "" then
    return ""
  end
  if component == "title" then
    local s = str:gsub("%-+", " ")
    if #s > 0 then
      s = s:sub(1, 1):upper() .. s:sub(2)
    end
    return s
  elseif component == "signature" then
    return (str:gsub("=+", " "))
  end
  return str
end

--- Split a basename into stem and extension (handling compound extensions like `.org.gpg`).
---@param basename string
---@return string stem
---@return string extension
function M.split_extension(basename)
  if not basename or basename == "" then
    return "", ""
  end
  -- Hidden file without extension (e.g. ".gitignore")
  if basename:sub(1, 1) == "." and not basename:find(".", 2, true) then
    return basename, ""
  end
  local stem, ext = basename:match("^(.*)(%.[^%.]+)$")
  if not stem or stem == "" then
    return basename, ""
  end
  local ext_name = ext:sub(2):lower()
  if COMPOUND_EXT[ext_name] then
    local stem2, ext2 = stem:match("^(.*)(%.[^%.]+)$")
    if stem2 and stem2 ~= "" then
      return stem2, ext2 .. ext
    end
  end
  return stem, ext
end

---@class denote.ParsedFile
---@field path string Full normalized path (or basename if no directory was given)
---@field dir string Parent directory ("" if basename only)
---@field filename string Basename including extension
---@field identifier string|nil 15-char timestamp ID (YYYYMMDDTHHMMSS)
---@field signature string|nil Signature string (without leading `==`)
---@field title string|nil Slugified title (without leading `--`)
---@field keywords string[] List of keywords (empty table if none)
---@field extension string Extension including leading dot (e.g. ".org", ".md", "")
---@field is_denote boolean True when the file has a valid Denote identifier

--- Parse a file path or basename into its Denote components.
--- Handles standard order (`DATE==SIG--TITLE__KW.ext`) as well as any custom
--- `file_name_components_order` (`@@DATE`, `==SIG`, `--TITLE`, `__KW`).
---@param path string
---@return denote.ParsedFile
function M.parse_filename(path)
  local norm = path:find("[/\\]") and utils.normalize(path) or path
  local dir = path:find("[/\\]") and vim.fn.fnamemodify(norm, ":h") or ""
  local filename = vim.fn.fnamemodify(norm, ":t")
  local stem, extension = M.split_extension(filename)

  local result = {
    path = norm,
    dir = dir,
    filename = filename,
    identifier = nil,
    signature = nil,
    title = nil,
    keywords = {},
    extension = extension,
    is_denote = false,
  }

  if stem == "" then
    return result
  end

  -- Tokenize stem by Denote delimiters: `@@`, `==`, `--`, `__`.
  -- The first component may have no leading delimiter (usually identifier, or title/signature/etc.).
  local tokens = {}
  local pos = 1
  local len = #stem

  -- Check if stem starts with a delimiter
  local function delim_at(i)
    local two = stem:sub(i, i + 1)
    if two == "@@" or two == "==" or two == "--" or two == "__" then
      return two
    end
    return nil
  end

  local cur_delim = delim_at(1)
  if cur_delim then
    pos = 3
  end

  local seg_start = pos
  local i = pos
  while i <= len do
    local d = delim_at(i)
    if d then
      tokens[#tokens + 1] = { delim = cur_delim, value = stem:sub(seg_start, i - 1) }
      cur_delim = d
      i = i + 2
      seg_start = i
    else
      i = i + 1
    end
  end
  tokens[#tokens + 1] = { delim = cur_delim, value = stem:sub(seg_start, len) }

  for idx, tok in ipairs(tokens) do
    local d, v = tok.delim, tok.value
    if d == "@@" then
      local id = v:match("^(" .. M.ID_PATTERN .. ")$")
      if id then
        result.identifier = id
      end
    elseif d == nil and idx == 1 then
      local id = v:match("^(" .. M.ID_PATTERN .. ")$")
      if id then
        result.identifier = id
      elseif v ~= "" then
        -- Non-standard first component (reordered without leading delimiter)
        -- If there's an explicit @@id later, treat leading bare segment as title if not set
        result._leading_bare = v
      end
    elseif d == "==" then
      if v ~= "" then
        result.signature = v
      end
    elseif d == "--" then
      if v ~= "" then
        result.title = v
      end
    elseif d == "__" then
      if v ~= "" then
        local kws = {}
        for kw in v:gmatch("[^_]+") do
          if kw ~= "" then
            kws[#kws + 1] = kw
          end
        end
        result.keywords = kws
      end
    end
  end

  if result._leading_bare then
    if result.identifier and not result.title then
      result.title = result._leading_bare
    end
    result._leading_bare = nil
  end

  result.is_denote = result.identifier ~= nil
  return result
end

--- Return true if `path` is a Denote file (has a valid identifier).
---@param path string
---@return boolean
function M.is_denote_file(path)
  return M.parse_filename(path).is_denote
end

--- Format a Denote filename (basename only) from its components.
---@param opts { identifier?: string, signature?: string, title?: string, keywords?: string[]|string, extension?: string, sluggify?: boolean }
---@return string
function M.format_filename(opts)
  local do_slug = opts.sluggify ~= false
  local id = opts.identifier or ""
  local sig = opts.signature or ""
  local title = opts.title or ""
  local kws = opts.keywords or {}
  local ext = opts.extension or ""

  if do_slug then
    sig = M.sluggify_signature(sig)
    title = M.sluggify_title(title)
    kws = M.sluggify_keywords(kws)
  elseif type(kws) == "string" then
    kws = utils.parse_keywords_input(kws)
  end

  if ext ~= "" and ext:sub(1, 1) ~= "." then
    ext = "." .. ext
  end

  local order = config.opts.file_name_components_order or { "identifier", "signature", "title", "keywords" }
  local parts = {}

  for _, comp in ipairs(order) do
    if comp == "identifier" and id ~= "" then
      if #parts == 0 and not config.opts.identifier_delimiter_always_present then
        parts[#parts + 1] = id
      else
        parts[#parts + 1] = "@@" .. id
      end
    elseif comp == "signature" and sig ~= "" then
      parts[#parts + 1] = "==" .. sig
    elseif comp == "title" and title ~= "" then
      parts[#parts + 1] = "--" .. title
    elseif comp == "keywords" and #kws > 0 then
      parts[#parts + 1] = "__" .. table.concat(kws, "_")
    end
  end

  return table.concat(parts, "") .. ext
end

--- Format a Unix timestamp into a Denote identifier (`YYYYMMDDTHHMMSS`).
---@param ts? integer
---@return string
function M.format_identifier(ts)
  return tostring(os.date("%Y%m%dT%H%M%S", ts or os.time()))
end

--- Parse a Denote identifier (`YYYYMMDDTHHMMSS`) back into a Unix timestamp.
---@param id string
---@return integer|nil
function M.identifier_to_time(id)
  if not id then
    return nil
  end
  local y, m, d, H, Mi, S = id:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)$")
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(H),
    min = tonumber(Mi),
    sec = tonumber(S),
  })
end

--- Generate a unique Denote identifier that does not collide with any existing
--- file in `existing_ids` (a set table `{ [id] = true }`).
---@param ts? integer Base timestamp (defaults to `os.time()`)
---@param existing_ids? table<string, boolean> Set of already-used identifiers
---@return string
function M.unique_identifier(ts, existing_ids)
  local t = ts or os.time()
  local id = M.format_identifier(t)
  if not existing_ids then
    return id
  end
  while existing_ids[id] do
    t = t + 1
    id = M.format_identifier(t)
  end
  return id
end

--- Extract an identifier from a file path, or nil.
---@param path string
---@return string|nil
function M.retrieve_identifier(path)
  return M.parse_filename(path).identifier
end

return M
