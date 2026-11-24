local denote = require("denote")
local files = require("denote.files")
local config = require("denote.config")

--- External changes happen between event-loop iterations; the index validates once per tick.
local function tick()
  vim.wait(5)
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text or "")
  f:close()
end

describe("denote.files index", function()
  it("picks up files created, renamed, and deleted outside denote.nvim", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, mappings = { enabled = false } })
      local root = config.directory()
      eq(0, #files.list())

      write(root .. "/20261101T100000--first__a.md", "x")
      tick()
      eq(1, #files.list())

      write(root .. "/sub/20261101T110000--second__b.md", "x")
      tick()
      eq(2, #files.list())
      eq(root .. "/sub/20261101T110000--second__b.md", files.find_by_id("20261101T110000"))

      os.rename(root .. "/sub/20261101T110000--second__b.md", root .. "/sub/20261101T110000--renamed__b.md")
      tick()
      eq(root .. "/sub/20261101T110000--renamed__b.md", files.find_by_id("20261101T110000"))

      os.remove(root .. "/20261101T100000--first__a.md")
      tick()
      eq(nil, files.find_by_id("20261101T100000"))
      eq(1, #files.list())
    end)
  end)

  it("honours excluded directories and extra exclusion regexps", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, mappings = { enabled = false } })
      local root = config.directory()
      write(root .. "/.git/20261101T100000--ignored.md", "x")
      write(root .. "/archive/20261101T100001--old.md", "x")
      write(root .. "/20261101T100002--kept.md", "x")
      eq(2, #files.list())
      eq(1, #files.list({ excluded_dirs_regexp = "archive" }))
      eq(1, #files.list({ regexp = "kept" }))
      eq(1, #files.list({ not_regexp = "kept" }))
    end)
  end)

  it("resolves identifiers in silos and the journal directory", function()
    with_temp_dir(function(dir)
      local silo = dir .. "/silo"
      local journal = dir .. "/journal"
      write(dir .. "/notes/20261101T100000--main.md", "x")
      write(silo .. "/20261101T100001--silo-note.md", "x")
      write(journal .. "/20261101T100002--day__journal.md", "x")
      denote.setup({
        directory = dir .. "/notes",
        silos = { silo },
        journal = { directory = journal },
        mappings = { enabled = false },
      })
      ok(files.has_id("20261101T100000"))
      ok(files.has_id("20261101T100001"))
      ok(files.has_id("20261101T100002"))
      ok(not files.has_id("20261101T999999"))
      -- An explicit directory restricts the lookup
      eq(nil, files.find_by_id("20261101T100001", dir .. "/notes"))
    end)
  end)

  it("canonicalizes symlinked directories so paths compare equal to buffer names", function()
    with_temp_dir(function(dir)
      local real = dir .. "/real"
      vim.fn.mkdir(real, "p")
      local link = dir .. "/link"
      assert((vim.uv or vim.loop).fs_symlink(real, link))
      denote.setup({ directory = link, mappings = { enabled = false } })
      eq((vim.uv or vim.loop).fs_realpath(real), config.directory())
      -- Non-existent children keep their names on top of the resolved parent
      eq(config.directory() .. "/new/sub", config.canonicalize(link .. "/new/sub"))
    end)
  end)
end)
