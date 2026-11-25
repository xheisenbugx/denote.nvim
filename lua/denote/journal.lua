---@mod denote.journal Journal entries (matching `denote-journal`)
---
--- `journal.interval` ("daily", "weekly", "monthly", "yearly") decides how often a new entry
--- is created; existing entries are matched by their identifier date falling in the period.
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
    return config.directory(jcfg.directory)
  end
  return config.directory()
end

--- Return the journal keyword slug (default: `"journal"`).
---@return string
function M.keyword()
  local jcfg = config.opts.journal or {}
  return naming.sluggify_keyword(jcfg.keyword or "journal")
end

M.intervals = { daily = true, weekly = true, monthly = true, yearly = true }

--- Default title formats per interval (used when `journal.title_format` is nil).
M.default_title_formats = {
  daily = "%A %e %B %Y",
  weekly = "Week %V %G",
  monthly = "%B %Y",
  yearly = "%Y",
}

--- Return the configured journal interval (`denote-journal-interval`). Unknown values are
--- treated as `"daily"`, like Emacs.
---@return "daily"|"weekly"|"monthly"|"yearly"
function M.interval()
  local iv = (config.opts.journal or {}).interval
  if type(iv) == "string" and M.intervals[iv] then
    return iv
  end
  return "daily"
end

--- First day of the week: 1 = Monday (ISO 8601, default), 0 = Sunday.
---@return integer
function M.week_start()
  local ws = (config.opts.journal or {}).week_start
  return ws == 0 and 0 or 1
end

--- Local timestamp for a calendar date at `hour` (os.time normalises overflowing fields).
---@return integer
local function mktime(year, month, day, hour, min, sec)
  return os.time({ year = year, month = month, day = day, hour = hour or 12, min = min or 0, sec = sec or 0 })
end

--- ISO 8601 week number and week-based year for `ts`.
---@param ts integer
---@return integer week, integer year
function M.iso_week(ts)
  local t = os.date("*t", ts)
  local iso_wday = (t.wday + 5) % 7 + 1 -- Monday = 1 .. Sunday = 7
  local thu = os.date("*t", mktime(t.year, t.month, t.day - iso_wday + 4))
  return math.floor((thu.yday - 1) / 7) + 1, thu.year
end

--- Return the bounds of the `interval` period containing `ts`: the first second of its first
--- day and the last second of its last day (both local time).
--- Weeks start on `week_start` (default: `journal.week_start`, Monday).
---@param ts integer
---@param interval? string "daily"|"weekly"|"monthly"|"yearly" (default: configured interval)
---@param week_start? integer 1 = Monday, 0 = Sunday
---@return integer start_ts, integer end_ts
function M.period_bounds(ts, interval, week_start)
  interval = interval or M.interval()
  week_start = week_start or M.week_start()
  local t = os.date("*t", ts)
  local y, m, d = t.year, t.month, t.day
  local sy, sm, sd, ey, em, ed
  if interval == "weekly" then
    local offset = (t.wday - 1 - week_start) % 7 -- days since the start of the week
    sy, sm, sd = y, m, d - offset
    ey, em, ed = y, m, d - offset + 6
  elseif interval == "monthly" then
    sy, sm, sd = y, m, 1
    ey, em, ed = y, m + 1, 0
  elseif interval == "yearly" then
    sy, sm, sd = y, 1, 1
    ey, em, ed = y, 12, 31
  else
    sy, sm, sd = y, m, d
    ey, em, ed = y, m, d
  end
  return mktime(sy, sm, sd, 0, 0, 0), mktime(ey, em, ed, 23, 59, 59)
end

--- Format a journal entry title for Unix timestamp `ts`. `%V`/`%G` are expanded to the
--- ISO week number / week-based year portably (also on platforms whose strftime lacks them).
---@param ts integer
---@param interval? string (default: configured interval)
---@return string
function M.format_title(ts, interval)
  interval = interval or M.interval()
  local jcfg = config.opts.journal or {}
  local fmt = jcfg.title_format
  if type(fmt) == "table" then
    fmt = fmt[interval]
  end
  if type(fmt) ~= "string" then
    fmt = M.default_title_formats[interval] or M.default_title_formats.daily
  end
  if fmt:find("%%[VG]") then
    local week_ts = ts
    if interval == "weekly" then
      -- Number the week after its Thursday so Sunday-start weeks stay consistent
      local start = M.period_bounds(ts, "weekly")
      local st = os.date("*t", start)
      week_ts = mktime(st.year, st.month, st.day + (M.week_start() == 0 and 4 or 3))
    end
    local week, wyear = M.iso_week(week_ts)
    fmt =
      fmt:gsub("%%%%", "\1"):gsub("%%V", string.format("%02d", week)):gsub("%%G", tostring(wyear)):gsub("\1", "%%%%")
  end
  -- Collapse double spaces produced by %e on single-digit days
  return (vim.trim(tostring(os.date(fmt, ts))):gsub("%s+", " "))
