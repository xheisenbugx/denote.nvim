local denote = require("denote")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")
local sort = require("denote.sort")
local utils = require("denote.utils")

describe("denote 4.3.1 parity & visual bug regressions", function()
  it("inserts links AFTER cursor in Normal mode without splitting trailing words (Bug #1)", function()
    vim.cmd("enew!")
    vim.bo.filetype = "markdown"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Building on " })
    -- Normal mode cursor on the trailing space (0-based col 11)
    vim.api.nvim_win_set_cursor(0, { 1, 11 })
    links.insert_text("[Note](denote:20261118T091500)")
    eq("Building on [Note](denote:20261118T091500)", vim.api.nvim_get_current_line())

    -- Empty line still inserts at column 0
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    links.insert_text("[[denote:20261118T091500][Org]]")
    eq("[[denote:20261118T091500][Org]]", vim.api.nvim_get_current_line())
  end)

  it("returns empty statusline on non-file special buffers like Backlinks (Bug #3)", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local n1 = denote.create_sync({ title = "Alpha", keywords = { "a" }, date = "2026-11-23 10:00:00", open = false })
      local bl_buf = denote.backlinks({ file = n1.path })
      eq("", denote.statusline(bl_buf))
    end)
  end)

  it("supports identifier_delimiter_always_present (Denote 4.1.0)", function()
    denote.setup({ identifier_delimiter_always_present = true, mappings = { enabled = false } })
    local fname = naming.format_filename({
      identifier = "20261123T191500",
      title = "Prefixed ID",
      keywords = { "test" },
      extension = ".md",
    })
    eq("@@20261123T191500--prefixed-id__test.md", fname)
    local p = naming.parse_filename(fname)
    eq(true, p.is_denote)
    eq("20261123T191500", p.identifier)
    eq("prefixed-id", p.title)
  end)

  it("excludes keywords matching keywords_to_not_infer_pattern (Denote 4.2.0)", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        known_keywords = {},
        keywords_to_not_infer_pattern = "^private",
        mappings = { enabled = false },
      })
      denote.create_sync({
        title = "Secret",
        keywords = { "private", "public" },
        date = "2026-11-23 11:00:00",
        open = false,
      })
      eq({ "public" }, files.keywords(dir))
    end)
  end)

  it(
    "converts file type and front matter between Markdown and Org (denote-change-file-type-and-front-matter)",
    function()
      with_temp_dir(function(dir)
        denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
        local n = denote.create_sync({
          title = "Convertible Note",
          keywords = { "emacs", "neovim" },
          signature = "1a",
          date = "2026-11-23 12:00:00",
          body = "Important paragraph that must survive conversion.\n",
          open = true,
          save = true,
        })

        local org_path, err = denote.change_file_type_and_front_matter(n.path, "org")
        eq(nil, err)
        ok(org_path ~= nil)
        eq("20261123T120000==1a--convertible-note__emacs_neovim.org", vim.fn.fnamemodify(org_path, ":t"))
        eq(false, utils.exists(n.path))
        ok(utils.is_file(org_path))

        local fm = frontmatter.parse_file(org_path)
        ok(fm ~= nil)
        eq("org", fm.file_type)
        eq("Convertible Note", fm.title)
        eq({ "emacs", "neovim" }, fm.keywords)
        eq("1a", fm.signature)
        local raw = utils.read_file(org_path)
        ok(raw ~= nil and raw:find("Important paragraph that must survive conversion.", 1, true) ~= nil)
      end)
    end
  )

  it("fires after_new_note_hook and after_rename_file_hook", function()
    with_temp_dir(function(dir)
      local created_seen, renamed_seen = nil, nil
      denote.setup({
        directory = dir,
        mappings = { enabled = false },
        after_new_note_hook = function(path)
          created_seen = path
        end,
        after_rename_file_hook = function(new_path, old_path)
          renamed_seen = { old = old_path, new = new_path }
        end,
      })
      local n =
        denote.create_sync({ title = "Hook Note", keywords = { "h" }, date = "2026-11-23 13:00:00", open = false })
      eq(n.path, created_seen)

      local np = denote.rename_sync({ file = n.path, title = "Hook Renamed" })
      eq(n.path, renamed_seen.old)
      eq(np, renamed_seen.new)
    end)
  end)

  it("supports all rename_buffer_format specifiers (%D, %t, %T, %i, %s, %k, %b, prefix)", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        buffer_name_prefix = "[D] ",
        rename_buffer_format = "%D%b",
        rename_buffer_backlinks_indicator = " <-->",
        mappings = { enabled = false },
      })
      local target = denote.create_sync({
        title = "Hub Note",
        keywords = { "hub" },
        date = "2026-11-23 14:00:00",
        open = true,
        save = true,
      })
      eq("[D] Hub Note", denote.statusline(target.bufnr))

      denote.create_sync({
        title = "Referrer",
        keywords = { "ref" },
        date = "2026-11-23 14:05:00",
        body = "Link to [Hub](denote:" .. target.identifier .. ")\n",
        open = false,
      })
      eq("[D] Hub Note <-->", denote.statusline(target.bufnr))
    end)
  end)

  it("links to all files with matching contents and greps files referenced in a region", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local n1 = denote.create_sync({
        title = "Rust Note",
        keywords = { "rust" },
        date = "2026-11-23 15:00:00",
        body = "Borrow checker ensures memory safety.\n",
        open = false,
      })
      local n2 = denote.create_sync({
        title = "Lua Note",
        keywords = { "lua" },
        date = "2026-11-23 15:05:00",
        body = "LuaJIT is blazingly fast.\n",
        open = false,
      })

      local moc = denote.create_sync({
        title = "MOC",
        keywords = { "moc" },
        date = "2026-11-23 15:10:00",
        open = true,
        save = true,
      })
      local added = denote.link_to_all_files_with_contents("memory safety")
      eq(1, #added)
      ok(added[1]:find("denote:" .. n1.identifier, 1, true) ~= nil)

      -- Grep only files referenced in region (should find n1, NOT n2)
      local lc = vim.api.nvim_buf_line_count(0)
      local qbuf = denote.grep_files_referenced_in_region("safety", { line1 = 1, line2 = lc, bufnr = moc.bufnr })
      ok(qbuf ~= nil and vim.api.nvim_buf_is_valid(qbuf))
      local qtext = table.concat(buf_lines(qbuf), "\n")
      ok(qtext:find("Rust Note", 1, true) ~= nil)
      eq(nil, qtext:find("Lua Note", 1, true))
      eq("20261123T150500", n2.identifier)
    end)
  end)

  it("supports last-modified and random sort components", function()
    local input = {
      "/notes/20261123T100001--a.md",
      "/notes/20261123T100002--b.md",
      "/notes/20261123T100003--c.md",
    }
    local rand = sort.sort_files(input, "random")
    eq(3, #rand)
    ok(vim.tbl_contains(sort.COMPONENTS, "last-modified"))
    ok(vim.tbl_contains(sort.COMPONENTS, "random"))
  end)
end)
