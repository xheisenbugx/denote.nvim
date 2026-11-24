local denote = require("denote")
local org_int = require("denote.integrations.org")
local utils = require("denote.utils")

describe("denote.integrations.org", function()
  it("renders denote-links, denote-backlinks, and denote-files Org dynamic blocks", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "org", mappings = { enabled = false } })

      local n1 = denote.create_sync({
        title = "First Org Note",
        keywords = { "emacs" },
        date = "2026-11-23 20:00:00",
        body = "* Section One\nContent from first note.\n",
        open = false,
      })
      local n2 = denote.create_sync({
        title = "Second Org Note",
        keywords = { "emacs" },
        date = "2026-11-23 20:05:00",
        body = "Links back to [[denote:" .. n1.identifier .. "][First Org Note]].\n",
        open = false,
      })

      -- Test denote-links & denote-files in a metanote buffer
      vim.cmd("enew!")
      vim.bo.filetype = "org"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "#+title: Metanote",
        "",
        '#+BEGIN: denote-links :regexp "_emacs" :sort-by-component title',
        "#+END:",
        "",
        '#+BEGIN: denote-files :regexp "_emacs" :no-front-matter t :add-links t',
        "#+END:",
      })

      local count = denote.org_dblock_update()
      eq(2, count)
      local text = table.concat(buf_lines(), "\n")
      ok(text:find("- %[%[denote:" .. n1.identifier .. "%]%[First Org Note%]%]") ~= nil)
      ok(text:find("- %[%[denote:" .. n2.identifier .. "%]%[Second Org Note%]%]") ~= nil)
      ok(text:find("Content from first note.", 1, true) ~= nil)

      -- Test denote-backlinks inside n1
      utils.open_file(n1.path, "edit")
      local lc = vim.api.nvim_buf_line_count(0)
      vim.api.nvim_buf_set_lines(0, lc, lc, false, { "#+BEGIN: denote-backlinks", "#+END:" })
      denote.org_dblock_update()
      local n1_text = table.concat(buf_lines(), "\n")
      ok(n1_text:find("- %[%[denote:" .. n2.identifier .. "%]%[Second Org Note%]%]") ~= nil)
    end)
  end)

  it("exports denote: links for org.nvim HTML, Markdown, LaTeX, and Org backends", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "org", mappings = { enabled = false } })
      local n1 = denote.create_sync({
        title = "Export Target",
        keywords = { "pub" },
        date = "2026-11-23 21:00:00",
        open = false,
      })
      local info = { input_file = dir .. "/index.org" }

      eq(
        '<a href="20261123T210000--export-target__pub.html">Export Target</a>',
        org_int.export_link(n1.identifier, "Export Target", "html", info)
      )
      eq(
        "[Export Target](20261123T210000--export-target__pub.md)",
        org_int.export_link(n1.identifier, "Export Target", "markdown", info)
      )
      eq(
        "\\href{20261123T210000--export-target__pub.pdf}{Export Target}",
        org_int.export_link(n1.identifier, "Export Target", "latex", info)
      )
      eq(
        "[[denote:" .. n1.identifier .. "][Export Target]]",
        org_int.export_link(n1.identifier, "Export Target", "org", info)
      )
    end)
  end)

  it("registers denote: link type and dynamic blocks into org.nvim when present", function()
    -- Mock org.nvim modules in package.loaded to verify live hook wiring
    local dblock_writers = {}
    local mock_org_config = { opts = { links = { types = {} } } }
    local mock_org_dblock = {
      register = function(name, fn)
        dblock_writers[name] = fn
      end,
    }
    package.loaded["org.config"] = mock_org_config
    package.loaded["org.dblock"] = mock_org_dblock

    local attached = org_int.attach()
    eq(true, attached)
    ok(type(mock_org_config.opts.links.types.denote.follow) == "function")
    ok(type(mock_org_config.opts.links.types.denote.store) == "function")
    ok(type(mock_org_config.opts.links.types.denote.export) == "function")
    eq("DenoteLink", mock_org_config.opts.links.types.denote.face)
    ok(type(dblock_writers["denote-links"]) == "function")
    ok(type(dblock_writers["denote-backlinks"]) == "function")
    ok(type(dblock_writers["denote-files"]) == "function")

    package.loaded["org.config"] = nil
    package.loaded["org.dblock"] = nil
  end)
end)
