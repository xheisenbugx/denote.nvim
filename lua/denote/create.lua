---@mod denote.create Creating Denote notes (interactive prompts, templates, open-or-create, region)

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local pickers = require("denote.pickers")
local sort = require("denote.sort")
local utils = require("denote.utils")

local M = {}

---@class denote.CreateOpts
---@field title? string
---@field keywords? string[]|string
---@field file_type? string
---@field subdirectory? string Subdirectory relative to `dir` (or absolute path)
---@field date? string|integer Date string or Unix timestamp
---@field template? string Template key from `config.opts.templates`
---@field signature? string
---@field body? string Extra body text appended after front matter / template
---@field dir? string Explicit root directory override
---@field open? boolean Open the created note in Neovim (default: true)
---@field how? string Window open mode ("edit", "split", "vsplit", "tab")
---@field save? boolean Override `save_buffer_after_creation`
---@field prompts? string[] Override prompt sequence for interactive creation
---@field interactive? boolean When false, create synchronously without prompting
---@field on_created? fun(path: string, meta: table) Callback after note is created

--- Resolve a template entry into a string.
---@param template_name? string
---@param meta table
---@return string
local function resolve_template(template_name, meta)
  if not template_name or template_name == "" then
    return ""
  end
  local tmpl = (config.opts.templates or {})[template_name]
  if type(tmpl) == "function" then
    return tostring(tmpl(meta) or "")
  elseif type(tmpl) == "string" then
    return tmpl
  end
  return ""
end

--- Create a Denote note synchronously from resolved options (no prompts).
--- Writes the file to disk (or opens it in a buffer if `save == false` and `open == true`),
--- and returns `{ path, identifier, title, keywords, signature, file_type, date, bufnr }`.
---@param opts denote.CreateOpts
---@return table
function M.create_sync(opts)
  opts = opts or {}
  local root = config.directory(opts.dir)
  local target_dir = root
  if opts.subdirectory and opts.subdirectory ~= "" and opts.subdirectory ~= "." then
    if opts.subdirectory:sub(1, 1) == "/" or opts.subdirectory:sub(1, 1) == "~" then
      target_dir = utils.normalize(opts.subdirectory)
    else
      target_dir = utils.normalize(root .. "/" .. opts.subdirectory)
    end
  end
  utils.ensure_dir(target_dir)

  local ts, err = utils.parse_date(opts.date)
  if not ts then
    utils.warn(err or "Invalid date; using current time")
    ts = os.time()
  end

  local existing = files.identifier_set(root)
  local id = naming.unique_identifier(ts, existing)
  local _, ft = frontmatter.get_spec(opts.file_type)
  local ext = frontmatter.extension_for(ft)
  local title = opts.title or ""
  local kws = naming.sluggify_keywords(opts.keywords or {})
  local sig = naming.sluggify_signature(opts.signature or "")

  local filename = naming.format_filename({
    identifier = id,
    signature = sig,
    title = title,
    keywords = kws,
    extension = ext,
    sluggify = true,
  })
  local path = target_dir .. "/" .. filename

  local meta = {
    path = path,
    identifier = id,
    title = title,
    keywords = kws,
    signature = sig,
    file_type = ft,
    date = ts,
  }

  local fm = frontmatter.format(meta)
  local tmpl_body = resolve_template(opts.template, meta)
  local extra_body = opts.body or ""
  local content = fm
  if tmpl_body ~= "" then
    content = content .. tmpl_body
    if content:sub(-1) ~= "\n" then
      content = content .. "\n"
    end
  end
  if extra_body ~= "" then
    if tmpl_body ~= "" and content:sub(-2) ~= "\n\n" then
      content = content .. "\n"
    end
    content = content .. extra_body
    if content:sub(-1) ~= "\n" then
      content = content .. "\n"
    end
  end

  local should_open = opts.open ~= false
  local should_save = opts.save
  if should_save == nil then
    should_save = (not should_open) or config.opts.save_buffer_after_creation
  end

  if should_save then
    local ok_write, werr = utils.write_file(path, content)
    if not ok_write then
      utils.error("Failed to create note: " .. tostring(werr))
      return meta
    end
  end

  if should_open then
    local bufnr = utils.open_file(path, opts.how)
    meta.bufnr = bufnr
    if not should_save then
      local lines = vim.split(content, "\n", { plain = true })
      if #lines > 1 and lines[#lines] == "" then
        table.remove(lines)
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end
    -- Move cursor to end of file, ready to type
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_win_set_cursor(0, { line_count, 0 })
    if not should_save then
      -- Also write if user requested save_buffer_after_creation
      if config.opts.save_buffer_after_creation then
        vim.cmd("silent write")
      end
    end
  end

  if opts.on_created then
    opts.on_created(path, meta)
  end

  local hook = config.opts.after_new_note_hook
  if type(hook) == "function" then
    pcall(hook, path, meta)
  elseif type(hook) == "table" then
    for _, fn in ipairs(hook) do
      if type(fn) == "function" then
        pcall(fn, path, meta)
      end
    end
  end
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "DenoteNewNote", data = meta })

  return meta
