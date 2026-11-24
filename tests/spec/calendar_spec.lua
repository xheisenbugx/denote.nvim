local calendar = require("denote.calendar")
local denote = require("denote")
local journal = require("denote.journal")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

--- Days carrying `hl` in the calendar buffer.
local function highlighted_days(hl)
  local s = calendar.state()
  local ns = vim.api.nvim_get_namespaces()["denote_journal_calendar"]
  local by_pos = {}
  for d, pos in pairs(s.cells) do
    by_pos[pos[1] .. ":" .. pos[2]] = d
  end
  local days = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.buf, ns, 0, -1, { details = true })) do
    if m[4].hl_group == hl then
      local d = by_pos[m[2] .. ":" .. m[3]]
      if d then
        days[#days + 1] = d
      end
    end
  end
  table.sort(days)
  return days
end

describe("denote.calendar grid", function()
  it("lays out a month starting on Sunday", function()
    -- February 2026 starts on a Sunday and has 28 days
    eq(28, calendar.days_in_month(2026, 2))
    local sun = calendar.month_grid(2026, 2, 0)
    eq(4, #sun)
    eq({ 1, 2, 3, 4, 5, 6, 7 }, sun[1])
    eq({ 22, 23, 24, 25, 26, 27, 28 }, sun[4])
    local mon = calendar.month_grid(2026, 2, 1)
    eq(5, #mon)
    eq({ false, false, false, false, false, false, 1 }, mon[1])
    eq({ 23, 24, 25, 26, 27, 28, false }, mon[5])
  end)

  it("handles leap-year February", function()
    eq(29, calendar.days_in_month(2028, 2))
    eq(28, calendar.days_in_month(2100, 2))
    local g = calendar.month_grid(2028, 2, 1) -- 2028-02-01 is a Tuesday
    eq({ false, 1, 2, 3, 4, 5, 6 }, g[1])
    eq({ 28, 29, false, false, false, false, false }, g[5])
  end)

  it("names weekday columns from the week start", function()
    eq({ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }, calendar.weekday_names(1))
    eq({ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }, calendar.weekday_names(0))
  end)
end)

describe("denote.calendar float", function()
  it("highlights entry days, navigates, and supports F / N", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        file_type = "org",
        journal = { directory = dir .. "/journal", title_format = "%Y-%m-%d" },
        mappings = { enabled = false },
      })
      local e3 = journal.new_entry({ date = "2026-11-03", open = false, save = true }).path
      journal.new_entry({ date = "2026-11-24", open = false, save = true })
      journal.new_entry({ date = "2026-12-02", open = false, save = true })

      vim.cmd("enew!")
      local origin = vim.api.nvim_get_current_win()
      denote.journal_calendar({ date = "2026-11-10" })
      local s = calendar.state()
      ok(s ~= nil, "calendar open")
      eq("Mo Tu We Th Fr Sa Su", buf_lines(s.buf)[1])
      eq({ 3, 24 }, highlighted_days("DenoteJournalCalendarEntry"))
      eq(10, s.day)

      -- Navigation: month forward/back, day and week motions
      feed("]")
      eq(12, calendar.state().month)
      eq({ 2 }, highlighted_days("DenoteJournalCalendarEntry"))
      feed("[")
      eq(11, calendar.state().month)
      feed("}")
      eq(2027, calendar.state().year)
      feed("{")
      eq(2026, calendar.state().year)
      feed("l")
      eq(11, calendar.state().day)
      feed("h")
      eq(10, calendar.state().day)

      -- F on a day without an entry notifies and keeps the calendar open
      feed("F")
      ok(calendar.state() ~= nil, "still open")

      -- k moves a week back to the 3rd, F visits the entry
      feed("k")
      eq(3, calendar.state().day)
      feed("F")
      eq(nil, calendar.state())
      eq(origin, vim.api.nvim_get_current_win())
      eq(e3, vim.api.nvim_buf_get_name(0))

      -- N creates the entry for the day at point (daily interval)
      denote.journal_calendar({ date = "2026-11-05" })
      feed("N")
      eq(nil, calendar.state())
      ok(vim.api.nvim_buf_get_name(0):find("/journal/20261105T", 1, true) ~= nil)
      vim.cmd("silent write")
      local found = journal.find_for_date(os.time({ year = 2026, month = 11, day = 5, hour = 12 }))
      eq(1, #found)
      eq(found[1], vim.api.nvim_buf_get_name(0))

      -- q closes
      denote.journal_calendar({ date = "2026-11-05" })
      eq({ 3, 5, 24 }, highlighted_days("DenoteJournalCalendarEntry"))
      feed("q")
      eq(nil, calendar.state())
    end)
  end)

  it("N reuses the weekly entry for the period of the day at point", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        file_type = "org",
        journal = { directory = dir, interval = "weekly" },
        mappings = { enabled = false },
      })
      local p = journal.new_entry({ date = "2026-11-23", open = false, save = true }).path
      vim.cmd("enew!")
      denote.journal_calendar({ date = "2026-11-27" })
      feed("N")
      eq(p, vim.api.nvim_buf_get_name(0))
      eq(1, #journal.entries())
    end)
  end)
end)
