local denote = require("denote")
local links = require("denote.links")

describe("denote.links", function()
  it("formats links accurately for Org, Markdown, Wiki, and Plain Text", function()
    denote.setup({ markdown_link_style = "denote", mappings = { enabled = false } })

    eq("[[denote:20261123T191500][My Note]]", links.format_link("20261123T191500", "My Note", { syntax = "org" }))
    eq(
      "[[denote:20261123T191500]]",
      links.format_link("20261123T191500", "My Note", { syntax = "org", id_only = true })
    )
    eq("[My Note](denote:20261123T191500)", links.format_link("20261123T191500", "My Note", { syntax = "markdown" }))
    eq("[[denote:20261123T191500][My Note]]", links.format_link("20261123T191500", "My Note", { syntax = "text" }))

    denote.setup({ markdown_link_style = "wiki", mappings = { enabled = false } })
    eq("[[denote:20261123T191500|My Note]]", links.format_link("20261123T191500", "My Note", { syntax = "markdown" }))
  end)

  it("parses Org, Markdown, Wiki, Plain, heading, and query links on a line", function()
    local line =
      "See [[denote:20261123T191500::#intro][Org Ref]] and [MD Ref](denote:20261123T191501) and [[denote:query-contents:emacs][Search]]"
    local parsed = links.parse_line(line, 1)
    eq(3, #parsed)

    eq("id", parsed[1].kind)
    eq("20261123T191500", parsed[1].identifier)
    eq("#intro", parsed[1].search)
    eq("Org Ref", parsed[1].description)
    eq("org", parsed[1].syntax)

    eq("id", parsed[2].kind)
    eq("20261123T191501", parsed[2].identifier)
    eq("MD Ref", parsed[2].description)
    eq("markdown", parsed[2].syntax)

    eq("query-contents", parsed[3].kind)
    eq("emacs", parsed[3].query)
    eq("Search", parsed[3].description)
  end)

  it("follows direct ID links and heading links in Org and Markdown", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "org", mappings = { enabled = false } })
      local target = denote.create_sync({
        title = "Target Note",
        keywords = { "ref" },
        date = "2026-11-23 16:00:00",
        body = "* First\nHello\n* Second\n:PROPERTIES:\n:CUSTOM_ID: sec-two\n:END:\nTarget line.\n",
        open = false,
      })

      local ok_follow = links.follow_target(target.identifier .. "::#sec-two")
      eq(true, ok_follow)
      eq(target.path, require("denote.utils").normalize(vim.api.nvim_buf_get_name(0)))
      local cur_line = vim.api.nvim_get_current_line()
      eq("* Second", cur_line)
    end)
  end)

  it("inserts matching links via add_links and converts between denote: and file paths", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local n1 =
        denote.create_sync({ title = "Alpha", keywords = { "topic" }, date = "2026-11-23 17:00:00", open = false })
      local n2 =
        denote.create_sync({ title = "Beta", keywords = { "topic" }, date = "2026-11-23 17:00:05", open = false })
      local idx = denote.create_sync({
        title = "Index",
        keywords = { "moc" },
        date = "2026-11-23 17:01:00",
        open = true,
        save = true,
      })

      local inserted = denote.add_links("_topic")
      eq(2, #inserted)
      eq("[Alpha](denote:" .. n1.identifier .. ")", inserted[1]:sub(3))
      eq("[Beta](denote:" .. n2.identifier .. ")", inserted[2]:sub(3))

      -- Convert denote: links -> relative file paths
      local c1 = denote.convert_links_to_file_paths()
      eq(2, c1)
      local text_after = table.concat(buf_lines(), "\n")
      ok(text_after:find("20261123T170000--alpha__topic.md", 1, true) ~= nil)

      -- Convert relative file paths -> denote: links
      local c2 = denote.convert_links_to_denote_paths()
      eq(2, c2)
      local text_restored = table.concat(buf_lines(), "\n")
      ok(text_restored:find("denote:" .. n1.identifier, 1, true) ~= nil)
      eq(idx.path, require("denote.utils").normalize(vim.api.nvim_buf_get_name(0)))
    end)
  end)
end)