end

--- Run a sequential chain of interactive prompts and call `done(collected)`.
---@param prompt_list string[]
---@param initial denote.CreateOpts
---@param done fun(collected: denote.CreateOpts)
local function run_prompts(prompt_list, initial, done)
  local state = vim.deepcopy(initial or {})
  local root = config.directory(state.dir)

  local function step(idx)
    if idx > #prompt_list then
      done(state)
      return
    end
    local p = prompt_list[idx]

    if p == "title" then
      if state.title ~= nil then
        step(idx + 1)
        return
      end
      vim.ui.input({ prompt = "Note title: ", default = state._initial_title or "" }, function(input)
        if input == nil then
          return
        end
        state.title = vim.trim(input)
        step(idx + 1)
      end)
    elseif p == "keywords" then
      if state.keywords ~= nil then
        step(idx + 1)
        return
      end
      local known = files.keywords(root)
      local hint = #known > 0 and (" (" .. table.concat(vim.list_slice(known, 1, 6), ", ") .. ")") or ""
      vim.ui.input({
        prompt = "Keywords (comma or space separated)" .. hint .. ": ",
        default = "",
      }, function(input)
        if input == nil then
          return
        end
        state.keywords = utils.parse_keywords_input(input)
        step(idx + 1)
      end)
    elseif p == "file_type" then
      if state.file_type ~= nil then
        step(idx + 1)
        return
      end
      local types = vim.tbl_keys(frontmatter.file_types())
      table.sort(types)
      local items = {}
      for _, ft in ipairs(types) do
        local ext = frontmatter.extension_for(ft)
        items[#items + 1] = {
          display = { { ft, "DenoteTitle" }, { " (" .. ext .. ")", "DenoteExtension" } },
          text = ft .. " " .. ext,
          value = ft,
        }
      end
      pickers.pick({
        title = "Select File Type",
        items = items,
        preview = false,
        on_choice = function(chosen)
          if chosen[1] then
            state.file_type = chosen[1].value
            step(idx + 1)
          end
        end,
      })
    elseif p == "subdirectory" then
      if state.subdirectory ~= nil then
        step(idx + 1)
        return
      end
      local dirs = files.subdirectories(root, true)
      local items = {}
      for _, d in ipairs(dirs) do
        local rel = utils.relpath(d, root)
        local label = rel == "" and ". (root)" or rel
        items[#items + 1] = {
          display = { { label, "DenoteTitle" } },
          text = label,
          value = rel == "" and "." or rel,
        }
      end
      pickers.pick({
        title = "Select Subdirectory",
        items = items,
        preview = false,
        allow_query = true,
        create_label = "+ New subdirectory...",
        on_choice = function(chosen, query)
          if chosen[1] then
            state.subdirectory = chosen[1].value
          elseif query and query ~= "" then
            state.subdirectory = vim.trim(query)
          else
            return
          end
          step(idx + 1)
        end,
      })
    elseif p == "date" then
      if state.date ~= nil then
        step(idx + 1)
        return
      end
      vim.ui.input({
        prompt = "Date (YYYY-MM-DD [HH:MM[:SS]], today, yesterday, -1d): ",
        default = tostring(os.date("%Y-%m-%d %H:%M")),
      }, function(input)
        if input == nil then
          return
        end
        state.date = vim.trim(input)
        step(idx + 1)
      end)
    elseif p == "template" then
      if state.template ~= nil then
        step(idx + 1)
        return
      end
      local names = vim.tbl_keys(config.opts.templates or {})
      table.sort(names)
      if #names == 0 then
        utils.warn("No templates configured in `denote.setup({ templates = { ... } })`")
        state.template = ""
        step(idx + 1)
        return
      end
      local items = {
        { display = { { "(none)", "Comment" } }, text = "none", value = "" },
      }
      for _, name in ipairs(names) do
        items[#items + 1] = {
          display = { { name, "DenoteTitle" } },
          text = name,
          value = name,
        }
      end
      pickers.pick({
        title = "Select Template",
        items = items,
        preview = false,
        on_choice = function(chosen)
          if chosen[1] then
            state.template = chosen[1].value
            step(idx + 1)
          end
        end,
      })
    elseif p == "signature" then
      if state.signature ~= nil then
        step(idx + 1)
        return
      end
      vim.ui.input({ prompt = "Signature (e.g. 1a, 1=2): ", default = "" }, function(input)
        if input == nil then
          return
        end
        state.signature = vim.trim(input)
        step(idx + 1)
      end)
    else
      step(idx + 1)
    end
  end

  step(1)
