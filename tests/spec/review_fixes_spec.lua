local backlinks = require("denote.backlinks")
local capture = require("denote.capture")
local config = require("denote.config")
local denote = require("denote")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local journal = require("denote.journal")
local links = require("denote.links")
local mappings = require("denote.mappings")
local naming = require("denote.naming")
local org_int = require("denote.integrations.org")
local preview = require("denote.preview")
local report = require("denote.report")
local search = require("denote.search")
local sequence = require("denote.sequence")
local silo = require("denote.silo")
local ui = require("denote.ui")
local utils = require("denote.utils")

local uv = vim.uv or vim.loop

describe("review fixes and improvements", function()
  it("gates .denote.lua behind vim.secure.read, switches silo overrides, and supports silos_auto_detect", function()
    with_temp_dir(function(dir)
      local main_dir = dir .. "/main"
      local lua_silo = dir .. "/lua_silo"
      local json_silo = dir .. "/json_silo"
      utils.ensure_dir(main_dir)
      utils.ensure_dir(lua_silo)
      utils.ensure_dir(json_silo .. "/sub")
      utils.write_file(lua_silo .. "/.denote.lua", 'return { file_type = "org" }\n')
      utils.write_file(json_silo .. "/.denote.json", vim.json.encode({ file_type = "org", directory = "sub" }))

      denote.setup({
        directory = main_dir,
        file_type = "markdown-yaml",
        silos = { lua_silo, json_silo },
        silos_auto_detect = true,
        mappings = { enabled = false },
      })

      -- Untrusted .denote.lua is ignored safely
      local det_dir, det_opts = silo.detect(lua_silo .. "/note.org")
      eq(utils.normalize(lua_silo), det_dir)
      eq({}, det_opts)

      -- Once trusted via vim.secure.trust, .denote.lua overrides take effect
      local lua_path = lua_silo .. "/.denote.lua"
      local ok_trust = pcall(vim.secure.trust, { path = lua_path, action = "allow" })
      if ok_trust then
        local td, topts = silo.detect(lua_silo .. "/note.org")
        eq(utils.normalize(lua_silo), td)
        eq("org", topts.file_type)
        pcall(vim.secure.trust, { path = lua_path, action = "remove" })
      end

      -- silo.switch applies .denote.json relative directory & overrides and resets cleanly
      silo.switch(json_silo)
      eq(config.canonicalize(json_silo .. "/sub"), config.directory())
      eq("org", config.opts.file_type)
      silo.switch(nil)
      eq(config.canonicalize(main_dir), config.directory())
      eq("markdown-yaml", config.opts.file_type)

      -- silos_auto_detect scopes config.directory() to current buffer's silo
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, json_silo .. "/sub/test.org")
      vim.api.nvim_win_set_buf(0, buf)
      eq(config.canonicalize(json_silo .. "/sub"), config.directory())
    end)
  end)

  it("keeps preview float <CR> across BufEnter and switches when previewing a new link", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local t1 = denote.create_sync({
        title = "First Target",
        date = "2026-11-20 10:00:00",
        body = "Body 1\n\n## Deep Section\nReached.\n",
        open = false,
      })
      local t2 = denote.create_sync({
        title = "Second Target",
        date = "2026-11-20 10:05:00",
        body = "Body 2\n",
        open = false,
      })
      local src = denote.create_sync({
        title = "Source",
        date = "2026-11-20 10:10:00",
        body = string.format("[One](denote:%s::#deep-section) and [Two](denote:%s)\n", t1.identifier, t2.identifier),
        open = true,
        save = true,
      })
      vim.bo[src.bufnr].filetype = "markdown"
      local lnum = vim.api.nvim_buf_line_count(src.bufnr)
      vim.api.nvim_win_set_cursor(0, { lnum, 2 })

      local w1 = preview.open()
      ok(w1 and vim.api.nvim_win_is_valid(w1))
      -- Focusing preview (BufEnter) must not replace preview <CR> with follow_link
      local w1_focus = preview.open()
      eq(w1, w1_focus)
      eq(w1, vim.api.nvim_get_current_win())
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      eq(t1.path, utils.normalize(vim.api.nvim_buf_get_name(0)))
      eq("## Deep Section", vim.api.nvim_get_current_line())

      -- Opening preview on another link replaces stale preview instead of focusing old one
      vim.api.nvim_win_set_buf(0, src.bufnr)
      local line = vim.api.nvim_buf_get_lines(src.bufnr, lnum - 1, lnum, false)[1]
      local second_col = assert(line:find("[Two]", 1, true))
      vim.api.nvim_win_set_cursor(0, { lnum, second_col })
      local w2 = preview.open()
      ok(w2 and vim.api.nvim_win_is_valid(w2))
      local p2 = vim.api.nvim_win_get_buf(w2)
      eq("Second Target", vim.api.nvim_buf_get_lines(p2, 0, 1, false)[1])
      preview.close()
    end)
  end)

  it("preserves prior buffer mappings on fallback without double-wrapping", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local called = 0
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(0, buf)
      vim.bo[buf].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain text line" })
      vim.keymap.set("n", "<CR>", function()
        called = called + 1
      end, { buffer = buf, desc = "User CR" })

      mappings.attach_buffer(buf)
      mappings.attach_buffer(buf) -- idempotent
      vim.api.nvim_win_set_cursor(0, { 1, 2 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      eq(1, called)
    end)
  end)

  it("matches denote: prefixes in cmp keyword pattern and avoids doubling autopaired closers in blink/cmp", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      local note = denote.create_sync({ title = "Alpha Note", keywords = { "lua" }, open = false })
      local cmp_src = require("denote.integrations.cmp").new()
      local re = vim.regex(cmp_src:get_keyword_pattern())
      ok(re:match_str("denote:2026alpha-1") ~= nil)

      local blink_src = require("denote.integrations.blink").new()
      local out_items
      blink_src:get_completions({
        line = "[link](denote:alp)",
        cursor = { 1, 17 },
        bufnr = vim.api.nvim_get_current_buf(),
      }, function(res)
        out_items = res.items
      end)
      eq(1, #out_items)
      eq("denote:" .. note.identifier .. ")", out_items[1].textEdit.newText)
      -- Range covers existing autopaired `)` so it isn't doubled
      eq(18, out_items[1].textEdit.range["end"].character)
    end)
  end)

  it("handles symlinked subdirs, .git exclusion, word boundaries, and smart-case escapes in search", function()
    with_temp_dir(function(dir)
      local real_sub = dir .. "/external_notes"
      local notes_root = dir .. "/notes"
      utils.ensure_dir(real_sub)
      utils.ensure_dir(notes_root .. "/.git")
      assert(uv.fs_symlink(real_sub, notes_root .. "/linked"))

      local ext_note = real_sub .. "/20261120T120000--external__sym.md"
      utils.write_lines(ext_note, {
        "---",
        'title: "External"',
        "---",
        "Go programming language and going somewhere.",
      })
      utils.write_lines(notes_root .. "/.git/20261120T120100--gitobj.md", { "Go inside git" })

      local backends = vim.fn.executable("rg") == 1 and { true, false } or { false }
      local orig_max = search.MAX_EXPLICIT_FILES
      search.MAX_EXPLICIT_FILES = 1 -- force root-directory rg path
      local ok_run, err = pcall(function()
        for _, use_rg in ipairs(backends) do
          denote.setup({ directory = notes_root, mappings = { enabled = false }, search = { ripgrep = use_rg } })
          search.reset()

          -- Symlinked subdir included, .git excluded
          local all_list = files.list()
          eq(1, #all_list)

          local word_hits = search.run({
            pattern = "Go",
            fixed = true,
            word = true,
            case = "insensitive",
            files = all_list,
            root = config.directory(),
          })
          eq(1, #word_hits)

          local smart_hits = search.run({
            pattern = "programming\\s+language",
            case = "smart",
            files = all_list,
            root = config.directory(),
          })
          eq(1, #smart_hits)
        end
      end)
      search.MAX_EXPLICIT_FILES = orig_max
      ok(ok_run, err)
    end)
  end)

  it("survives symlink cycles and resolves symlinked subdirs & invalidation in files.lua", function()
    with_temp_dir(function(dir)
      local sub = dir .. "/sub"
      utils.ensure_dir(sub)
      utils.write_file(sub .. "/20261120T130000--one.md", "hi")
      assert(uv.fs_symlink(dir, sub .. "/loop"))

      local link_root = dir .. "/root_link"
      assert(uv.fs_symlink(dir, link_root))
      denote.setup({ directory = link_root, mappings = { enabled = false } })

      local list = files.list()
      eq(1, #list)
      local subdirs = files.subdirectories()
      ok(#subdirs >= 1)

      utils.write_file(sub .. "/20261120T130500--two.md", "hi2")
      files.invalidate(link_root)
      eq(2, #files.list())
    end)
  end)

  it("supports free-form @@ IDs, excluded_punctuation_pattern in signatures, and UTF-8 desluggify", function()
    denote.setup({ excluded_punctuation_pattern = "[!]", mappings = { enabled = false } })
    local parsed = naming.parse_filename("@@custom-id--free-form-title__tag.md")
    eq("custom-id", parsed.identifier)
    eq("free-form-title", parsed.title)
    eq(
      "@@custom-id--free-form-title__tag.md",
      naming.format_filename({
        identifier = "custom-id",
        title = "Free Form Title",
        keywords = { "tag" },
        extension = ".md",
      })
    )
    eq("a=b=?c", naming.sluggify_signature("a=b! ?c-"))
    eq("École normale", naming.desluggify("title", "école-normale"))
  end)

  it(
    "handles Org underscore keywords, multiline TOML tags, YAML comments, rename_date, code blocks, and custom hooks",
    function()
      with_temp_dir(function(dir)
        denote.setup({
          directory = dir,
          file_type = "org",
          mappings = { enabled = false },
          file_types = {
            custom = {
              extension = ".custom",
              front_matter = function(m)
                return string.format("TITLE=%s\nID=%s\n\n", m.title, m.identifier)
              end,
              parse = function(lines)
                local title, id
                for i, l in ipairs(lines) do
                  title = title or l:match("^TITLE=(.+)$")
                  id = id or l:match("^ID=(.+)$")
                  if l == "" then
                    return {
                      title = title,
                      identifier = id,
                      keywords = {},
                      file_type = "custom",
                      start_line = 1,
                      end_line = i - 1,
                      has_front_matter = title ~= nil,
                    }
                  end
                end
                return { has_front_matter = false, file_type = "custom", start_line = 0, end_line = 0 }
              end,
              rewrite = function(lines, updates)
                local out = vim.deepcopy(lines)
                local changed = false
                for i, l in ipairs(out) do
                  if updates.title and l:match("^TITLE=") and l ~= "TITLE=" .. updates.title then
                    out[i] = "TITLE=" .. updates.title
                    changed = true
                  end
                end
                return out, changed
              end,
            },
          },
        })

        -- Org underscore keyword + src block heading exclusion
        local org_path = dir .. "/20261120T140000--org-test__a.org"
        utils.write_lines(org_path, {
          "#+title: Org Test",
          "#+export_file_name: out.html",
          "#+identifier: 20261120T140000",
          "#+filetags: :a:",
          "",
          "#+begin_src org",
          "* Fake Heading Inside Src",
          "#+end_src",
          "* Real Heading",
        })
        local fm_org = frontmatter.parse_file(org_path)
        eq("20261120T140000", fm_org.identifier)
        local oh = frontmatter.extract_headings(org_path)
        eq(1, #oh)
        eq("Real Heading", oh[1].text)

        -- Multiline TOML tags + rewrite
        local toml_lines = {
          "+++",
          'title = "Toml Title" # comment',
          "tags = [",
          '  "alpha",',
          '  "beta" # trailing',
          "]",
          'identifier = "20261120T140100"',
          "+++",
          "",
          "Body",
        }
        local fm_toml = frontmatter.parse_lines(toml_lines, "markdown-toml")
        eq("Toml Title", fm_toml.title)
        eq({ "alpha", "beta" }, fm_toml.keywords)
        local rewritten_toml, changed_toml = frontmatter.rewrite_lines(toml_lines, "markdown-toml", {
          keywords = { "gamma" },
        })
        eq(true, changed_toml)
        eq({ "gamma" }, frontmatter.parse_lines(rewritten_toml, "markdown-toml").keywords)
        eq(7, #rewritten_toml)
        eq("Body", rewritten_toml[7])

        -- YAML inline comments & empty title guard during rename
        local yaml_fm = frontmatter.parse_lines({
          "---",
          'title: "YAML # Kept" # inline comment',
          'tags: ["one", "two"] # comment',
          'identifier: "20261120T140200"',
          "---",
        }, "markdown-yaml")
        eq("YAML # Kept", yaml_fm.title)
        eq({ "one", "two" }, yaml_fm.keywords)

        -- rename_date updates front matter date:
        local n = denote.create_sync({
          title = "Dated Note",
          date = "2026-11-20 10:00:00",
          file_type = "markdown-yaml",
          open = false,
        })
        local renamed, rerr = denote.rename_sync({ file = n.path, date = "2026-11-21 12:30:00" })
        eq(nil, rerr)
        local fm_after = frontmatter.parse_file(renamed)
        ok(fm_after.date:find("^2026%-11%-21T12:30:00") ~= nil, fm_after.date)

        -- Custom parse/rewrite hooks
        local cn = denote.create_sync({ title = "Custom Init", file_type = "custom", open = false })
        eq("Custom Init", frontmatter.extract_title(cn.path))
        local cn2 = denote.rename_sync({ file = cn.path, title = "Custom Two" })
        eq("Custom Two", frontmatter.extract_title(cn2))

        -- create_sync honors save = false even when save_buffer_after_creation = true
        denote.setup({ directory = dir, save_buffer_after_creation = true, mappings = { enabled = false } })
        local unsaved = denote.create_sync({ title = "Unsaved Buffer", save = false, open = true })
        eq(false, utils.exists(unsaved.path))
        -- And a second note created in the same second avoids ID collision with open buffer
        local unsaved2 =
          denote.create_sync({ title = "Unsaved Second", date = unsaved.identifier, save = false, open = true })
        ok(unsaved.identifier ~= unsaved2.identifier)
      end)
    end
  )

  it("handles Markdown images, bare punctuation, relative links, and code-block diagnostics", function()
    with_temp_dir(function(dir)
      utils.ensure_dir(dir .. "/sub")
      denote.setup({
        directory = dir,
        file_type = "markdown-yaml",
        markdown_link_style = "relative",
        mappings = { enabled = false },
      })
      local target = denote.create_sync({
        title = "Sub Note",
        subdirectory = "sub",
        date = "2026-11-20 15:00:00",
        body = "## Section One\nContent.\n",
        open = false,
      })
      local host = denote.create_sync({
        title = "Host Note",
        date = "2026-11-20 15:05:00",
        open = true,
        save = true,
      })
      vim.bo[host.bufnr].filetype = "markdown"
      vim.api.nvim_buf_set_lines(host.bufnr, -1, -1, false, {
        "![Diagram](20261120T150000--diagram.png)",
        "[Rel](sub/20261120T150000--sub-note.md#section-one)",
        "See denote:" .. target.identifier .. ".",
        "```markdown",
        "[Ignored](denote:20200101T000000)",
        "```",
      })
      -- Image must NOT be rewritten; relative link converts to denote:ID::#anchor
      local converted = denote.convert_links_to_denote_paths(host.bufnr)
      eq(1, converted)
      local lines = buf_lines(host.bufnr)
      eq("![Diagram](20261120T150000--diagram.png)", lines[#lines - 5])
      eq("[Rel](denote:" .. target.identifier .. "::#section-one)", lines[#lines - 4])

      -- Bare link trims trailing period
      local bare = links.parse_line(lines[#lines - 3], 1)
      eq(1, #bare)
      eq(target.identifier, bare[1].identifier)

      -- Code block broken link is ignored by ui.broken_links
      eq(0, #ui.broken_links(lines, "markdown"))
    end)
  end)

  it(
    "supports cross-field capture backrefs, pipe in defaults, single-key dispatch, and word-bounded reports",
    function()
      with_temp_dir(function(dir)
        local jdir = dir .. "/journal"
        denote.setup({
          directory = dir,
          journal = { directory = jdir },
          file_type = "markdown-yaml",
          mappings = { enabled = false },
          capture = {
            templates = {
              {
                key = "m",
                description = "Meeting",
                title = "Meeting with %^{Who|Alice|Bob}",
                template = "Attendee: %\\1",
              },
              { key = "n", description = "Plain" },
            },
          },
        })

        -- Pipe inside default & cross-field backref
        local prompts = capture.prompts("%^{Choice|a|b}")
        eq("a|b", prompts[1].default)
        local m = denote.capture({ key = "m", answers = { Who = "Ada" }, interactive = false, open = false })
        ok(utils.read_file(m.path):find("Attendee: Ada", 1, true) ~= nil)

        -- Single-key dispatch float works when pressing template key
        local picked_key = nil
        capture.open_dispatch(capture.templates(), function(entry)
          picked_key = entry.key
        end)
        vim.api.nvim_feedkeys("n", "x", false)
        eq("n", picked_key)

        -- Report word-boundary & already-linked mention safety & journal backlink orphan check
        local go = denote.create_sync({ title = "Go", date = "2026-11-20 16:00:00", open = false })
        local doc = denote.create_sync({
          title = "Notes",
          date = "2026-11-20 16:05:00",
          body = "I am going to write [Go](denote:" .. go.identifier .. ") and Go code.\n",
          open = true,
          save = true,
        })
        local mentions = report.unlinked_mentions({ file = go.path, sync = true })
        eq(0, #mentions) -- line already contains go.identifier

        -- Put Go unlinked on another line, ensure already-linked span is skipped by link_mention
        vim.api.nvim_buf_set_lines(doc.bufnr, -1, -1, false, { "Learn [Go](https://go.dev) and Go today." })
        report.last_mention_target = { path = go.path, identifier = go.identifier, title = "Go" }
        vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(doc.bufnr), 0 })
        ok(report.link_mention())
        eq(
          "Learn [Go](https://go.dev) and [Go](denote:" .. go.identifier .. ") today.",
          vim.api.nvim_get_current_line()
        )

        -- Journal backlink clears orphan status in report.check()
        local alone = denote.create_sync({ title = "JournalLinked", date = "2026-11-20 16:10:00", open = false })
        journal.new_entry({ date = "2026-11-20", open = false, save = true })
        local jfiles = journal.entries()
        utils.write_lines(jfiles[1].path, { "See [JL](denote:" .. alone.identifier .. ")." })
        local chk = report.check({ quickfix = false })
        ok(not vim.tbl_contains(chk.orphans, alone.path))
      end)
    end
  )

  it("supports recursive sequence reparenting, org export escaping, atomic writes, and valid dates", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, sequence = { scheme = "numeric" }, mappings = { enabled = false } })
      denote.create_sync({ title = "P1", signature = "1", date = "2026-11-20 17:00:00", open = false })
      local c1 = denote.create_sync({ title = "C1", signature = "1=1", date = "2026-11-20 17:00:01", open = false })
      denote.create_sync({ title = "G1", signature = "1=1=1", date = "2026-11-20 17:00:02", open = false })
      denote.create_sync({ title = "P2", signature = "2", date = "2026-11-20 17:00:03", open = false })

      sequence.reparent({ file = c1.path, parent_signature = "2", dir = dir, recursive = true })
      local map = sequence.signature_map(dir)
      ok(map["2=1"] ~= nil)
      ok(map["2=1=1"] ~= nil)
      eq(nil, map["1=1"])
      eq(nil, map["1=1=1"])

      -- Org export escaping & markdown anchor preservation
      local exp_target = denote.create_sync({
        title = "Pub & Note",
        keywords = { "pub" },
        date = "2026-11-20 17:10:00",
        open = false,
      })
      local info = { input_file = dir .. "/index.org" }
      eq(
        '<a href="20261120T171000--pub-note__pub.html#sec">A &amp; &lt;B&gt;</a>',
        org_int.export_link(exp_target.identifier .. "::#sec", "A & <B>", "html", info)
      )
      eq(
        "\\href{20261120T171000--pub-note__pub.pdf}{A \\& B\\_C}",
        org_int.export_link(exp_target.identifier, "A & B_C", "latex", info)
      )
      eq(
        "[Sec](20261120T171000--pub-note__pub.md#sec)",
        org_int.export_link(exp_target.identifier .. "::#sec", "Sec", "markdown", info)
      )

      -- Date validation rejects impossible calendar dates
      local bad_ts, bad_err = utils.parse_date("2026-02-31")
      eq(nil, bad_ts)
      ok(bad_err ~= nil)
      local yest, yerr = utils.parse_date("yesterday")
      eq(nil, yerr)
      ok(yest ~= nil)

      -- Check health runs without error
      local ok_health = pcall(require("denote.health").check)
      eq(true, ok_health)
    end)
  end)
end)
