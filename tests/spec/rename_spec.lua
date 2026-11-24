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
end)