end

--- Primary note creation entry point (matching `M-x denote`).
--- If `opts.title` is supplied along with `opts.interactive == false` (or `opts.open == false`),
--- creates immediately without prompting; otherwise runs the configured `prompts` pipeline.
---@param opts? denote.CreateOpts
---@return table|nil
function M.note(opts)
  opts = opts or {}
  local silo_dir = opts._silo_dir
  local function finish(collected)
    if silo_dir then
      return require("denote.silo").with_silo(silo_dir, function()
        return M.create_sync(collected)
      end)
    end
    return M.create_sync(collected)
  end

  if opts.interactive == false or (opts.title ~= nil and opts.keywords ~= nil and not opts.prompts) then
    return finish(opts)
  end

  local prompt_list = opts.prompts
  if not prompt_list then
    if silo_dir then
      local _, local_opts = require("denote.silo").detect(silo_dir)
      prompt_list = (local_opts and local_opts.prompts) or config.opts.prompts or { "title", "keywords" }
    else
      prompt_list = config.opts.prompts or { "title", "keywords" }
    end
  end

  run_prompts(prompt_list, opts, function(collected)
    finish(collected)
  end)
end

--- Helper to ensure a specific prompt is included in the default prompt list.
---@param extra string
---@param opts? denote.CreateOpts
local function note_with_prompt(extra, opts)
  opts = vim.deepcopy(opts or {})
  local prompts = vim.deepcopy(opts.prompts or config.opts.prompts or { "title", "keywords" })
  if not vim.tbl_contains(prompts, extra) then
    table.insert(prompts, 1, extra)
  end
  opts.prompts = prompts
  return M.note(opts)
end

--- Create a note prompting for file type (`denote-type`).
---@param opts? denote.CreateOpts
function M.type(opts)
  return note_with_prompt("file_type", opts)
end

--- Create a note prompting for custom date (`denote-date`).
---@param opts? denote.CreateOpts
function M.date(opts)
  return note_with_prompt("date", opts)
end

--- Create a note prompting for subdirectory (`denote-subdirectory`).
---@param opts? denote.CreateOpts
function M.subdirectory(opts)
  return note_with_prompt("subdirectory", opts)
end

--- Create a note prompting for template (`denote-template`).
---@param opts? denote.CreateOpts
function M.template(opts)
  return note_with_prompt("template", opts)
end

