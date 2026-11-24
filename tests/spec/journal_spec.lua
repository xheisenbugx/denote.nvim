local denote = require("denote")
local journal = require("denote.journal")
local naming = require("denote.naming")

describe("denote.journal", function()
  it("creates, reuses, and links to daily journal entries", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        file_type = "org",
        journal = {
          directory = dir .. "/journal",
          keyword = "journal",
          title_format = "%Y-%m-%d Journal",
        },
        mappings = { enabled = false },
      })

      local path1, created1 = journal.new_or_existing_entry({ date = "2026-11-23", open = false, save = true })
      eq(true, created1)
      eq({ "journal" }, naming.parse_filename(path1).keywords)
      ok(path1:find("/journal/20261123T", 1, true) ~= nil)

      -- Second call for same date reuses existing entry
      local path2, created2 = journal.new_or_existing_entry({ date = "2026-11-23", open = false, save = true })
      eq(false, created2)
      eq(path1, path2)

      -- Link to journal entry from an Org buffer
      vim.cmd("enew!")
      vim.bo.filetype = "org"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
      journal.link_or_create_entry({ date = "2026-11-23" })
      local id = naming.retrieve_identifier(path1)
      ok(vim.api.nvim_get_current_line():find("denote:" .. id, 1, true) ~= nil)
    end)
  end)
end)

describe("denote.journal intervals", function()
  local function ts(y, m, d, H, Mi, S)
    return os.time({ year = y, month = m, day = d, hour = H or 12, min = Mi or 0, sec = S or 0 })
  end
  local function ymd(t)
    return os.date("%Y-%m-%d %H:%M:%S", t)
  end
  local function bounds(t, iv, ws)
    local a, b = journal.period_bounds(t, iv, ws)
    return { ymd(a), ymd(b) }
  end

  it("computes daily, monthly and yearly period bounds", function()
    eq({ "2026-11-24 00:00:00", "2026-11-24 23:59:59" }, bounds(ts(2026, 11, 24), "daily"))
    eq({ "2026-12-01 00:00:00", "2026-12-31 23:59:59" }, bounds(ts(2026, 12, 15), "monthly"))
    eq({ "2028-02-01 00:00:00", "2028-02-29 23:59:59" }, bounds(ts(2028, 2, 10), "monthly"))
    eq({ "2027-02-01 00:00:00", "2027-02-28 23:59:59" }, bounds(ts(2027, 2, 10), "monthly"))
    eq({ "2026-01-01 00:00:00", "2026-12-31 23:59:59" }, bounds(ts(2026, 7, 4), "yearly"))
  end)

  it("computes ISO (Monday) weeks, including weeks spanning months and years", function()
    -- Tue 2026-11-24 -> Mon 23 .. Sun 29
    eq({ "2026-11-23 00:00:00", "2026-11-29 23:59:59" }, bounds(ts(2026, 11, 24), "weekly", 1))
    -- Sunday belongs to the week that started the previous Monday
    eq({ "2026-11-23 00:00:00", "2026-11-29 23:59:59" }, bounds(ts(2026, 11, 29, 23, 59, 0), "weekly", 1))
    -- Week spanning months: Thu 2026-10-01 -> Mon 2026-09-28 .. Sun 2026-10-04
    eq({ "2026-09-28 00:00:00", "2026-10-04 23:59:59" }, bounds(ts(2026, 10, 1), "weekly", 1))
    -- Week spanning years: Fri 2027-01-01 -> Mon 2026-12-28 .. Sun 2027-01-03
    eq({ "2026-12-28 00:00:00", "2027-01-03 23:59:59" }, bounds(ts(2027, 1, 1), "weekly", 1))
    -- Sunday-start weeks
    eq({ "2026-11-22 00:00:00", "2026-11-28 23:59:59" }, bounds(ts(2026, 11, 24), "weekly", 0))
    eq({ "2026-11-29 00:00:00", "2026-12-05 23:59:59" }, bounds(ts(2026, 11, 29), "weekly", 0))
  end)

  it("computes ISO week numbers", function()
    eq({ 53, 2026 }, { journal.iso_week(ts(2027, 1, 1)) })
    eq({ 1, 2026 }, { journal.iso_week(ts(2025, 12, 29)) })
    eq({ 48, 2026 }, { journal.iso_week(ts(2026, 11, 24)) })
  end)

  it("uses per-interval default titles and honours title_format overrides", function()
    denote.setup({ journal = { interval = "weekly" }, mappings = { enabled = false } })
    eq("Week 48 2026", journal.format_title(ts(2026, 11, 24)))
    eq("November 2026", journal.format_title(ts(2026, 11, 24), "monthly"))
    eq("2026", journal.format_title(ts(2026, 11, 24), "yearly"))
    eq("Tuesday 24 November 2026", journal.format_title(ts(2026, 11, 24), "daily"))
    denote.setup({ journal = { title_format = { monthly = "Log %Y-%m" } }, mappings = { enabled = false } })
    eq("Log 2026-11", journal.format_title(ts(2026, 11, 24), "monthly"))
    eq("Week 48 2026", journal.format_title(ts(2026, 11, 24), "weekly"))
    denote.setup({ journal = { title_format = "%Y-%m-%d (%V) 100%%" }, mappings = { enabled = false } })
    eq("2026-11-24 (48) 100%", journal.format_title(ts(2026, 11, 24), "daily"))
  end)

  it("reuses the weekly entry for any day of the same ISO week", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        file_type = "org",
        journal = { directory = dir .. "/journal", interval = "weekly" },
        mappings = { enabled = false },
      })
      local p1, c1 = journal.new_or_existing_entry({ date = "2026-09-29", open = false, save = true })
      eq(true, c1)
      ok(p1:find("week%-40%-2026") ~= nil, p1)
      local p2, c2 = journal.new_or_existing_entry({ date = "2026-10-04", open = false, save = true })
      eq(false, c2)
      eq(p1, p2)
      local p3, c3 = journal.new_or_existing_entry({ date = "2026-10-05", open = false, save = true })
      eq(true, c3)
      ok(p3 ~= p1)
      -- journal_new always creates
      local meta = journal.new_entry({ date = "2026-09-30", open = false, save = true })
      ok(meta.path ~= p1)
      eq(2, #journal.find_for_period(ts(2026, 10, 1)))
    end)
  end)

  it("reuses the monthly entry and ignores notes without the journal keyword", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        file_type = "org",
        journal = { directory = dir, interval = "monthly" },
        mappings = { enabled = false },
      })
      -- A non-journal note in the same month must not be picked up
      local f = assert(io.open(dir .. "/20261102T090000--other__misc.org", "w"))
      f:write("#+title: other\n")
      f:close()
      require("denote.files").invalidate()
      local p1, c1 = journal.new_or_existing_entry({ date = "2026-11-24", open = false, save = true })
      eq(true, c1)
      ok(p1:find("november%-2026") ~= nil, p1)
      local p2, c2 = journal.new_or_existing_entry({ date = "2026-11-01", open = false, save = true })
      eq(false, c2)
      eq(p1, p2)
      local _, c3 = journal.new_or_existing_entry({ date = "2026-12-01", open = false, save = true })
      eq(true, c3)
      eq({ "20261124" }, vim.tbl_keys(journal.entries_by_date({ year = 2026, month = 11 })))
    end)
  end)
end)
