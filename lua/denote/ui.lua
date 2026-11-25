---@mod denote.ui Highlights, link decorations, broken link checks, and help float

local config = require("denote.config")
local files = require("denote.files")
local links = require("denote.links")

local M = {}

local ns_links = vim.api.nvim_create_namespace("denote_links_ui")

--- Define default highlight groups linked to standard Neovim groups so every
--- colorscheme looks harmonious out of the box.
function M.setup_highlights()
  local groups = {
    DenoteIdentifier = { default = true, link = "Comment" },
    DenoteSignature = { default = true, link = "Special" },
    DenoteTitle = { default = true, link = "Title" },
    DenoteKeywords = { default = true, link = "Tag" },
    DenoteExtension = { default = true, link = "NonText" },
    DenoteDelimiter = { default = true, link = "NonText" },
    DenoteLink = { default = true, link = "Underlined" },
    DenoteQueryLink = { default = true, link = "Special" },
    DenoteBrokenLink = { default = true, link = "DiagnosticError" },
    DenoteFrontMatterKey = { default = true, link = "Keyword" },
    DenoteFrontMatterDelimiter = { default = true, link = "Comment" },
    DenoteBacklinksHeader = { default = true, link = "Title" },
    DenoteBacklinksFile = { default = true, link = "Directory" },
    DenoteBacklinksLineNr = { default = true, link = "LineNr" },
    DenoteBacklinksMatch = { default = true, link = "Normal" },
    DenoteJournalCalendarEntry = { default = true, link = "Special" },
    DenoteJournalCalendarToday = { default = true, link = "Todo" },
    DenoteJournalCalendarHeader = { default = true, link = "Title" },
    DenoteJournalCalendarWeekday = { default = true, link = "Comment" },
  }
  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

--- Define highlight groups if they have not yet been initialized (e.g. before `setup()`).
function M.ensure_highlights()
  local hl = vim.api.nvim_get_hl(0, { name = "DenoteTitle" })
  if not hl or vim.tbl_isempty(hl) then
    M.setup_highlights()
  end
end

--- Return a set `{ [lnum] = true }` of 1-based line numbers inside fenced / source code blocks.
---@param lines string[]
---@param filetype? string
---@return table<integer, boolean>
function M.code_block_lines(lines, filetype)
  local in_code = {}
  if filetype == "org" then
    local block = nil
    for i, line in ipairs(lines) do
      local low = line:lower()
      if block then
        in_code[i] = true
        if low:match("^%s*#%+end_" .. block .. "%s") or low:match("^%s*#%+end_" .. block .. "$") then
          block = nil
        end
      else
        local bname = low:match("^%s*#%+begin_([%w_%-]+)")
        if bname == "src" or bname == "example" or bname == "verbatim" then
          block = bname
          in_code[i] = true
        end
      end
    end
  else
    local fence_char, fence_len = nil, 0
    for i, line in ipairs(lines) do
      if fence_char then
        in_code[i] = true
        local run, trailing = line:match("^%s*(" .. fence_char .. "+)(.*)$")
        if run and #run >= fence_len and trailing:match("^%s*$") then
          fence_char, fence_len = nil, 0
        end
      else
        local ticks, tick_rest = line:match("^%s*(`+)(.*)$")
        local tildes, tilde_rest = line:match("^%s*(~+)(.*)$")
        if ticks and #ticks >= 3 and not tick_rest:find("`", 1, true) then
          fence_char, fence_len = "`", #ticks
          in_code[i] = true
        elseif tildes and #tildes >= 3 and not tilde_rest:find("~", 1, true) then
          fence_char, fence_len = "~", #tildes
          in_code[i] = true
        end
      end
    end
  end
  return in_code
end

local ns_diag = vim.api.nvim_create_namespace("denote_broken_links")

--- Report broken `denote:` links in `bufnr` through `vim.diagnostic` (`ui.diagnostics`).
---@param bufnr integer
---@param broken { lnum: integer, start_col: integer, end_col: integer, identifier: string }[]
local function set_diagnostics(bufnr, broken)
  local ui_opts = config.opts.ui or {}
  if ui_opts.diagnostics == false then
    vim.diagnostic.reset(ns_diag, bufnr)
    return
  end
  local severity = ui_opts.diagnostics_severity or vim.diagnostic.severity.WARN
  local diags = {}
  for _, b in ipairs(broken) do
    diags[#diags + 1] = {
      lnum = b.lnum - 1,
      col = b.start_col - 1,
      end_col = b.end_col,
      severity = severity,
      source = "denote",
      code = "broken-link",
      message = "Broken Denote link: no note with identifier " .. b.identifier,
    }
  end
  vim.diagnostic.set(ns_diag, bufnr, diags)
end

