local denote = require("denote")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local utils = require("denote.utils")

describe("denote.rename", function()
  it("renames a Denote note and updates its front matter", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local meta = denote.create_sync({
        title = "Initial Title",
        keywords = { "draft" },
        date = "2026-11-23 12:00:00",
        open = true,
        save = true,
      })

      local new_path, err = denote.rename_sync({
        file = meta.path,
        title = "Final Polished Title",
        keywords = { "published", "lua" },
        signature = "2a",
      })
      eq(nil, err)
      ok(utils.is_file(new_path))
      eq(false, utils.exists(meta.path))
      eq("20261123T120000==2a--final-polished-title__lua_published.md", vim.fn.fnamemodify(new_path, ":t"))

      local fm = frontmatter.parse_file(new_path)
      eq("Final Polished Title", fm.title)
      eq({ "lua", "published" }, fm.keywords)
      eq("2a", fm.signature)
    end)
  end)

  it("syncs filename from edited front matter (Org and Markdown)", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "org", mappings = { enabled = false } })
      local meta = denote.create_sync({
        title = "Before Edit",
        keywords = { "old" },
        date = "2026-11-23 13:00:00",
        open = false,
      })

      -- Simulate user editing Org front matter directly
      utils.write_lines(meta.path, {
        "#+title:      After Direct Edit",
        "#+date:       [2026-11-23 Mon 13:00]",
        "#+filetags:   :emacs:org:",
        "#+identifier: 20261123T130000",
        "#+signature:  3=1",
        "",
        "Body",
      })

      local synced, err = denote.rename_file_using_front_matter(meta.path)
      eq(nil, err)
      eq("20261123T130000==3=1--after-direct-edit__emacs_org.org", vim.fn.fnamemodify(synced, ":t"))
      ok(utils.is_file(synced))
    end)
  end)

  it("renames non-Denote arbitrary files (e.g. PDFs) and adds/removes keywords", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, mappings = { enabled = false } })
      local pdf = dir .. "/paper.pdf"
      utils.write_file(pdf, "%PDF-1.4 mock")

      local renamed, err = denote.rename_sync({
        file = pdf,
        title = "Lambda Calculus",
        keywords = { "cs", "paper" },
        date = "2026-11-23 14:00:00",
      })
      eq(nil, err)
      eq("20261123T140000--lambda-calculus__cs_paper.pdf", vim.fn.fnamemodify(renamed, ":t"))

      local added = denote.keywords_add({ "pl" }, renamed)
      eq({ "cs", "paper", "pl" }, naming.parse_filename(added).keywords)

      local removed = denote.keywords_remove({ "paper" }, added)
      eq({ "cs", "pl" }, naming.parse_filename(removed).keywords)
    end)
  end)

  it("adds front matter to plain notes that lack it", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, mappings = { enabled = false } })
      local note = dir .. "/20261123T150000--raw-note__idea.md"
      utils.write_lines(note, { "Just some body text." })

      local changed, err = denote.add_front_matter(note)
      eq(nil, err)
      eq(true, changed)
      local fm = frontmatter.parse_file(note)
      eq(true, fm.has_front_matter)
      eq("Raw note", fm.title)
      eq({ "idea" }, fm.keywords)
      eq("20261123T150000", fm.identifier)
    end)
  end)

  it("preserves full note content and allows normal :write after renaming loaded buffers", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "org", mappings = { enabled = false } })
      local meta = denote.create_sync({
        title = "Something",
        keywords = { "neovim", "org" },
        date = "2026-11-24 10:58:45",
        open = true,
        save = true,
      })
      local buf = meta.bufnr
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "* Heading", "Important body text!", "Second line." })
      vim.cmd("silent write")

      local new_path, err = denote.rename_sync({
        file = meta.path,
        title = "Renamed Something",
        keywords = { "neovim", "org" },
      })
      eq(nil, err)
      eq(false, utils.exists(meta.path))
      ok(utils.is_file(new_path))

      -- Both buffer and disk keep full body content
      local disk = utils.read_lines(new_path)
      local joined = table.concat(disk, "\n")
      ok(joined:find("#+title:      Renamed Something", 1, true) ~= nil)
      ok(joined:find("Important body text!", 1, true) ~= nil)
      ok(joined:find("Second line.", 1, true) ~= nil)
      eq(disk, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

      -- Subsequent normal :write succeeds without E13 / overwrite prompt
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Third line after rename." })
      local ok_w, werr = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent write")
      end)
      eq(true, ok_w)
      eq(nil, werr)
      ok(table.concat(utils.read_lines(new_path), "\n"):find("Third line after rename.", 1, true) ~= nil)
    end)
  end)

  it("supports case-only renames when preserve_case is enabled and safe path normalization", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "org", preserve_case = true, mappings = { enabled = false } })
      local meta = denote.create_sync({
        title = "myNote",
        keywords = { "org" },
        date = "2026-11-24 11:00:00",
        open = true,
        save = true,
      })
      vim.api.nvim_buf_set_lines(meta.bufnr, -1, -1, false, { "* Keep me" })
      vim.cmd("silent write")

      local new_path, err = denote.rename_sync({
        file = meta.path,
        title = "MyNote",
        keywords = { "org" },
      })
      eq(nil, err)
      eq("20261124T110000--MyNote__org.org", vim.fn.fnamemodify(new_path, ":t"))
      ok(table.concat(utils.read_lines(new_path), "\n"):find("* Keep me", 1, true) ~= nil)

      -- Path normalization must not expand %, #, or glob brackets
      eq("/tmp/foo#bar%1[2].org", utils.normalize("/tmp/foo#bar%1[2].org"))

      -- Plain .txt file with a horizontal rule and no key: value header has no front matter
      local parsed_txt = frontmatter.parse_lines({ "Just a paragraph", "----------", "More text" }, "text")
      eq(false, parsed_txt.has_front_matter)
    end)
  end)
end)
