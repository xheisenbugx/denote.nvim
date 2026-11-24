local backlinks = require("denote.backlinks")
local denote = require("denote")

describe("denote.backlinks", function()
  it("finds backlinks across Markdown and Org notes and opens interactive buffer", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local target = denote.create_sync({
        title = "Core Concept",
        keywords = { "concept" },
        date = "2026-11-23 18:00:00",
        open = false,
      })
      local md_linker = denote.create_sync({
        title = "MD Note",
        keywords = { "md" },
        date = "2026-11-23 18:01:00",
        body = "See [Core Concept](denote:" .. target.identifier .. ") for details.\n",
        open = false,
      })
      local org_linker = denote.create_sync({
        title = "Org Note",
        keywords = { "org" },
        file_type = "org",
        date = "2026-11-23 18:02:00",
        body = "* Related\nCheck [[denote:" .. target.identifier .. "][Core Concept]].\n",
        open = false,
      })

      local matches = backlinks.find(target.identifier, { exclude_file = target.path })
      eq(2, #matches)
      local files = backlinks.files_for(target.identifier, { exclude_file = target.path })
      eq({ md_linker.path, org_linker.path }, files)

      local buf = denote.backlinks({ file = target.path })
      ok(vim.api.nvim_buf_is_valid(buf))
      local joined = table.concat(buf_lines(buf), "\n")
      ok(joined:find("MD Note", 1, true) ~= nil)
      ok(joined:find("Org Note", 1, true) ~= nil)
    end)
  end)
end)