end

--- Timestamp encoded in a Denote identifier (`YYYYMMDDTHHMMSS`), or nil.
---@param id string|nil
---@return integer|nil
local function id_time(id)
  local y, m, d, H, Mi, S = (id or ""):match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)")
  if not y then
    return nil
  end
  return mktime(tonumber(y), tonumber(m), tonumber(d), tonumber(H), tonumber(Mi), tonumber(S))
end

--- List all journal entries: Denote files in the journal directory whose keywords include the
--- journal keyword (any Denote file when the keyword is empty), sorted by path.
---@return { path: string, identifier: string, time: integer }[]
function M.entries()
  local kw = M.keyword()
  local out = {}
  for _, path in ipairs(files.list({ dir = M.directory(), denote_only = true })) do
    local parsed = naming.parse_filename(path)
    local t = id_time(parsed.identifier)
    if t and (kw == "" or vim.tbl_contains(parsed.keywords or {}, kw)) then
      out[#out + 1] = { path = path, identifier = parsed.identifier, time = t }
    end
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

--- Group journal entries by the day of their identifier.
--- With `year`/`month` given, only entries from that month are included.
---@param opts? { year?: integer, month?: integer }
---@return table<string, string[]> map of `YYYYMMDD` -> sorted paths
function M.entries_by_date(opts)
  opts = opts or {}
  local prefix = ""
  if opts.year then
    prefix = string.format("%04d", opts.year)
    if opts.month then
      prefix = prefix .. string.format("%02d", opts.month)
    end
  end
  local out = {}
  for _, e in ipairs(M.entries()) do
    local day = e.identifier:sub(1, 8)
    if day:sub(1, #prefix) == prefix then
      out[day] = out[day] or {}
      table.insert(out[day], e.path)
    end
  end
  return out
end

--- Find existing journal entries whose identifier date is in the same `interval` period as `ts`.
---@param ts integer
---@param interval? string (default: configured interval)
---@return string[]
function M.find_for_period(ts, interval)
  local start, stop = M.period_bounds(ts, interval)
  local found = {}
  for _, e in ipairs(M.entries()) do
    if e.time >= start and e.time <= stop then
      found[#found + 1] = e.path
    end
  end
  return found
end

--- Find existing journal entries for the exact day of `ts` (`YYYYMMDD` + journal keyword).
---@param ts integer
---@return string[]
function M.find_for_date(ts)
  return M.find_for_period(ts, "daily")
end

--- Create a new journal entry (`denote-journal-new-entry`).
---@param opts? { date?: string|integer, open?: boolean, save?: boolean, how?: string, title?: string, extra_keywords?: string[], interactive?: boolean, answers?: table<string, string> }
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

  local answers = vim.deepcopy(opts.answers or {})
  local function build(resolved_answers)
    return create.create_sync({
      dir = M.directory(),
      title = opts.title or M.format_title(ts),
      keywords = kws,
      date = ts,
      file_type = jcfg.file_type or config.opts.file_type,
      template = jcfg.template,
      open = opts.open,
      save = opts.save,
      how = opts.how,
      context = { answers = resolved_answers },
    })
  end

  local named = jcfg.template and (config.opts.templates or {})[jcfg.template] or nil
  if opts.interactive ~= false and type(named) == "string" then
    local capture = require("denote.capture")
    if #capture.prompts(named) > 0 then
      return capture.ask({ named }, answers, build)
    end
  end

  return build(answers)
end

--- Open the journal entry for the current period (see `journal.interval`) containing today
--- (or `opts.date`) if it exists, otherwise create it (`denote-journal-new-or-existing-entry`).
---@param opts? { date?: string|integer, open?: boolean, save?: boolean, how?: string }
---@return string path, boolean created
function M.new_or_existing_entry(opts)
  opts = opts or {}
  local ts, err = utils.parse_date(opts.date)
  if not ts then
    utils.warn(err or "Invalid journal date; using today")
    ts = os.time()
  end

  local existing = M.find_for_period(ts)
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
    how = opts.how,
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
