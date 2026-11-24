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