--- Return the broken `denote:` ID links in `lines` (targets resolved like `follow_link`,
--- i.e. across the active directory, silos, and the journal directory).
---@param lines string[]
---@param filetype? string
---@return { lnum: integer, start_col: integer, end_col: integer, identifier: string }[]
function M.broken_links(lines, filetype)
  local out = {}
  local known = {}
  local in_code = M.code_block_lines(lines, filetype)
  for lnum, line in ipairs(lines) do
    if not in_code[lnum] and (line:find("denote:", 1, true) or line:find("](", 1, true)) then
      for _, link in ipairs(links.parse_line(line, lnum)) do
        local id = link.kind == "id" and link.identifier or nil
        if id then
          if known[id] == nil then
            known[id] = files.has_id(id)
          end
          if not known[id] then
            out[#out + 1] = { lnum = lnum, start_col = link.start_col, end_col = link.end_col, identifier = id }
          end
        end
      end
    end
  end
  return out
end

--- Highlight `denote:` links (and optionally flag broken IDs or conceal targets)
--- in Markdown and Plain Text buffers. (Org buffers with org.nvim get native link highlighting,
--- but still receive broken-link diagnostics.)
---@param bufnr integer
---@param force? boolean Bypass unchanged-state cache
function M.decorate_buffer(bufnr, force)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  if vim.bo[bufnr].buftype ~= "" or vim.b[bufnr].denote_preview_path ~= nil then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if ft ~= "markdown" and ft ~= "md" and ft ~= "text" and ft ~= "org" then
    return
  end
  local ui_opts = config.opts.ui or {}
  local state_key = table.concat({
    tostring(vim.api.nvim_buf_get_changedtick(bufnr)),
    tostring(files.generation),
    tostring(ui_opts.highlight_links),
    tostring(ui_opts.conceal_links),
    tostring(ui_opts.check_broken_links),
    tostring(ui_opts.diagnostics),
  }, ":")
  if not force and vim.b[bufnr].denote_decorated_state == state_key then
    return
  end
  vim.b[bufnr].denote_decorated_state = state_key

  local check_broken = ui_opts.check_broken_links ~= false
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local broken = check_broken and M.broken_links(lines, ft) or {}
  set_diagnostics(bufnr, broken)

  -- Skip Org buffers when org.nvim is active (org.nvim draws its own links & concealment)
  if ft == "org" and package.loaded["org"] then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns_links, 0, -1)
  if not ui_opts.highlight_links then
    return
  end

  local conceal = ui_opts.conceal_links == true
  local broken_at = {}
  for _, b in ipairs(broken) do
    broken_at[b.lnum .. ":" .. b.start_col] = true
  end

  local in_code = M.code_block_lines(lines, ft)
  for lnum, line in ipairs(lines) do
    if not in_code[lnum] and (line:find("denote:", 1, true) or line:find("](", 1, true)) then
      for _, link in ipairs(links.parse_line(line, lnum)) do
        local hl = "DenoteLink"
        if link.kind ~= "id" then
          hl = "DenoteQueryLink"
        elseif broken_at[lnum .. ":" .. link.start_col] then
          hl = "DenoteBrokenLink"
        end
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_links, lnum - 1, link.start_col - 1, {
          end_col = link.end_col,
          hl_group = hl,
          priority = 120,
        })
        if conceal and link.description and link.description ~= "" then
          -- Conceal link syntax around description when conceallevel > 0
          if link.syntax == "markdown" then
            local desc_start = link.start_col -- after `[`
            local desc_end = desc_start + #link.description
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_links, lnum - 1, link.start_col - 1, {
              end_col = link.start_col,
              conceal = "",
            })
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_links, lnum - 1, desc_end, {
              end_col = link.end_col,
              conceal = "",
            })
          elseif link.syntax == "org" then
            local desc_idx = line:find("][", link.start_col, true)
            if desc_idx then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_links, lnum - 1, link.start_col - 1, {
                end_col = desc_idx + 1,
                conceal = "",
              })
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_links, lnum - 1, link.end_col - 2, {
                end_col = link.end_col,
                conceal = "",
              })
            end
          elseif link.syntax == "wiki" then
            local pipe_idx = line:find("|", link.start_col, true)
            if pipe_idx then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_links, lnum - 1, link.start_col - 1, {
                end_col = pipe_idx,
                conceal = "",
              })
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_links, lnum - 1, link.end_col - 2, {
                end_col = link.end_col,
                conceal = "",
              })
            end
          end
        end
      end
    end
  end
end

--- Show a clean centered floating help window listing keymaps.
---@param title string
---@param rows { [1]: string, [2]: string }[]
function M.show_help(title, rows)
  local max_key = 0
  for _, r in ipairs(rows) do
    local w = vim.fn.strdisplaywidth(r[1])
    if w > max_key then
      max_key = w
    end
  end
  local lines = {}
  local width = vim.fn.strdisplaywidth(title) + 6
  for _, r in ipairs(rows) do
    local pad = string.rep(" ", max_key - vim.fn.strdisplaywidth(r[1]))
    local line = string.format("  %s%s   %s", r[1], pad, r[2])
    lines[#lines + 1] = line
    local lw = vim.fn.strdisplaywidth(line) + 2
    if lw > width then
      width = lw
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ui = vim.api.nvim_list_uis()[1]
  local cols = ui and ui.width or 80
  local total_rows = ui and ui.height or 24
  local win_w = math.max(1, math.min(width, cols - 4))
  local win_h = math.max(1, math.min(#lines, total_rows - 4))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = win_w,
    height = win_h,
    row = math.floor((total_rows - win_h) / 2),
    col = math.floor((cols - win_w) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, k in ipairs({ "q", "<Esc>", "g?", "?" }) do
    vim.keymap.set("n", k, close, { buffer = buf, nowait = true })
  end
end

return M
