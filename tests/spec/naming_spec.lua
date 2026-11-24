local config = require("denote.config")
local naming = require("denote.naming")

describe("denote.naming", function()
  before_each(function()
    config.setup({})
  end)

  it("sluggifies titles, signatures, and keywords", function()
    eq("my-first-note-about-emacs", naming.sluggify_title("My First Note! About Emacs?"))
    eq("hello-world", naming.sluggify_title("  Hello___World  "))
    eq("1=1=a", naming.sluggify_signature("1 1 a"))
    eq("1a2", naming.sluggify_signature("1a2"))
    eq("emacs", naming.sluggify_keyword("Emacs!"))
    eq("notetaking", naming.sluggify_keyword("note-taking"))
    eq({ "alpha", "beta", "gamma" }, naming.sluggify_keywords({ "Gamma", "alpha", "Beta", "alpha" }))
  end)

  it("desluggifies titles and signatures", function()
    eq("My first note", naming.desluggify("title", "my-first-note"))
    eq("1 2 a", naming.desluggify("signature", "1=2=a"))
  end)

  it("splits standard and compound extensions", function()
    local s1, e1 = naming.split_extension("20261123T191500--note.org")
    eq("20261123T191500--note", s1)
    eq(".org", e1)

    local s2, e2 = naming.split_extension("20261123T191500--secret.org.gpg")
    eq("20261123T191500--secret", s2)
    eq(".org.gpg", e2)

    local s3, e3 = naming.split_extension("20261123T191500--secret.md.age")
    eq("20261123T191500--secret", s3)
    eq(".md.age", e3)
  end)

  it("formats canonical Denote filenames", function()
    eq(
      "20261123T191500==1a--my-note__emacs_neovim.org",
      naming.format_filename({
        identifier = "20261123T191500",
        signature = "1a",
        title = "My Note!",
        keywords = { "neovim", "emacs" },
        extension = ".org",
      })
    )
    eq(
      "20261123T191500--just-title.md",
      naming.format_filename({
        identifier = "20261123T191500",
        title = "Just Title",
        extension = ".md",
      })
    )
    eq(
      "20261123T191500__paper_pdf.pdf",
      naming.format_filename({
        identifier = "20261123T191500",
        keywords = { "pdf", "paper" },
        extension = ".pdf",
      })
    )
  end)

  it("parses canonical and partial Denote filenames", function()
    local p = naming.parse_filename("/tmp/notes/20261123T191500==1=2--my-great-note__emacs_neovim.org")
    eq(true, p.is_denote)
    eq("20261123T191500", p.identifier)
    eq("1=2", p.signature)
    eq("my-great-note", p.title)
    eq({ "emacs", "neovim" }, p.keywords)
    eq(".org", p.extension)

    local p2 = naming.parse_filename("/tmp/notes/20261123T191500.pdf")
    eq(true, p2.is_denote)
    eq("20261123T191500", p2.identifier)
    eq(nil, p2.title)
    eq({}, p2.keywords)
    eq(".pdf", p2.extension)

    local p3 = naming.parse_filename("/tmp/notes/random-readme.md")
    eq(false, p3.is_denote)
    eq(nil, p3.identifier)
  end)

  it("supports reordered components with @@identifier (Denote 3.x/4.x)", function()
    config.setup({
      file_name_components_order = { "title", "keywords", "signature", "identifier" },
    })
    local fname = naming.format_filename({
      identifier = "20261123T191500",
      signature = "2b",
      title = "Reordered Note",
      keywords = { "lua" },
      extension = ".md",
    })
    eq("--reordered-note__lua==2b@@20261123T191500.md", fname)

    local parsed = naming.parse_filename(fname)
    eq(true, parsed.is_denote)
    eq("20261123T191500", parsed.identifier)
    eq("reordered-note", parsed.title)
    eq("2b", parsed.signature)
    eq({ "lua" }, parsed.keywords)
  end)

  it("generates collision-free identifiers", function()
    local ts = naming.identifier_to_time("20261123T191500")
    local used = {
      ["20261123T191500"] = true,
      ["20261123T191501"] = true,
    }
    eq("20261123T191502", naming.unique_identifier(ts, used))
  end)
end)