--- Create a note prompting for signature (`denote-signature`).
---@param opts? denote.CreateOpts
function M.signature(opts)
  return note_with_prompt("signature", opts)
end

--- Open an existing Denote note, or create a new one if no match is selected
--- (`denote-open-or-create`).
---@param opts? { dir?: string, prompts?: string[] }
function M.open_or_create(opts)
  opts = opts or {}
  local root = config.directory(opts.dir)
  local all_files = sort.sort_files(files.list({ dir = root, denote_only = true }), "identifier", true)
  local items = {}
  for i, path in ipairs(all_files) do
    items[i] = pickers.file_item(path, { dir = root })
  end

  pickers.pick({
    title = "Denote Open or Create",
    items = items,
    allow_query = true,
    create_label = "+ Create new note...",
    on_choice = function(chosen, query, how)
      if chosen[1] then
        utils.open_file(chosen[1].value, how)
      else
        local create_opts = vim.deepcopy(opts)
        if query and vim.trim(query) ~= "" then
          create_opts._initial_title = vim.trim(query)
        end
        create_opts.how = how
        M.note(create_opts)
      end
    end,
  })
end

--- Open an existing note or choose which creation command to run (`denote-open-or-create-with-command`).
---@param opts? { dir?: string }
function M.open_or_create_with_command(opts)
  opts = opts or {}
  local commands = {
    { display = { { "note (default)", "DenoteTitle" } }, text = "note", value = "note" },
    { display = { { "type (choose file type)", "DenoteTitle" } }, text = "type", value = "type" },
    { display = { { "date (custom date)", "DenoteTitle" } }, text = "date", value = "date" },
    { display = { { "subdirectory", "DenoteTitle" } }, text = "subdirectory", value = "subdirectory" },
    { display = { { "template", "DenoteTitle" } }, text = "template", value = "template" },
    { display = { { "signature", "DenoteTitle" } }, text = "signature", value = "signature" },
  }
  pickers.pick({
    title = "Select Note Creation Command",
    items = commands,
    preview = false,
    on_choice = function(chosen)
      if not chosen[1] then
        return
      end
      local cmd = chosen[1].value
      local prompt_map = {
        note = config.opts.prompts or { "title", "keywords" },
        type = { "file_type", "title", "keywords" },
        date = { "date", "title", "keywords" },
        subdirectory = { "subdirectory", "title", "keywords" },
        template = { "template", "title", "keywords" },
        signature = { "signature", "title", "keywords" },
      }
      M.open_or_create(vim.tbl_extend("force", opts, { prompts = prompt_map[cmd] }))
    end,
  })
end

--- Create a new Denote note containing the current visual selection (`denote-region`).
--- If invoked from a code buffer, wraps the region in an Org `#+begin_src <lang>` or
--- Markdown fenced code block matching the target note's syntax.
---@param opts? denote.CreateOpts & { line1?: integer, line2?: integer }
function M.region(opts)
  opts = vim.deepcopy(opts or {})
  local bufnr = vim.api.nvim_get_current_buf()
  local src_ft = vim.bo[bufnr].filetype
  local line1 = opts.line1 or vim.fn.line("'<")
  local line2 = opts.line2 or vim.fn.line("'>")
  if line1 > line2 then
    line1, line2 = line2, line1
  end
  local selected = vim.api.nvim_buf_get_lines(bufnr, math.max(0, line1 - 1), line2, false)
  local raw_text = table.concat(selected, "\n")

  local is_prose = src_ft == "" or src_ft == "text" or src_ft == "markdown" or src_ft == "org"
  local _, target_ft = frontmatter.get_spec(opts.file_type)

  if not is_prose then
    if target_ft == "org" then
      opts.body = string.format("#+begin_src %s\n%s\n#+end_src\n", src_ft, raw_text)
    elseif target_ft == "markdown-yaml" or target_ft == "markdown-toml" then
      opts.body = string.format("```%s\n%s\n```\n", src_ft, raw_text)
    else
      opts.body = raw_text .. "\n"
    end
  else
    opts.body = raw_text .. "\n"
  end

  return M.note(opts)
end

return M
