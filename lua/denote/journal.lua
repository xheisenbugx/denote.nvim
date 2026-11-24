---@mod denote.journal Daily journal entries (matching `denote-journal`)
---
--- Provides:
--- - `new_entry(opts)`: always create a new journal note for today or a specified date.
--- - `new_or_existing_entry(opts)`: open today's (or date's) existing journal note, or create it.
--- - `link_or_create_entry(opts)`: insert a Denote link to today's (or date's) journal note,
---   creating it first if it doesn't exist.

local config = require("denote.config")
local create = require("denote.create")
local files = require("denote.files")
local links = require("denote.links")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

--- Return the configured journal directory (defaults to `<denote.directory>/journal` if configured,
--- otherwise `<denote.directory>`).
---@return string
function M.directory()
  local jcfg = config.opts.journal or {}
  if jcfg.directory and jcfg.directory ~= "" then
    return utils.normalize(jcfg.directory)
  end
  return config.directory()
end

--- Return the journal keyword slug (default: `"journal"`).
---@return string
function M.keyword()
  local jcfg = config.opts.journal or {}
  return naming.sluggify_keyword(jcfg.keyword or "journal")
end

--- Format a journal entry title for Unix timestamp `ts`.
---@param ts integer
---@return string
function M.format_title(ts)
  local jcfg = config.opts.journal or {}
  local fmt = jcfg.title_format or "%A %e %B %Y"
  -- Collapse double spaces produced by %e on single-digit days
  return (vim.trim(tostring(os.date(fmt, ts))):gsub("%s+", " "))
end

--- Find existing journal entries matching date `ts` (`YYYYMMDD` + journal keyword).
---@param ts integer
---@return string[]
function M.find_for_date(ts)
  local day_prefix = tostring(os.date("%Y%m%d", ts))
  local kw = M.keyword()
  local dir = M.directory()
  local found = {}
  for _, path in ipairs(files.list({ dir = dir, denote_only = true })) do
    local parsed = naming.parse_filename(path)
    if parsed.identifier and parsed.identifier:sub(1, 8) == day_prefix then
      if kw == "" or vim.tbl_contains(parsed.keywords or {}, kw) then
        found[#found + 1] = path
      end
    end
  end
  table.sort(found)
  return found
end

--- Create a new journal entry (`denote-journal-new-entry`).
---@param opts? { date?: string|integer, open?: boolean, save?: boolean, title?: string, extra_keywords?: string[] }
---@return table meta
function M.new_entry(opts)
  opts = opts or {}
  local ts, err = utils.parse_date(opts.date)
  if not ts then
    utils.warn(err or "Invalid journal date; using today")
    ts = os.time()
  end
  local jcfg = config.opts.journal or {}
  local kws = { M.keyword() }
  for _, kw in ipairs(opts.extra_keywords or {}) do
    kws[#kws + 1] = kw
  end

  return create.create_sync({
    dir = M.directory(),
    title = opts.title or M.format_title(ts),
    keywords = kws,
    date = ts,
    file_type = jcfg.file_type or config.opts.file_type,
    template = jcfg.template,
    open = opts.open,
    save = opts.save,
  })
end

--- Open today's (or `opts.date`'s) journal entry if it exists, otherwise create it
--- (`denote-journal-new-or-existing-entry`).
---@param opts? { date?: string|integer, open?: boolean, save?: boolean, how?: string }
---@return string path, boolean created
function M.new_or_existing_entry(opts)
  opts = opts or {}
  local ts, err = utils.parse_date(opts.date)
  if not ts then
    utils.warn(err or "Invalid journal date; using today")
    ts = os.time()
  end

  local existing = M.find_for_date(ts)
  if #existing > 0 then
    local target = existing[1]
    if opts.open ~= false then
      utils.open_file(target, opts.how)
    end
    return target, false
  end

  local meta = M.new_entry({
    date = ts,
    open = opts.open,
    save = opts.save,
  })
  return meta.path, true
end

--- Insert a link in the current buffer to today's (or `opts.date`'s) journal entry,
--- creating the entry first if it does not exist (`denote-journal-link-or-create-entry`).
---@param opts? { date?: string|integer, id_only?: boolean }
---@return string path
function M.link_or_create_entry(opts)
  opts = opts or {}
  local path = M.new_or_existing_entry({
    date = opts.date,
    open = false,
    save = true,
  })
  links.link({
    target = path,
    id_only = opts.id_only,
  })
  return path
end

return M
