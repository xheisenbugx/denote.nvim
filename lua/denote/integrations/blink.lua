---@mod denote.integrations.blink blink.cmp completion source for Denote links
---
--- Setup in blink.cmp:
--- ```lua
--- sources = {
---   default = { "lsp", "path", "snippets", "buffer", "denote" },
---   providers = {
---     denote = { name = "Denote", module = "denote.integrations.blink" },
---   },
--- }
--- ```

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

local cache = { gen = -1, dir = "", items = {} }

---@return { path: string, id: string, title: string, keywords: string[], filename: string }[]
local function candidate_notes()
  local root = config.directory()
  if cache.gen == files.generation and cache.dir == root then
    return cache.items
  end
  local out = {}
  for _, path in ipairs(files.list({ denote_only = true })) do
    local parsed = naming.parse_filename(path)
    if parsed.identifier then
      out[#out + 1] = {
        path = path,
        id = parsed.identifier,
        filename = parsed.filename,
        keywords = parsed.keywords,
        title = frontmatter.extract_title(path),
      }
    end
  end
  cache = { gen = files.generation, dir = root, items = out }
  return out
end

function M.new()
  return setmetatable({}, { __index = M })
end

function M:enabled()
  if vim.bo.buftype ~= "" then
    return false
  end
  local ft = vim.bo.filetype
  return ft == "org" or ft == "markdown" or ft == "md" or ft == "text"
end

function M:get_trigger_characters()
  return { ":", "[" }
end

function M:get_completions(ctx, callback)
  local line = ctx.line or ""
  local col = ctx.cursor and ctx.cursor[2] or #line
  local before = line:sub(1, col)
  local after = line:sub(col + 1)

  -- Trigger when typing `denote:` or `[[denote:` or `](denote:`
  local match_start = before:find("denote:[%w%-_]*$")
  if not match_start then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return
  end

  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
  local syntax = links.buffer_syntax(bufnr)
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  local from_dir = buf_name ~= "" and vim.fn.fnamemodify(utils.normalize(buf_name), ":h") or config.directory()
  local in_org_bracket = before:match("%[%[denote:[%w%-_]*$") ~= nil
  local in_md_paren = before:match("%]%(denote:[%w%-_]*$") ~= nil
  local row0 = (ctx.cursor and ctx.cursor[1] or 1) - 1

  local end_col = col
  if in_org_bracket and after:sub(1, 2) == "]]" then
    end_col = col + 2
  elseif in_md_paren and after:sub(1, 1) == ")" then
    end_col = col + 1
  end

  local items = {}
  for _, note in ipairs(candidate_notes()) do
    local kws = #note.keywords > 0 and ("[" .. table.concat(note.keywords, ", ") .. "]") or ""
    local new_text
    if in_org_bracket then
      new_text = "denote:" .. note.id .. "][" .. note.title .. "]]"
    elseif in_md_paren then
      new_text = "denote:" .. note.id .. ")"
    else
      new_text = links.format_link(note.id, note.title, {
        syntax = syntax,
        file_path = note.path,
        from_dir = from_dir,
      })
    end
    items[#items + 1] = {
      label = note.title .. " (" .. note.id .. ")",
      filterText = note.id .. " " .. note.title .. " " .. table.concat(note.keywords, " "),
      detail = kws,
      kind = 17, -- File
      documentation = {
        kind = "markdown",
        value = string.format(
          "**%s**\n\n- ID: `%s`\n- File: `%s`\n- Keywords: %s",
          note.title,
          note.id,
          note.filename,
          kws ~= "" and kws or "(none)"
        ),
      },
      textEdit = {
        newText = new_text,
        range = {
          start = { line = row0, character = match_start - 1 },
          ["end"] = { line = row0, character = end_col },
        },
      },
    }
  end

  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = items,
  })
end

return M
