local denote = require("denote")
local sequence = require("denote.sequence")

describe("denote.sequence", function()
  it("computes numeric parent, child, sibling signatures and relatives", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        sequence = { scheme = "numeric" },
        mappings = { enabled = false },
      })

      eq("1", sequence.next_parent(dir))
      local p1 = denote.create_sync({ title = "Root One", signature = "1", date = "2026-11-23 10:00:00", open = false })
      eq("2", sequence.next_parent(dir))
      eq("1=1", sequence.next_child("1", dir))

      local c1 =
        denote.create_sync({ title = "Child One", signature = "1=1", date = "2026-11-23 10:00:01", open = false })
      eq("1=2", sequence.next_child("1", dir))
      eq("1=2", sequence.next_sibling("1=1", dir))
      eq("1=1=1", sequence.next_child("1=1", dir))

      local c2 =
        denote.create_sync({ title = "Child Two", signature = "1=2", date = "2026-11-23 10:00:02", open = false })
      local g1 =
        denote.create_sync({ title = "Grandchild", signature = "1=1=1", date = "2026-11-23 10:00:03", open = false })

      local rel = sequence.relatives("1=1", dir)
      eq(p1.path, rel.parent)
      eq({ c2.path }, rel.siblings)
      eq({ g1.path }, rel.children)
      eq({ g1.path }, rel.descendants)
      eq(c1.signature, "1=1")
    end)
  end)

  it("supports alphanumeric Folgezettel sequences (1, 1a, 1b, 1a1)", function()
    with_temp_dir(function(dir)
      denote.setup({
        directory = dir,
        sequence = { scheme = "alphanumeric" },
        mappings = { enabled = false },
      })

      denote.create_sync({ title = "Root", signature = "1", date = "2026-11-23 11:00:00", open = false })
      eq("1a", sequence.next_child("1", dir))
      denote.create_sync({ title = "Branch A", signature = "1a", date = "2026-11-23 11:00:01", open = false })
      eq("1b", sequence.next_child("1", dir))
      eq("1b", sequence.next_sibling("1a", dir))
      eq("1a1", sequence.next_child("1a", dir))
      denote.create_sync({ title = "Sub 1", signature = "1a1", date = "2026-11-23 11:00:02", open = false })
      eq("1a2", sequence.next_child("1a", dir))
      eq("1a1a", sequence.next_child("1a1", dir))
    end)
  end)
end)
