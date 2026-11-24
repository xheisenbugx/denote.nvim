---@mod denote.preview Hover preview of the note behind a `denote:` link
---
--- `:Denote preview` (default buffer-local `K` on a link) opens a floating window with the
--- target note's title, identifier, keywords, and the first lines of its body (starting at the
--- linked heading for `denote:ID::#heading` / `::*Heading` links). Press `K` again to focus the
--- float, `q` / `<Esc>` inside it to close, or `<CR>` to open the note.

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

---@param path string
---@return string[]
local function read_all(path)
  local bufnr = utils.find_buffer(path)
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  return utils.read_lines(path)
end

--- Find the first body line for a `::search` suffix (heading or custom id), or nil.
---@param path string
---@param search? string
---@return integer|nil
local function search_start(path, search)
  if not search or search == "" then
    return nil
  end
  local num = tonumber(search)
  if num then
    return num
  end
  local headings = frontmatter.extract_headings(path)
  local hash = search:match("^#(.+)$")
  local star = search:match("^%*(.+)$")
  for _, h in ipairs(headings) do
    if hash and (h.custom_id == hash or h.slug == hash or h.slug == naming.sluggify_title(hash)) then
      return h.lnum
    end
    if star and h.text:lower() == vim.trim(star):lower() then
      return h.lnum
    end
  end
  return nil
end

--- Build the preview lines for the note at `path`.
---@param path string
---@param search? string
---@return string[] lines, string filetype
function M.build(path, search)
  local all = read_all(path)
  local ft = frontmatter.detect_file_type(path, all)
  local fm = ft and frontmatter.parse_lines(all, ft) or nil
  local body_start = (fm and fm.has_front_matter) and (fm.end_line + 1) or 1
  local from = search_start(path, search) or body_start

  local parsed = naming.parse_filename(path)
  local title = frontmatter.extract_title(path)
  local header = { title }
  local meta = { parsed.identifier or "" }
  if parsed.signature and parsed.signature ~= "" then
    meta[#meta + 1] = "==" .. parsed.signature
  end
  if parsed.keywords and #parsed.keywords > 0 then
    meta[#meta + 1] = "_" .. table.concat(parsed.keywords, " _")
  end
  header[#header + 1] = table.concat(meta, "  ")
  header[#header + 1] = string.rep("─", math.max(#title, 20))

  local max_lines = (config.opts.preview and config.opts.preview.max_lines) or 20
  local body = {}
  -- Skip leading blank lines
  while from <= #all and vim.trim(all[from]) == "" do
    from = from + 1
  end
  for i = from, math.min(#all, from + max_lines - 1) do
    body[#body + 1] = all[i]
  end
  if #all > from + max_lines - 1 then
    body[#body + 1] = "…"
  end
  if #body == 0 then
    body[1] = "(empty note)"
  end

  local filetype = (ft == "org") and "org" or (ft == "text" and "text" or "markdown")
  return vim.list_extend(header, body), filetype
end

local current = { win = nil, buf = nil }

--- Close the preview window if open.
function M.close()
  if current.win and vim.api.nvim_win_is_valid(current.win) then
    vim.api.nvim_win_close(current.win, true)
  end
  current.win, current.buf = nil, nil
end

--- Preview the Denote link under the cursor (or the given link) in a floating window.
---@param link? denote.Link
---@return integer|nil win
function M.open(link)
  -- Second press focuses an existing preview (like LSP hover)
  if current.win and vim.api.nvim_win_is_valid(current.win) then
    vim.api.nvim_set_current_win(current.win)
    return current.win
  end

  link = link or links.link_at_cursor()
  if not link then
    utils.notify("No Denote link under cursor")
    return nil
  end

  local lines, filetype, path
  if link.kind == "id" then
    path = files.find_by_id(link.identifier)
    if not path then
      utils.warn("Cannot find Denote file with identifier: " .. tostring(link.identifier))
      return nil
    end
    lines, filetype = M.build(path, link.search)
  else
    lines = {
      link.kind == "query-contents" and "Content query" or "Filename query",
      link.query or "",
      string.rep("─", 20),
      "Press <CR> on the link to run this query.",
    }
    filetype = "text"
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = filetype
  vim.b[buf].denote_preview_path = path

  local ns = vim.api.nvim_create_namespace("denote_preview")
  pcall(vim.api.nvim_buf_add_highlight, buf, ns, "DenoteTitle", 0, 0, -1)
  pcall(vim.api.nvim_buf_add_highlight, buf, ns, "DenoteIdentifier", 1, 0, -1)
  pcall(vim.api.nvim_buf_add_highlight, buf, ns, "DenoteDelimiter", 2, 0, -1)

  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, math.max(20, math.floor(vim.o.columns * 0.6)))
  local height = math.min(#lines, math.max(3, math.floor(vim.o.lines * 0.5)))

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = (config.opts.preview and config.opts.preview.border) or "rounded",
    focusable = true,
  })
  vim.wo[win].wrap = true
  vim.wo[win].conceallevel = 2
  current.win, current.buf = win, buf

  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, M.close, { buffer = buf, nowait = true, desc = "denote: close preview" })
  end
  vim.keymap.set("n", "<CR>", function()
    local target = vim.b[buf].denote_preview_path
    M.close()
    if target then
      utils.open_file(target)
    end
  end, { buffer = buf, nowait = true, desc = "denote: open previewed note" })

  -- Close when the cursor moves in the originating window (like LSP hover)
  local origin = vim.api.nvim_get_current_buf()
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
    buffer = origin,
    once = true,
    callback = function()
      if vim.api.nvim_get_current_win() ~= current.win then
        M.close()
      end
    end,
  })

  return win
end

return M
