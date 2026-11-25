---@mod denote.capture Capture templates (the Neovim analogue of `denote-org-capture`)
---
--- A small template expansion engine modelled on Org capture's template escapes, plus
--- `capture()` which creates a note (or appends to an existing one) from a capture template.
---
--- Supported escapes:
---   `%^{Prompt}`         prompt with `vim.ui.input` (same name -> same answer)
---   `%^{Prompt|default}` prompt with a default value
---   `%\N`                answer of the N-th distinct prompt (1-9)
---   `%i`                 region / selected text (multi-line text keeps the indentation of `%i`)
---   `%a` / `%l`          link back to the origin (Denote link for notes, `path:line` otherwise)
---   `%x`                 clipboard (`+` register, falling back to `"`)
---   `%f` / `%F`          origin file name / full path
---   `%t` / `%T`          active date / date-time, e.g. `<2026-11-24 Tue>` / `<2026-11-24 Tue 16:30>`
---   `%u` / `%U`          inactive date / date-time, e.g. `[2026-11-24 Tue]`
---   `%n`                 user name (`$USER`)
---   `%?`                 final cursor position (removed from the text)
---   `%%`                 a literal `%`
--- A line made only of escapes that all expand to nothing (e.g. `%i` without a region) is dropped.

local config = require("denote.config")
local utils = require("denote.utils")

local M = {}

--- Default extra content for capture templates (matches `denote-org-capture-specifiers`).
M.default_specifiers = "%l\n%i\n%?"

---@class denote.CaptureOrigin
---@field bufnr? integer
---@field path? string
---@field lnum? integer
---@field filetype? string

---@class denote.CaptureContext
---@field origin? denote.CaptureOrigin Where the capture was started from
---@field region? string Text for `%i`
---@field answers? table<string, string> Prompt answers keyed by prompt name (pre-supplied or collected)
---@field prompt_order? { name: string, default?: string }[] Prompt order shared across title/signature/body backreferences
---@field syntax? "org"|"markdown"|"text" Link syntax of the target note (for `%a`/`%l`)
---@field target_dir? string Directory of the target note (relative Markdown links)
---@field date? integer Unix timestamp for `%t`/`%T`/`%u`/`%U` (default: now)
---@field clipboard? string Override for `%x`

---@class denote.CaptureTemplate
---@field key string Key used by `:Denote capture <key>` and shown in the picker
---@field description? string
---@field template? string|fun(ctx: denote.CaptureContext): string Body (default: `capture.specifiers`)
---@field title? string|fun(ctx: denote.CaptureContext): string May contain escapes (e.g. `%^{Title}`)
---@field keywords? string[]|string
---@field file_type? string
---@field subdirectory? string
---@field signature? string|fun(ctx: denote.CaptureContext): string
---@field date? string|integer
---@field dir? string
---@field prompts? string[] Denote prompts for fields left unset (default: `config.prompts`)
---@field target? "journal"|{ identifier?: string, path?: string, journal?: boolean, date?: string }|fun(ctx: denote.CaptureContext): string
---@field open? boolean Open the note after capturing (default: true)
---@field save? boolean Save after capturing
---@field how? string Window open mode

local SIMPLE =
  { i = true, a = true, l = true, x = true, f = true, F = true, t = true, T = true, u = true, U = true, n = true }

