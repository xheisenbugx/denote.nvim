local capture = require("denote.capture")
local denote = require("denote")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local utils = require("denote.utils")

--- Replace vim.ui.input with a stub answering from `answers` (by prompt text) and recording calls.
local function stub_input(answers)
  local orig = vim.ui.input
  local calls = {}
  vim.ui.input = function(o, cb)
    calls[#calls + 1] = o
    local key = o.prompt:gsub(": $", "")
    local a = answers[key]
    if a == nil then
      a = o.default
    end
    cb(a)
  end
  return calls, function()
    vim.ui.input = orig
  end
end

local function setup(dir, extra)
  denote.setup(vim.tbl_deep_extend("force", {
    directory = dir,
    file_type = "markdown-yaml",
    mappings = { enabled = false },
  }, extra or {}))
end

describe("denote.capture expansion", function()
  it("expands simple escapes", function()
    local ts = os.time({ year = 2026, month = 11, day = 24, hour = 16, min = 30 })
    local day = os.date("%a", ts)
    local ctx = {
      date = ts,
      region = "selected",
      clipboard = "clip",
      origin = { path = "/tmp/src/code.lua", lnum = 7 },
      syntax = "markdown",
    }
    eq("selected|clip|code.lua|/tmp/src/code.lua|100%", (capture.expand_sync("%i|%x|%f|%F|100%%", ctx)))
    eq("<2026-11-24 " .. day .. ">", (capture.expand_sync("%t", ctx)))
    eq("<2026-11-24 " .. day .. " 16:30>", (capture.expand_sync("%T", ctx)))
    eq("[2026-11-24 " .. day .. "]", (capture.expand_sync("%u", ctx)))
    eq("[2026-11-24 " .. day .. " 16:30]", (capture.expand_sync("%U", ctx)))
    eq("/tmp/src/code.lua:7", (capture.expand_sync("%a", ctx)))
    eq("/tmp/src/code.lua:7", (capture.expand_sync("%l", ctx)))
    ctx.syntax = "org"
    eq("[[file:/tmp/src/code.lua::7]]", (capture.expand_sync("%a", ctx)))
    -- Unknown escapes are kept verbatim
    eq("50%z", (capture.expand_sync("50%z", ctx)))
  end)

  it("reads the clipboard registers for %x", function()
    local orig = vim.fn.getreg
    vim.fn.getreg = function(reg)
      return reg == '"' and "unnamed\n" or ""
    end
    local okr, text = pcall(capture.expand_sync, "%x", {})
    vim.fn.getreg = orig
    ok(okr, text)
    eq("unnamed", text)
  end)

  it("indents multi-line regions and drops empty escape-only lines", function()
    eq("- item\n  - a\n  - b", (capture.expand_sync("- item\n  %i", { region = "- a\n- b" })))
    eq("title\nend", (capture.expand_sync("title\n%i\n%x\nend", { clipboard = "" })))
  end)

  it("places the cursor at %? and removes it", function()
    local text, cursor = capture.expand_sync("ab\ncd%?ef", {})
    eq("ab\ncdef", text)
    eq(6, cursor)
    eq({ 2, 2 }, capture.offset_to_pos(text, cursor))
    local t2, c2 = capture.expand_sync("%l\n%i\n%?", { region = "R" })
    eq("R\n", t2)
    eq(3, c2)
  end)

  it("links back to a Denote origin with a denote: link", function()
    with_temp_dir(function(dir)
      setup(dir)
      local src = denote.create_sync({ title = "Source", keywords = { "x" }, open = false, save = true })
      local ctx = { origin = { path = src.path, lnum = 3 }, syntax = "org" }
      eq("[[denote:" .. src.identifier .. "][Source]]", (capture.expand_sync("%a", ctx)))
      ctx.syntax = "markdown"
      eq("[Source](denote:" .. src.identifier .. ")", (capture.expand_sync("%l", ctx)))
    end)
  end)

  it("prompts with defaults, reuses repeated prompts and supports back-references", function()
    local calls, restore = stub_input({ Name = "Ada" })
    local result
    local okr, err = pcall(function()
      capture.expand("%^{Name} / %^{Role|admin} / %^{Name} / %\\2", {}, function(text)
        result = text
      end)
    end)
    restore()
    ok(okr, err)
    eq("Ada / admin / Ada / admin", result)
    eq(2, #calls)
    eq("admin", calls[2].default)
    -- Pre-supplied answers skip prompting entirely (synchronous path)
    eq("Bob / admin", (capture.expand_sync("%^{Name} / %^{Role|admin}", { answers = { Name = "Bob" } })))
  end)
end)

describe("denote.capture notes", function()
  it("expands escapes in config.templates and lands the cursor on %?", function()
    with_temp_dir(function(dir)
      setup(dir, {
        templates = {
          meeting = "## %^{Topic|General}\n\n%?\n\nDate: %u",
          fn = function(meta)
            return "Raw %? " .. meta.title
          end,
        },
      })
      local m = denote.create_sync({
        title = "Sync",
        keywords = { "work" },
        template = "meeting",
        context = { answers = { Topic = "Roadmap" } },
      })
      local lines = buf_lines(m.bufnr)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      eq("", lines[row])
      eq("## Roadmap", lines[row - 2])
      ok(lines[row + 2]:match("^Date: %[%d%d%d%d%-%d%d%-%d%d %a+%]$"), lines[row + 2])

      -- Function templates are left untouched
      local m2 = denote.create_sync({ title = "F", keywords = {}, template = "fn", open = false })
      ok(utils.read_file(m2.path):find("Raw %%%? F") ~= nil)
    end)
  end)

  it("asks template prompts during interactive note creation", function()
    with_temp_dir(function(dir)
      setup(dir, { templates = { t = "Who: %^{Who}" } })
      local _, restore = stub_input({ Who = "Grace" })
      local okr, m = pcall(denote.note, { title = "P", keywords = { "k" }, template = "t", open = false })
      restore()
      ok(okr, m)
      ok(utils.read_file(m.path):find("Who: Grace", 1, true) ~= nil)
    end)
  end)

  it("creates a note from a capture template with the region as %i", function()
    with_temp_dir(function(dir)
      setup(dir, {
        file_type = "org",
        capture = {
          templates = {
            {
              key = "m",
              description = "Meeting",
              title = "Meeting with %^{Who}",
              keywords = { "meeting" },
              subdirectory = "work",
              template = "* Notes\n%i\n%?\n* Source\n%a",
            },
          },
        },
      })
      local src = denote.create_sync({ title = "Origin", keywords = { "src" }, save = true })
      vim.api.nvim_buf_set_lines(src.bufnr, -1, -1, false, { "important line", "second" })
      local nlines = vim.api.nvim_buf_line_count(src.bufnr)

      local _, restore = stub_input({ Who = "Linus" })
      local okr, m = pcall(denote.capture, { key = "m", line1 = nlines - 1, line2 = nlines })
      restore()
      ok(okr, m)
      eq("20", m.identifier:sub(1, 2))
      ok(m.path:find("/work/", 1, true) ~= nil)
      eq("Meeting with Linus", frontmatter.parse_file(m.path).title)
      eq({ "meeting" }, naming.parse_filename(m.path).keywords)
      local lines = buf_lines(m.bufnr)
      local text = table.concat(lines, "\n")
      ok(text:find("* Notes\nimportant line\nsecond\n\n* Source\n", 1, true) ~= nil, text)
      ok(text:find("[[denote:" .. src.identifier .. "][Origin]]", 1, true) ~= nil, text)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      eq("second", lines[row - 1])
      eq("", lines[row])
    end)
  end)

  it("uses capture.specifiers when a template has no body", function()
    with_temp_dir(function(dir)
      setup(dir, { capture = { specifiers = "From: %f\n%i\n%?" } })
      vim.cmd("enew!")
      vim.api.nvim_buf_set_name(0, dir .. "/scratch.txt")
      local m = denote.capture({
        region = "hello",
        entry = { key = "q", title = "Quick", keywords = {} },
        open = false,
      })
      local raw = utils.read_file(m.path)
      ok(raw:find("From: scratch.txt\nhello\n\n$") ~= nil, raw)
    end)
  end)

  it("appends to an existing note and to today's journal", function()
    with_temp_dir(function(dir)
      setup(dir, {
        journal = { directory = dir .. "/journal" },
        capture = {
          templates = {
            { key = "a", target = { identifier = "20261124T100000" }, template = "- %^{Item} %?" },
            { key = "j", target = "journal", template = "* %^{Entry}\n%i" },
          },
        },
      })
      local target = denote.create_sync({
        title = "Inbox",
        keywords = { "inbox" },
        date = "2026-11-24 10:00:00",
        body = "existing",
        open = false,
      })
      eq("20261124T100000", target.identifier)

      local res = denote.capture({ key = "a", answers = { Item = "milk" }, interactive = false, open = false })
      ok(utils.read_file(target.path):find("existing\n\n%- milk \n$") ~= nil, utils.read_file(target.path))

      -- Opening the target places the cursor after the appended item
      res = denote.capture({ key = "a", answers = { Item = "eggs" }, interactive = false })
      local lines = buf_lines(res.bufnr)
      eq("- eggs ", lines[#lines])
      eq({ #lines, 7 }, res.cursor)
      eq(#lines, vim.api.nvim_win_get_cursor(0)[1])

      local _, restore = stub_input({ Entry = "Thought" })
      local okr, jr = pcall(denote.capture, { key = "j", region = "body", open = false })
      restore()
      ok(okr, jr)
      ok(jr.path:find("/journal/", 1, true) ~= nil)
      ok(utils.read_file(jr.path):find("\n%* Thought\nbody\n$") ~= nil, utils.read_file(jr.path))
    end)
  end)
end)
