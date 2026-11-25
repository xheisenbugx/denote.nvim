---@mod denote.integrations.cmp nvim-cmp completion source for Denote links
---
--- Setup in nvim-cmp:
--- ```lua
--- require("cmp").register_source("denote", require("denote.integrations.cmp").new())
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

function M:is_available()
  if vim.bo.buftype ~= "" then
    return false
  end
  local ft = vim.bo.filetype
  return ft == "org" or ft == "markdown" or ft == "md" or ft == "text"
end

function M:get_trigger_characters()
  return { ":" }
end

function M:get_keyword_pattern()
  return [[denote:[[:alnum:]_-]*]]
end

function M:complete(params, callback)
  local before = params.context.cursor_before_line or ""
  local match_start = before:find("denote:[%w%-_]*$")
  if not match_start then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local bufnr = params.context.bufnr or vim.api.nvim_get_current_buf()
  local syntax = links.buffer_syntax(bufnr)
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  local from_dir = buf_name ~= "" and vim.fn.fnamemodify(utils.normalize(buf_name), ":h") or config.directory()
  local after = params.context.cursor_after_line or ""
  local in_org_bracket = before:match("%[%[denote:[%w%-_]*$") ~= nil
  local in_md_paren = before:match("%]%(denote:[%w%-_]*$") ~= nil
  local cursor = params.context.cursor or {}
  local row0 = (cursor.row or 1) - 1
  local col = cursor.col or #before

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
      filterText = "denote:" .. note.id .. " " .. note.title .. " " .. table.concat(note.keywords, " "),
      detail = kws,
      kind = 17,
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

  callback({ items = items, isIncomplete = false })
end

return M
