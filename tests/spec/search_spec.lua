local denote = require("denote")
local search = require("denote.search")
local query = require("denote.query")
local backlinks = require("denote.backlinks")

local has_rg = vim.fn.executable("rg") == 1
local backends = has_rg and { true, false } or { false }

local function setup(dir, use_rg)
  denote.setup({
    directory = dir,
    file_type = "markdown-yaml",
    mappings = { enabled = false },
    search = { ripgrep = use_rg },
  })
  search.reset()
end

for _, use_rg in ipairs(backends) do
  local label = use_rg and "ripgrep" or "pure Lua"

  describe("denote.search (" .. label .. ")", function()
    it("returns an empty result (not a slow rescan) when nothing matches", function()
      with_temp_dir(function(dir)
        setup(dir, use_rg)
        eq(use_rg, search.use_ripgrep())
        denote.create_sync({ title = "Alpha", keywords = { "a" }, body = "nothing here\n", open = false })
        eq({}, query.search_contents("definitely-not-present"))
      end)
    end)

    it("uses smart case and the same regex operators in both backends", function()
      with_temp_dir(function(dir)
        setup(dir, use_rg)
        denote.create_sync({ title = "One", body = "Apple pie\nbanana split\n", open = false })
        eq(2, #query.search_contents("apple|banana"))
        eq(1, #query.search_contents("Apple"))
        eq(0, #query.search_contents("APPLE"))
        eq(1, #query.search_contents("(ban)+ana"))
      end)
    end)

    it("finds notes inside ignored and hidden directories", function()
      with_temp_dir(function(dir)
        setup(dir, use_rg)
        local root = require("denote.config").directory()
        vim.fn.mkdir(root .. "/.hidden", "p")
        local f = assert(io.open(root .. "/.ignore", "w"))
        f:write("*.md\n")
        f:close()
        local note = denote.create_sync({ title = "Secret", body = "needle\n", open = false, subdirectory = ".hidden" })
        ok(note.path:find("/.hidden/", 1, true) ~= nil, "note should live in the hidden directory")
        local matches = query.search_contents("needle")
        eq(1, #matches)
        eq(note.path, matches[1].file)
      end)
    end)

    it("searches unsaved buffer contents instead of the file on disk", function()
      with_temp_dir(function(dir)
        setup(dir, use_rg)
        local note = denote.create_sync({ title = "Draft", body = "old text\n", open = true, save = true })
        vim.api.nvim_buf_set_lines(note.bufnr, -1, -1, false, { "fresh unsaved words" })
        eq(1, #query.search_contents("fresh unsaved"))
        eq(true, vim.bo[note.bufnr].modified)
      end)
    end)

    it("finds backlinks synchronously and asynchronously, skipping front matter", function()
      with_temp_dir(function(dir)
        setup(dir, use_rg)
        local target = denote.create_sync({ title = "Target", date = "2026-11-01 10:00:00", open = false })
        denote.create_sync({
          title = "Linker",
          date = "2026-11-01 10:01:00",
          body = "See [T](denote:" .. target.identifier .. ")\n",
          open = false,
        })
        local sync = backlinks.find(target.identifier, { exclude_file = target.path })
        eq(1, #sync)

        local async_result
        backlinks.find(target.identifier, { exclude_file = target.path }, function(m)
          async_result = m
        end)
        vim.wait(3000, function()
          return async_result ~= nil
        end, 10)
        eq(sync, async_result)
      end)
    end)
  end)
end
