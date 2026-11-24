local config = require("denote.config")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")

describe("denote.frontmatter", function()
  before_each(function()
    config.setup({})
  end)

  it("formats and parses Org front matter", function()
    local ts = naming.identifier_to_time("20261123T191500")
    local fm = frontmatter.format({
      title = "Org Note",
      date = ts,
      keywords = { "neovim", "emacs" },
      identifier = "20261123T191500",
      signature = "1a",
      file_type = "org",
    })
    ok(fm:find("#%+title:%s+Org Note") ~= nil)
    ok(fm:find("#%+filetags:%s+:emacs:neovim:") ~= nil)
    ok(fm:find("#%+identifier:%s+20261123T191500") ~= nil)
    ok(fm:find("#%+signature:%s+1a") ~= nil)

    local parsed = frontmatter.parse_lines(vim.split(fm, "\n", { plain = true }), "org")
    eq(true, parsed.has_front_matter)
    eq("Org Note", parsed.title)
    eq({ "emacs", "neovim" }, parsed.keywords)
    eq("20261123T191500", parsed.identifier)
    eq("1a", parsed.signature)
  end)

  it("formats and parses Markdown YAML front matter (inline and block tags)", function()
    local ts = naming.identifier_to_time("20261123T191500")
    local fm = frontmatter.format({
      title = 'Markdown "Quoted" Note',
      date = ts,
      keywords = { "lua", "notes" },
      identifier = "20261123T191500",
      file_type = "markdown-yaml",
    })
    ok(fm:find("^%-%-%-\n") ~= nil)
    local parsed = frontmatter.parse_lines(vim.split(fm, "\n", { plain = true }), "markdown-yaml")
    eq(true, parsed.has_front_matter)
    eq('Markdown "Quoted" Note', parsed.title)
    eq({ "lua", "notes" }, parsed.keywords)
    eq("20261123T191500", parsed.identifier)

    -- Block-style YAML list tags
    local block_lines = {
      "---",
      'title: "Block Tags"',
      "tags:",
      "  - alpha",
      "  - beta",
      'identifier: "20261123T191500"',
      "---",
      "",
      "Body text",
    }
    local p2 = frontmatter.parse_lines(block_lines, "markdown-yaml")
    eq({ "alpha", "beta" }, p2.keywords)
    eq("Block Tags", p2.title)
  end)

  it("formats and parses Markdown TOML front matter", function()
    local ts = naming.identifier_to_time("20261123T191500")
    local fm = frontmatter.format({
      title = "TOML Note",
      date = ts,
      keywords = { "hugo" },
      identifier = "20261123T191500",
      file_type = "markdown-toml",
    })
    ok(fm:find("^%+%+%+\n") ~= nil)
    local parsed = frontmatter.parse_lines(vim.split(fm, "\n", { plain = true }), "markdown-toml")
    eq(true, parsed.has_front_matter)
    eq("TOML Note", parsed.title)
    eq({ "hugo" }, parsed.keywords)
    eq("20261123T191500", parsed.identifier)
  end)

  it("formats and parses Plain Text front matter", function()
    local ts = naming.identifier_to_time("20261123T191500")
    local fm = frontmatter.format({
      title = "Plain Note",
      date = ts,
      keywords = { "journal", "text" },
      identifier = "20261123T191500",
      file_type = "text",
    })
    ok(fm:find("%-%-%-%-%-") ~= nil)
    local parsed = frontmatter.parse_lines(vim.split(fm, "\n", { plain = true }), "text")
    eq(true, parsed.has_front_matter)
    eq("Plain Note", parsed.title)
    eq({ "journal", "text" }, parsed.keywords)
    eq("20261123T191500", parsed.identifier)
  end)

  it("rewrites front matter in place while preserving extra user fields", function()
    local lines = {
      "---",
      'title:      "Old Title"',
      "author:     Osvaldo",
      'tags:       ["old"]',
      'identifier: "20261123T191500"',
      "draft:      true",
      "---",
      "",
      "Hello body.",
    }
    local updated, changed = frontmatter.rewrite_lines(lines, "markdown-yaml", {
      title = "New Title",
      keywords = { "neovim", "denote" },
      signature = "1b",
    })
    eq(true, changed)
    local parsed = frontmatter.parse_lines(updated, "markdown-yaml")
    eq("New Title", parsed.title)
    eq({ "denote", "neovim" }, parsed.keywords)
    eq("1b", parsed.signature)
    -- Preserved custom fields and body
    local joined = table.concat(updated, "\n")
    ok(joined:find("author:     Osvaldo", 1, true) ~= nil)
    ok(joined:find("draft:      true", 1, true) ~= nil)
    ok(joined:find("Hello body.", 1, true) ~= nil)
  end)

  it("extracts headings from Org (with :CUSTOM_ID:) and Markdown files", function()
    with_temp_dir(function(dir)
      local org_path = dir .. "/20261123T191500--org-doc.org"
      require("denote.utils").write_lines(org_path, {
        "#+title: Org Doc",
        "",
        "* Introduction :tag:",
        ":PROPERTIES:",
        ":CUSTOM_ID: intro-sec",
        ":END:",
        "Some text.",
        "** Details",
      })
      local oh = frontmatter.extract_headings(org_path)
      eq(2, #oh)
      eq("Introduction", oh[1].text)
      eq("intro-sec", oh[1].custom_id)
      eq(3, oh[1].lnum)
      eq("Details", oh[2].text)
      eq(2, oh[2].level)

      local md_path = dir .. "/20261123T191501--md-doc.md"
      require("denote.utils").write_lines(md_path, {
        "---",
        'title: "MD Doc"',
        "---",
        "# Top Heading",
        "```lua",
        "# not a heading",
        "```",
        "## Second Section",
      })
      local mh = frontmatter.extract_headings(md_path)
      eq(2, #mh)
      eq("Top Heading", mh[1].text)
      eq("top-heading", mh[1].slug)
      eq("Second Section", mh[2].text)
      eq("second-section", mh[2].slug)
    end)
  end)
end)
