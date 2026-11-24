local denote = require("denote")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local utils = require("denote.utils")

describe("denote.create", function()
  it("creates Markdown and Org notes with templates and subdirectories", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        file_type = "markdown-yaml",
        templates = {
          meeting = "## Attendees\n\n- \n\n## Notes\n",
        },
        mappings = { enabled = false },
      })

      local m1 = denote.create_sync({
        title = "Weekly Sync",
        keywords = { "work", "meeting" },
        date = "2026-11-23 10:00:00",
        subdirectory = "projects/alpha",
        template = "meeting",
        open = false,
      })

      ok(utils.is_file(m1.path))
      eq("20261123T100000--weekly-sync__meeting_work.md", vim.fn.fnamemodify(m1.path, ":t"))
      ok(m1.path:find("projects/alpha/", 1, true) ~= nil)
      local content = utils.read_file(m1.path)
      ok(content:find("## Attendees", 1, true) ~= nil)
      eq("Weekly Sync", frontmatter.extract_title(m1.path))

      -- Org note with signature
      local m2 = denote.create_sync({
        title = "Org Architecture",
        keywords = { "org", "neovim" },
        file_type = "org",
        signature = "1a",
        date = "2026-11-23 10:00:00", -- same second -> collision avoidance bumps to 10:00:01
        open = false,
      })
      eq("20261123T100001", m2.identifier)
      eq("20261123T100001==1a--org-architecture__neovim_org.org", vim.fn.fnamemodify(m2.path, ":t"))
      local fm = frontmatter.parse_file(m2.path)
      eq("org", fm.file_type)
      eq("Org Architecture", fm.title)
      eq("1a", fm.signature)
    end)
  end)

  it("wraps code buffers when creating a note from a region", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        file_type = "org",
        mappings = { enabled = false },
      })
      vim.cmd("enew!")
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].filetype = "lua"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "local x = 1",
        "return x + 1",
      })

      local meta = denote.region({
        line1 = 1,
        line2 = 2,
        title = "Lua Snippet",
        keywords = { "lua" },
        interactive = false,
        open = false,
      })
      local raw = utils.read_file(meta.path)
      ok(raw:find("#%+begin_src lua\nlocal x = 1\nreturn x %+ 1\n#%+end_src") ~= nil)
      eq("20", naming.retrieve_identifier(meta.path):sub(1, 2))
    end)
  end)
end)
