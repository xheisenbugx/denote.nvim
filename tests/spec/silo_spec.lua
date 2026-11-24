local config = require("denote.config")
local denote = require("denote")
local files = require("denote.files")
local silo = require("denote.silo")
local utils = require("denote.utils")

describe("denote.silo", function()
  it("isolates notes across silos and detects .denote.json overrides", function()
    with_temp_dir(function(dir)
      local main_dir = dir .. "/main"
      local work_dir = dir .. "/work"
      utils.ensure_dir(main_dir)
      utils.ensure_dir(work_dir)
      utils.write_file(work_dir .. "/.denote.json", vim.json.encode({ file_type = "org" }))

      denote.setup({
        directory = main_dir,
        file_type = "markdown-yaml",
        silos = { work_dir },
        mappings = { enabled = false },
      })

      denote.create_sync({ title = "Personal Note", keywords = { "home" }, date = "2026-11-23 08:00:00", open = false })

      -- Inside work silo, .denote.json overrides file_type to org
      silo.with_silo(work_dir, function()
        eq("org", config.opts.file_type)
        denote.create_sync({ title = "Work Note", keywords = { "work" }, date = "2026-11-23 08:05:00", open = false })
      end)

      -- Primary config restored
      eq("markdown-yaml", config.opts.file_type)
      eq(1, #files.list({ dir = main_dir }))
      eq(1, #files.list({ dir = work_dir }))

      -- Detect silo from a file inside work_dir
      local detected_dir, detected_opts = silo.detect(work_dir .. "/some-file.org")
      eq(utils.normalize(work_dir), detected_dir)
      eq("org", detected_opts.file_type)
    end)
  end)
end)
