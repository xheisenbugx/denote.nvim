local denote = require("denote")
local query = require("denote.query")

describe("denote.query", function()
  it("searches contents across notes and inserts query links", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      denote.create_sync({
        title = "Quantum Note",
        keywords = { "physics" },
        date = "2026-11-23 19:00:00",
        body = "Entanglement is a fundamental quantum phenomenon.\n",
        open = false,
      })
      denote.create_sync({
        title = "Cooking Note",
        keywords = { "food" },
        date = "2026-11-23 19:01:00",
        body = "Boil pasta for 8 minutes.\n",
        open = false,
      })

      local matches = query.search_contents("Entanglement")
      eq(1, #matches)
      ok(matches[1].text:find("Entanglement", 1, true) ~= nil)

      local buf = wait_loaded(denote.grep("Entanglement"))
      ok(vim.api.nvim_buf_is_valid(buf))
      local text = table.concat(buf_lines(buf), "\n")
      ok(text:find("Quantum Note", 1, true) ~= nil)

      -- Query links insertion (Markdown and Org)
      vim.cmd("enew!")
      vim.bo.filetype = "org"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
      denote.query_contents_link("Entanglement", "Physics refs")
      eq("[[denote:query-contents:Entanglement][Physics refs]]", vim.api.nvim_get_current_line())

      vim.cmd("enew!")
      vim.bo.filetype = "markdown"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
      denote.query_filenames_link("_physics", "All physics files")
      eq("[All physics files](denote:query-filenames:_physics)", vim.api.nvim_get_current_line())
    end)
  end)
end)