--- Split one template line into tokens.
---@param line string
---@return table[]
local function tokenize(line)
  local tokens, buf = {}, {}
  local function flush()
    if #buf > 0 then
      tokens[#tokens + 1] = { kind = "lit", text = table.concat(buf) }
      buf = {}
    end
  end
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    local nx = line:sub(i + 1, i + 1)
    if c ~= "%" or nx == "" then
      buf[#buf + 1] = c
      i = i + 1
    elseif nx == "%" then
      buf[#buf + 1] = "%"
      i = i + 2
    elseif nx == "?" then
      flush()
      tokens[#tokens + 1] = { kind = "cursor" }
      i = i + 2
    elseif nx == "^" and line:sub(i + 2, i + 2) == "{" and line:find("}", i + 3, true) then
      local close = line:find("}", i + 3, true)
      flush()
      local inside = line:sub(i + 3, close - 1)
      local sep = inside:find("|", 1, true)
      local name = sep and inside:sub(1, sep - 1) or inside
      local default = sep and inside:sub(sep + 1) or nil
      tokens[#tokens + 1] = { kind = "prompt", name = name, default = default }
      i = close + 1
    elseif nx == "\\" and line:sub(i + 2, i + 2):match("%d") then
      flush()
      tokens[#tokens + 1] = { kind = "backref", index = tonumber(line:sub(i + 2, i + 2)) }
      i = i + 3
    elseif SIMPLE[nx] then
      flush()
      tokens[#tokens + 1] = { kind = "esc", char = nx }
      i = i + 2
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  flush()
  return tokens
end

--- Return the distinct prompts of `template` in order of first appearance.
---@param template? string
---@return { name: string, default?: string }[]
function M.prompts(template)
  local out, seen = {}, {}
  if type(template) ~= "string" then
    return out
  end
  for _, line in ipairs(vim.split(template, "\n", { plain = true })) do
    for _, tok in ipairs(tokenize(line)) do
      if tok.kind == "prompt" and not seen[tok.name] then
        seen[tok.name] = true
        out[#out + 1] = { name = tok.name, default = tok.default }
      end
    end
  end
  return out
end

--- Return ordered distinct prompts across multiple template strings.
---@param templates (string|nil)[]
---@return { name: string, default?: string }[]
local function collect_prompts(templates)
  local keys = {}
  for k in pairs(templates) do
    if type(k) == "number" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local out, seen = {}, {}
  for _, k in ipairs(keys) do
    for _, p in ipairs(M.prompts(templates[k])) do
      if not seen[p.name] then
        seen[p.name] = true
        out[#out + 1] = p
      end
    end
  end
  return out
end

--- Ask (asynchronously, via `vim.ui.input`) every `%^{...}` prompt of `templates` that has no
--- answer in `answers` yet, then call `done(answers)`. Cancelling a prompt aborts. When nothing
--- needs asking (or the prompts complete synchronously), `done`'s result is returned.
---@param templates (string|nil)[]
---@param answers table<string, string>
---@param done fun(answers: table<string, string>): any
---@return any
function M.ask(templates, answers, done)
  local pending = {}
  for _, p in ipairs(collect_prompts(templates)) do
    if answers[p.name] == nil then
      pending[#pending + 1] = p
    end
  end
  if #pending == 0 then
    return done(answers)
  end
  local result
  local function step(idx)
    if idx > #pending then
      result = done(answers)
      return
    end
    local p = pending[idx]
    vim.ui.input({ prompt = p.name .. ": ", default = p.default or "" }, function(input)
      if input == nil then
        return
      end
      answers[p.name] = input
      step(idx + 1)
    end)
  end
  step(1)
  -- Set when every prompt was answered synchronously (e.g. stubbed `vim.ui.input`).
  return result
end

--- Map a Denote file type to a link syntax.
---@param file_type? string
---@return "org"|"markdown"|"text"
function M.syntax_for(file_type)
  if file_type == "org" then
    return "org"
  elseif file_type == "markdown-yaml" or file_type == "markdown-toml" then
    return "markdown"
  end
  return "text"
end

--- Describe the current buffer/cursor as a capture origin.
---@param bufnr? integer
---@return denote.CaptureOrigin
function M.origin(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local origin = { bufnr = bufnr, path = vim.api.nvim_buf_get_name(bufnr), filetype = vim.bo[bufnr].filetype }
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    origin.lnum = vim.api.nvim_win_get_cursor(win)[1]
  end
  return origin
end

--- Link back to the capture origin (`%a` / `%l`).
---@param ctx denote.CaptureContext
---@return string
function M.origin_link(ctx)
  local o = ctx.origin
  if not o or not o.path or o.path == "" then
    return ""
  end
  local naming = require("denote.naming")
  local links = require("denote.links")
  local id = naming.is_denote_file(o.path) and naming.retrieve_identifier(o.path)
  local syntax = ctx.syntax or M.syntax_for(config.opts.file_type)
  if id then
    return links.format_link(id, links.default_description(o.path), {
      syntax = syntax,
      file_path = o.path,
      from_dir = ctx.target_dir,
    })
  end
  if syntax == "org" then
    return string.format("[[file:%s::%d]]", o.path, o.lnum or 1)
  end
  return o.lnum and (o.path .. ":" .. o.lnum) or o.path or ""
end

local function clipboard(ctx)
  if ctx.clipboard ~= nil then
    return ctx.clipboard
  end
  for _, reg in ipairs({ "+", '"' }) do
    local ok, v = pcall(vim.fn.getreg, reg)
    if ok and type(v) == "string" and v ~= "" then
      return (v:gsub("\n$", ""))
    end
  end
  return ""
end

local function org_date(ts, active, with_time)
  local s = tostring(os.date(with_time and "%Y-%m-%d %a %H:%M" or "%Y-%m-%d %a", ts))
  return active and ("<" .. s .. ">") or ("[" .. s .. "]")
end

local function escape_value(char, ctx)
  local o = ctx.origin or {}
  local ts = ctx.date or os.time()
  if char == "i" then
    return ((ctx.region or ""):gsub("\n$", ""))
  elseif char == "a" or char == "l" then
    return M.origin_link(ctx)
  elseif char == "x" then
    return clipboard(ctx)
  elseif char == "f" then
    return (o.path and o.path ~= "") and vim.fs.basename(o.path) or ""
  elseif char == "F" then
    return o.path or ""
  elseif char == "t" or char == "T" then
    return org_date(ts, true, char == "T")
  elseif char == "u" or char == "U" then
    return org_date(ts, false, char == "U")
  elseif char == "n" then
    return vim.env.USER or vim.env.USERNAME or ""
  end
  return ""
end

--- Expand `template` synchronously. Prompts are answered from `ctx.answers`, falling back to
--- their default (or the empty string); use `M.expand` / `M.ask` to prompt interactively.
---@param template string
---@param ctx? denote.CaptureContext
---@return string text, integer|nil cursor 1-based byte offset of `%?` in `text`
function M.expand_sync(template, ctx)
  ctx = ctx or {}
  local answers = ctx.answers or {}
  local order = ctx.prompt_order or M.prompts(template)
  local out, total, cursor, first = {}, 0, nil, true
  for _, line in ipairs(vim.split(template or "", "\n", { plain = true })) do
    local pieces, len = {}, 0
    local has_esc, has_value, has_text, cur_col = false, false, false, nil
    for _, tok in ipairs(tokenize(line)) do
      local v
      if tok.kind == "lit" then
        v = tok.text
        has_text = has_text or tok.text:match("%S") ~= nil
      elseif tok.kind == "cursor" then
        cur_col = cur_col or len
      else
        if tok.kind == "prompt" then
          v = answers[tok.name] or tok.default or ""
        elseif tok.kind == "backref" then
          local p = order[tok.index]
          v = p and (answers[p.name] or p.default) or ""
        else
          v = escape_value(tok.char, ctx)
          if tok.char == "i" and v:find("\n", 1, true) then
            local indent = table.concat(pieces)
            if indent ~= "" and indent:match("^%s*$") then
              v = v:gsub("\n", "\n" .. indent)
            end
          end
        end
        has_esc = true
        has_value = has_value or v ~= ""
      end
      if v then
        pieces[#pieces + 1] = v
        len = len + #v
      end
    end
    if not (has_esc and not has_value and not has_text and not cur_col) then
      if not first then
        out[#out + 1] = "\n"
        total = total + 1
      end
      first = false
      if cur_col and not cursor then
        cursor = total + cur_col + 1
      end
      local text = table.concat(pieces)
      out[#out + 1] = text
      total = total + #text
    end
  end
  return table.concat(out), cursor
end

--- Prompt for missing answers, then expand `template` and call `cb(text, cursor)`.
---@param template string
---@param ctx? denote.CaptureContext
---@param cb fun(text: string, cursor: integer|nil): any
---@return any
function M.expand(template, ctx, cb)
  ctx = ctx or {}
  ctx.answers = ctx.answers or {}
  return M.ask({ template }, ctx.answers, function()
    return cb(M.expand_sync(template, ctx))
  end)
end

--- Ensure `content` ends with a newline; when `cursor` is at the very end, add an empty line
--- for it to land on.
---@param content string
---@param cursor? integer
---@return string
function M.finalize(content, cursor)
  if content ~= "" and content:sub(-1) ~= "\n" then
    content = content .. "\n"
  end
  if cursor and cursor > #content and content:sub(-1) == "\n" then
    content = content .. "\n"
  end
  return content
end

--- Convert a 1-based byte offset into a `{ row, col }` window cursor (row 1-based, col 0-based).
---@param content string
---@param offset integer
---@return integer[]
function M.offset_to_pos(content, offset)
  local before = content:sub(1, offset - 1)
  local _, newlines = before:gsub("\n", "")
  local last_nl = before:match(".*()\n") or 0
  return { newlines + 1, #before - last_nl }
end

--- Text of lines `line1..line2` of `bufnr`; uses the exact (charwise / blockwise) visual
--- selection when the `'<`/`'>` marks match the range.
---@param bufnr? integer
---@param line1 integer
---@param line2 integer
---@return string
function M.region_text(bufnr, line1, line2)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if line1 > line2 then
    line1, line2 = line2, line1
  end
  if vim.fn.exists("*getregion") == 1 and bufnr == vim.api.nvim_get_current_buf() then
    local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    local mode = vim.fn.visualmode()
    if s[2] == line1 and e[2] == line2 and mode ~= "" then
      local ok, lines = pcall(vim.fn.getregion, s, e, { type = mode })
      if ok and type(lines) == "table" then
        return table.concat(lines, "\n")
      end
    end
  end
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false), "\n")
end

--- The configured capture templates (a single default note template when none are configured).
---@return denote.CaptureTemplate[]
function M.templates()
  local list = (config.opts.capture or {}).templates
  if type(list) ~= "table" or #list == 0 then
    return { { key = "n", description = "Denote note" } }
  end
  return list
end

--- Resolve an append target into a file path.
---@param target any
---@param ctx denote.CaptureContext
---@return string|nil
function M.resolve_target(target, ctx)
  if type(target) == "function" then
    return target(ctx)
  end
  if target == "journal" or (type(target) == "table" and target.journal) then
    local date = type(target) == "table" and target.date or nil
    return (require("denote.journal").new_or_existing_entry({ date = date, open = false, save = true }))
  end
  if type(target) == "string" then
    target = target:match("^%d%d%d%d%d%d%d%dT%d%d%d%d%d%d$") and { identifier = target } or { path = target }
  end
  if type(target) ~= "table" then
    return nil
  end
  if target.identifier then
    return require("denote.files").find_by_id(target.identifier)
  elseif target.path then
    return utils.normalize(target.path)
  end
  return nil
end

--- Append `text` at the end of the note at `path` (separated by a blank line).
---@param path string
---@param text string
---@param cursor? integer Byte offset of the cursor in `text`
---@param opts? { open?: boolean, how?: string, save?: boolean }
---@return { path: string, bufnr?: integer, cursor: integer[] }
function M.append(path, text, cursor, opts)
  opts = opts or {}
  local open = opts.open ~= false
  local bufnr = utils.find_buffer(path)
  if bufnr and not vim.api.nvim_buf_is_loaded(bufnr) then
    bufnr = nil
  end
  if open then
    bufnr = utils.open_file(path, opts.how)
  end
  local old_lines
  if bufnr then
    old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #old_lines == 1 and old_lines[1] == "" then
      old_lines = {}
    end
  else
    old_lines = vim.split(utils.read_file(path) or "", "\n", { plain = true })
    if old_lines[#old_lines] == "" then
      table.remove(old_lines)
    end
  end

  local existing = #old_lines > 0 and (table.concat(old_lines, "\n") .. "\n") or ""
  local sep = (existing ~= "" and existing:sub(-2) ~= "\n\n") and "\n" or ""
  local abs = cursor and (#existing + #sep + cursor) or nil
  local content = M.finalize(existing .. sep .. text, abs)
  local pos = M.offset_to_pos(content, abs or #content)
  local new_lines = vim.split(content, "\n", { plain = true })
  if new_lines[#new_lines] == "" then
    table.remove(new_lines)
  end
  if abs == nil then
    pos = { #new_lines, 0 }
  end

  local save = opts.save
  if save == nil then
    save = (not open) or config.opts.save_buffer_after_creation
  end
  if bufnr then
    local was_modified = vim.bo[bufnr].modified
    if vim.bo[bufnr].modifiable then
      vim.api.nvim_buf_set_lines(
        bufnr,
        #old_lines == 0 and 0 or #old_lines,
        -1,
        false,
        vim.list_slice(new_lines, #old_lines + 1)
      )
    end
    if save then
      if not open and was_modified and opts.save == nil then
        utils.warn("Appended to modified buffer; run :w to save")
      else
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("silent write")
        end)
      end
    end
    if open then
      pcall(vim.api.nvim_win_set_cursor, 0, pos)
    end
  else
    utils.write_file(path, content)
  end
  return { path = path, bufnr = bufnr, cursor = pos }
end

local function call_or(value, ctx)
  if type(value) == "function" then
    return value(ctx)
  end
  return value
end

--- Run one capture template: create a new note, or append to `entry.target`.
---@param entry denote.CaptureTemplate
---@param ctx denote.CaptureContext
---@param opts? { open?: boolean, how?: string, save?: boolean, interactive?: boolean }
---@return any result Created note meta / append result (when no prompt was needed)
function M.run(entry, ctx, opts)
  opts = opts or {}
  ctx.answers = ctx.answers or {}
  local body = call_or(entry.template, ctx)
  if body == nil then
    body = (config.opts.capture or {}).specifiers or M.default_specifiers
  end
  local open = opts.open
  if open == nil then
    open = entry.open
  end
  local save = opts.save
  if save == nil then
    save = entry.save
  end
  local how = opts.how or entry.how
  local interactive = opts.interactive ~= false

  if entry.target then
    local function finish()
      local path = M.resolve_target(entry.target, ctx)
      if not path or not utils.is_file(path) then
        utils.error("Denote capture: target note not found")
        return nil
      end
      local frontmatter = require("denote.frontmatter")
      ctx.syntax = M.syntax_for(frontmatter.detect_file_type(path))
      ctx.target_dir = vim.fs.dirname(path)
      local text, cursor = M.expand_sync(body, ctx)
      return M.append(path, text, cursor, { open = open, how = how, save = save })
    end
    if not interactive then
      return finish()
    end
    return M.ask({ body }, ctx.answers, finish)
  end

  local title_t = call_or(entry.title, ctx)
  local sig_t = call_or(entry.signature, ctx)
  ctx.prompt_order = collect_prompts({ title_t, sig_t, body })
  local function finish()
    local function inline(s)
      if s == nil then
        return nil
      end
      return vim.trim((M.expand_sync(s, ctx):gsub("\n", " ")))
    end
    return require("denote.create").note({
      title = inline(title_t),
      keywords = entry.keywords,
      file_type = entry.file_type,
      subdirectory = entry.subdirectory,
      signature = inline(sig_t),
      date = entry.date,
      dir = entry.dir,
      prompts = entry.prompts,
      open = open,
      save = save,
      how = how,
      interactive = opts.interactive,
      body_template = body,
      context = ctx,
    })
  end
  if not interactive then
    return finish()
  end
  return M.ask({ title_t, sig_t, body }, ctx.answers, finish)
end

--- Open a single-key centered float for capture templates (like Org's capture dispatcher).
---@param list denote.CaptureTemplate[]
---@param on_pick fun(entry: denote.CaptureTemplate)
---@return integer win
function M.open_dispatch(list, on_pick)
  require("denote.ui").ensure_highlights()
  local lines = {}
  local width = 26
  for _, entry in ipairs(list) do
    local line = string.format("  [%s]  %s", entry.key, entry.description or entry.key)
    lines[#lines + 1] = line
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ui = vim.api.nvim_list_uis()[1]
  local cols = ui and ui.width or 80
  local rows = ui and ui.height or 24
  local win_w = math.max(1, math.min(width, cols - 4))
  local win_h = math.max(1, math.min(#lines, rows - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = win_w,
    height = win_h,
    row = math.max(0, math.floor((rows - win_h) / 2)),
    col = math.max(0, math.floor((cols - win_w) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Denote Capture ",
    title_pos = "center",
    footer = " press key · q/Esc cancel ",
    footer_pos = "center",
  })

  local ns = vim.api.nvim_create_namespace("denote_capture_dispatch")
  for i, entry in ipairs(list) do
    utils.add_highlight(buf, ns, "DenoteIdentifier", i - 1, 2, 2 + #entry.key + 2)
    utils.add_highlight(buf, ns, "DenoteTitle", i - 1, 2 + #entry.key + 4, -1)
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, close, { buffer = buf, nowait = true, silent = true })
  end
  for _, entry in ipairs(list) do
    vim.keymap.set("n", entry.key, function()
      close()
      on_pick(entry)
    end, { buffer = buf, nowait = true, silent = true })
  end
  return win
end

--- Return true when `list` can use the single-key capture menu.
---@param list denote.CaptureTemplate[]
---@return boolean
local function can_single_key(list)
  if config.opts.capture and config.opts.capture.picker == true then
    return false
  end
  local seen = {}
  for _, entry in ipairs(list) do
    local k = entry.key
    if type(k) ~= "string" or #k ~= 1 or k:match("%s") or k == "q" or seen[k] then
      return false
    end
    seen[k] = true
  end
  return true
end

---@class denote.CaptureOpts
---@field key? string Capture template key (picker when omitted and several are configured)
---@field entry? denote.CaptureTemplate Use this template directly
---@field region? string Text for `%i`
---@field line1? integer Take `%i` from lines `line1..line2` of the current buffer
---@field line2? integer
---@field answers? table<string, string> Pre-supplied prompt answers
---@field origin? denote.CaptureOrigin
---@field open? boolean
---@field how? string
---@field save? boolean
---@field interactive? boolean When false, never prompt (prompts use their defaults)

--- Capture a note from a capture template (`:Denote capture [key]`, `:DenoteCapture`).
---@param opts? denote.CaptureOpts
---@return any
function M.capture(opts)
  opts = opts or {}
  local region = opts.region
  local line1 = opts.line1
  if region == nil and line1 then
    region = M.region_text(nil, line1, opts.line2 or line1)
  end
  local ctx = {
    origin = opts.origin or M.origin(),
    region = region,
    answers = vim.deepcopy(opts.answers or {}),
  }
  local function go(entry)
    return M.run(entry, ctx, opts)
  end
  if opts.entry then
    return go(opts.entry)
  end
  local list = M.templates()
  if opts.key then
    for _, entry in ipairs(list) do
      if entry.key == opts.key then
        return go(entry)
      end
    end
    utils.error("Unknown Denote capture template: " .. opts.key)
    return nil
  end
  if #list == 1 then
    return go(list[1])
  end
  if can_single_key(list) then
    return M.open_dispatch(list, go)
  end
  local items = {}
  for i, entry in ipairs(list) do
    items[i] = {
      display = { { "[" .. entry.key .. "] ", "DenoteIdentifier" }, { entry.description or entry.key, "DenoteTitle" } },
      text = entry.key .. " " .. (entry.description or ""),
      value = entry,
    }
  end
  require("denote.pickers").pick({
    title = "Denote Capture",
    items = items,
    preview = false,
    on_choice = function(chosen)
      if chosen[1] then
        go(chosen[1].value)
      end
    end,
  })
end

--- Keys of the configured capture templates (for command completion).
---@return string[]
function M.keys()
  local out = {}
  for _, entry in ipairs(M.templates()) do
    out[#out + 1] = entry.key
  end
  return out
end

return M
