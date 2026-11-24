---@mod denote.calendar Journal calendar (matching `denote-journal-calendar-mode`)
---
--- A floating month view (pure Lua) that highlights the days with a journal entry.
--- `F`/`<CR>` visits the entry of the day at point, `N` visits or creates the entry for
--- the period (see `journal.interval`) containing that day.

local journal = require("denote.journal")
local utils = require("denote.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("denote_journal_calendar")

--- Width of a day cell ("dd" + separator).
local CELL = 3

local month_names = {
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
}
local day_abbrevs = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }

--- Define the calendar highlight groups (only if the user has not defined them).
function M.setup_highlights()
  vim.api.nvim_set_hl(0, "DenoteJournalCalendarEntry", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "DenoteJournalCalendarToday", { default = true, link = "Todo" })
  vim.api.nvim_set_hl(0, "DenoteJournalCalendarHeader", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "DenoteJournalCalendarWeekday", { default = true, link = "Comment" })
end

--- Local noon timestamp for a calendar date (os.time normalises overflowing fields).
---@return integer
local function noon(year, month, day)
  return os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
end

--- Number of days in `month` of `year`.
---@param year integer
---@param month integer
---@return integer
function M.days_in_month(year, month)
  return os.date("*t", noon(year, month + 1, 0)).day
end

--- Weekday of a date: 1 = Sunday .. 7 = Saturday (like `os.date("*t").wday`).
---@return integer
function M.weekday(year, month, day)
  return os.date("*t", noon(year, month, day)).wday
end

