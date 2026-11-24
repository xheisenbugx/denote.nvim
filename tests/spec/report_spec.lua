local denote = require("denote")
local report = require("denote.report")
local ui = require("denote.ui")
local preview = require("denote.preview")

describe("denote.report", function()
  it("finds unlinked mentions and converts one into a link", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local target = denote.create_sync({ title = "Zettelkasten", date = "2026-11-01 10:00:00", open = false })
      local mentioner = denote.create_sync({
        title = "Reading",
        date = "2026-11-01 10:01:00",
        body = "I like the zettelkasten method.\nAlready linked: [Z](denote:"
          .. target.identifier
          .. ") zettelkasten\n",
        open = false,
      })
      local found = report.unlinked_mentions({ file = target.path, sync = true })
      eq(1, #found)
      eq(mentioner.path, found[1].file)

      vim.cmd("edit " .. vim.fn.fnameescape(mentioner.path))
      vim.api.nvim_win_set_cursor(0, { found[1].lnum, 0 })
      ok(report.link_mention())
      eq("I like the [zettelkasten](denote:" .. target.identifier .. ") method.", vim.api.nvim_get_current_line())
    end)
  end)

  it("reports broken links and orphan notes", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local a = denote.create_sync({ title = "A", date = "2026-11-01 10:00:00", open = false })
      local b = denote.create_sync({
        title = "B",
        date = "2026-11-01 10:01:00",
        body = "[A](denote:" .. a.identifier .. ") and [gone](denote:20200101T000000)\n",
        open = false,
      })
      local r = report.check({ quickfix = false })
      eq(1, #r.broken)
      eq("20200101T000000", r.broken[1].identifier)
      eq(b.path, r.broken[1].file)
      eq({ b.path }, r.orphans)

      local async_report
      report.check({ quickfix = true }, function(res)
        async_report = res
      end)
      vim.wait(3000, function()
        return async_report ~= nil
      end, 10)
      eq(1, #async_report.broken)
      local qf = vim.fn.getqflist()
      eq(2, #qf)
      vim.cmd("cclose")
    end)
  end)
end)

describe("denote.ui diagnostics", function()
  it("reports broken links as diagnostics but resolves journal and silo notes", function()
    with_temp_dir(function(dir)
      local journal = dir .. "/journal"
      vim.fn.mkdir(journal, "p")
      local f = assert(io.open(journal .. "/20261101T090000--day__journal.md", "w"))
      f:write("x")
      f:close()
      denote.setup({
        directory = dir .. "/notes",
        journal = { directory = journal },
        file_type = "markdown-yaml",
        mappings = { enabled = false },
      })
      local note = denote.create_sync({
        title = "Links",
        body = "[ok](denote:20261101T090000)\n[bad](denote:20200101T000000)\n",
        open = true,
        save = true,
      })
      vim.bo[note.bufnr].filetype = "markdown"
      ui.decorate_buffer(note.bufnr)
      local diags = vim.diagnostic.get(note.bufnr, { namespace = vim.api.nvim_create_namespace("denote_broken_links") })
      eq(1, #diags)
      ok(diags[1].message:find("20200101T000000", 1, true) ~= nil)

      denote.setup({
        directory = dir .. "/notes",
        journal = { directory = journal },
        ui = { diagnostics = false },
        mappings = { enabled = false },
      })
      ui.decorate_buffer(note.bufnr)
      eq(0, #vim.diagnostic.get(note.bufnr, { namespace = vim.api.nvim_create_namespace("denote_broken_links") }))
    end)
  end)
end)

describe("denote.preview", function()
  it("previews the linked note body, starting at a linked heading", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local target = denote.create_sync({
        title = "Preview Me",
        keywords = { "demo" },
        body = "Intro line.\n\n## Details\nDeep content.\n",
        open = false,
      })
      local lines = preview.build(target.path)
      eq("Preview Me", lines[1])
      ok(lines[2]:find(target.identifier, 1, true) ~= nil)
      ok(lines[2]:find("_demo", 1, true) ~= nil)
      eq("Intro line.", lines[4])

      local from_heading = preview.build(target.path, "#details")
      eq("## Details", from_heading[4])

      vim.cmd("enew!")
      vim.bo.filetype = "markdown"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "[P](denote:" .. target.identifier .. ")" })
      vim.api.nvim_win_set_cursor(0, { 1, 2 })
      local win = preview.open()
      ok(win and vim.api.nvim_win_is_valid(win))
      local pbuf = vim.api.nvim_win_get_buf(win)
      eq("Preview Me", vim.api.nvim_buf_get_lines(pbuf, 0, 1, false)[1])
      preview.close()
      ok(not vim.api.nvim_win_is_valid(win))
    end)
  end)
end)