--- Weekday column headers starting at `week_start` (1 = Monday, 0 = Sunday).
---@param week_start? integer
---@return string[]
function M.weekday_names(week_start)
  week_start = week_start or journal.week_start()
  local out = {}
  for i = 0, 6 do
    out[#out + 1] = day_abbrevs[(week_start + i) % 7 + 1]
  end
  return out
end

--- Lay out a month as weeks of 7 cells. Each cell is the day number, or `false` for
--- padding before the 1st / after the last day.
---@param year integer
---@param month integer
---@param week_start? integer 1 = Monday (default: `journal.week_start`), 0 = Sunday
---@return (integer|false)[][]
function M.month_grid(year, month, week_start)
  week_start = week_start or journal.week_start()
  local lead = (M.weekday(year, month, 1) - 1 - week_start) % 7
  local ndays = M.days_in_month(year, month)
  local weeks, row = {}, {}
  for _ = 1, lead do
    row[#row + 1] = false
  end
  for d = 1, ndays do
    row[#row + 1] = d
    if #row == 7 then
      weeks[#weeks + 1] = row
      row = {}
    end
  end
  if #row > 0 then
    while #row < 7 do
      row[#row + 1] = false
    end
    weeks[#weeks + 1] = row
  end
  return weeks
end

---@class denote.CalendarState
---@field buf integer
---@field win integer
---@field year integer
---@field month integer
---@field day integer
---@field cells table<integer, { [1]: integer, [2]: integer }> day -> { row (0-based), col (0-based) }
---@field moving? boolean True while the cursor is being moved programmatically

---@type denote.CalendarState|nil
local state = nil

--- Return the calendar state (for tests / integrations), or nil if closed.
---@return denote.CalendarState|nil
function M.state()
  if state and vim.api.nvim_win_is_valid(state.win) then
    return state
  end
  return nil
end

--- Timestamp (noon) of the day at point, or nil when the calendar is closed.
---@return integer|nil
function M.date_at_point()
  local s = M.state()
  return s and noon(s.year, s.month, s.day) or nil
end

local function render()
  local s = state
  if not s or not vim.api.nvim_buf_is_valid(s.buf) then
    return
  end
  local grid = M.month_grid(s.year, s.month)
  local lines = { table.concat(M.weekday_names(), " ") }
  s.cells = {}
  for r, week in ipairs(grid) do
    local parts = {}
    for c, d in ipairs(week) do
      parts[#parts + 1] = d and string.format("%2d", d) or "  "
      if d then
        s.cells[d] = { r, (c - 1) * CELL }
      end
    end
    lines[#lines + 1] = table.concat(parts, " ")
  end
  while #lines < 7 do
    lines[#lines + 1] = ""
  end

  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  pcall(
    vim.api.nvim_buf_set_extmark,
    s.buf,
    ns,
    0,
    0,
    { end_col = #lines[1], hl_group = "DenoteJournalCalendarWeekday" }
  )
  local entries = journal.entries_by_date({ year = s.year, month = s.month })
  local today = os.date("*t")
  for d, pos in pairs(s.cells) do
    local key = string.format("%04d%02d%02d", s.year, s.month, d)
    local hl
    if today.year == s.year and today.month == s.month and today.day == d then
      hl = "DenoteJournalCalendarToday"
    end
    if entries[key] then
      hl = "DenoteJournalCalendarEntry"
      -- Today with an entry: mark both (entry colour, today's on top via priority)
      if today.year == s.year and today.month == s.month and today.day == d then
        pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, pos[1], pos[2], {
          end_col = pos[2] + 2,
          hl_group = "DenoteJournalCalendarToday",
          priority = 210,
        })
      end
    end
    if hl then
      pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, pos[1], pos[2], {
        end_col = pos[2] + 2,
        hl_group = hl,
        priority = 200,
      })
    end
  end

  if vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_set_config, s.win, {
      title = " " .. month_names[s.month] .. " " .. s.year .. " ",
      title_pos = "center",
    })
    local pos = s.cells[s.day]
    if pos then
      s.moving = true
      pcall(vim.api.nvim_win_set_cursor, s.win, { pos[1] + 1, pos[2] })
      s.moving = false
    end
  end
end

--- Move the cursor to a date (re-rendering when the month changes).
---@param ts integer
function M.goto_date(ts)
  local s = M.state()
  if not s then
    return
  end
  local t = os.date("*t", ts)
  local month_changed = t.year ~= s.year or t.month ~= s.month
  s.year, s.month, s.day = t.year, t.month, t.day
  if month_changed or not s.cells then
    render()
  else
    local pos = s.cells[s.day]
    s.moving = true
    pcall(vim.api.nvim_win_set_cursor, s.win, { pos[1] + 1, pos[2] })
    s.moving = false
  end
end

local function shift_days(n)
  local s = M.state()
  if s then
    M.goto_date(noon(s.year, s.month, s.day + n))
  end
end

local function shift_months(n)
  local s = M.state()
  if not s then
    return
  end
  local first = os.date("*t", noon(s.year, s.month + n, 1))
  local day = math.min(s.day, M.days_in_month(first.year, first.month))
  M.goto_date(noon(first.year, first.month, day))
end

--- Close the calendar float.
function M.close()
  local s = state
  state = nil
  if s and vim.api.nvim_win_is_valid(s.win) then
    vim.api.nvim_win_close(s.win, true)
  end
end

--- Visit the journal entry of the day at point (`denote-journal-calendar-find-file`).
--- Prompts when several entries share the day; notifies when there is none.
function M.find_file()
  local ts = M.date_at_point()
  if not ts then
    return
  end
  local found = journal.find_for_date(ts)
  if #found == 0 then
    utils.notify("No journal entry for " .. os.date("%Y-%m-%d", ts))
    return
  end
  M.close()
  if #found == 1 then
    utils.open_file(found[1])
    return
  end
  vim.ui.select(found, {
    prompt = "Journal entry: ",
    format_item = function(p)
      return vim.fn.fnamemodify(p, ":t")
    end,
  }, function(choice)
    if choice then
      utils.open_file(choice)
    end
  end)
end

--- Visit or create the journal entry for the period containing the day at point
--- (`denote-journal-calendar-new-or-existing`).
function M.new_or_existing()
  local ts = M.date_at_point()
  if not ts then
    return
  end
  M.close()
  journal.new_or_existing_entry({ date = ts })
end

local help_rows = {
  { "h / l", "Previous / next day" },
  { "k / j", "Previous / next week" },
  { "[ / ]  H / L", "Previous / next month" },
  { "{ / }", "Previous / next year" },
  { "t", "Go to today" },
  { "F / <CR>", "Visit entry of the day at point" },
  { "N", "Visit or create entry for the day's period" },
  { "q / <Esc>", "Close" },
  { "g?", "Show this help" },
}

--- Open the journal calendar float on the month of `date` (default: today).
---@param opts? { date?: string|integer }
function M.open(opts)
  opts = opts or {}
  local ts, err = utils.parse_date(opts.date)
  if not ts then
    utils.warn(err or "Invalid date; using today")
    ts = os.time()
  end
  M.setup_highlights()
  M.close()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "denote-calendar"

  local width = 7 * CELL - 1
  local height = 7
  local ui = vim.api.nvim_list_uis()[1]
  local cols = ui and ui.width or 80
  local rows = ui and ui.height or 24
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((rows - height) / 2) - 1),
    col = math.max(0, math.floor((cols - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Calendar ",
    title_pos = "center",
    footer = " g? help ",
    footer_pos = "center",
  })
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = false

  local t = os.date("*t", ts)
  state = { buf = buf, win = win, year = t.year, month = t.month, day = t.day, cells = {} }
  render()

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Denote calendar: " .. desc })
  end
  map("h", function()
    shift_days(-vim.v.count1)
  end, "previous day")
  map("l", function()
    shift_days(vim.v.count1)
  end, "next day")
  map("k", function()
    shift_days(-7 * vim.v.count1)
  end, "previous week")
  map("j", function()
    shift_days(7 * vim.v.count1)
  end, "next week")
  for _, lhs in ipairs({ "[", "H" }) do
    map(lhs, function()
      shift_months(-vim.v.count1)
    end, "previous month")
  end
  for _, lhs in ipairs({ "]", "L" }) do
    map(lhs, function()
      shift_months(vim.v.count1)
    end, "next month")
  end
  map("{", function()
    shift_months(-12 * vim.v.count1)
  end, "previous year")
  map("}", function()
    shift_months(12 * vim.v.count1)
  end, "next year")
  map("t", function()
    M.goto_date(os.time())
  end, "today")
  map("F", M.find_file, "visit entry")
  map("<CR>", M.find_file, "visit entry")
  map("N", M.new_or_existing, "new or existing entry")
  map("q", M.close, "close")
  map("<Esc>", M.close, "close")
  map("g?", function()
    require("denote.ui").show_help("Denote journal calendar", help_rows)
  end, "help")

  local group = vim.api.nvim_create_augroup("DenoteJournalCalendar", { clear = true })
  -- Keep the selected day in sync with other cursor motions (mouse, w/b, ...)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      local s = M.state()
      if not s or s.moving or vim.api.nvim_get_current_win() ~= s.win then
        return
      end
      local cur = vim.api.nvim_win_get_cursor(s.win)
      local row, col = cur[1] - 1, cur[2]
      for d, pos in pairs(s.cells) do
        if pos[1] == row and col >= pos[2] and col < pos[2] + CELL then
          s.day = d
          if col ~= pos[2] then
            s.moving = true
            pcall(vim.api.nvim_win_set_cursor, s.win, { row + 1, pos[2] })
            s.moving = false
          end
          return
        end
      end
      local pos = s.cells[s.day]
      if pos then
        s.moving = true
        pcall(vim.api.nvim_win_set_cursor, s.win, { pos[1] + 1, pos[2] })
        s.moving = false
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        -- Close when focus moves elsewhere (but not for the help float opened on top)
        local s = M.state()
        if s and s.buf == buf and vim.api.nvim_get_current_win() ~= s.win then
          local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
          if cfg.relative == "" then
            M.close()
          end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      if state and state.buf == buf then
        state = nil
      end
    end,
  })
end

return M
