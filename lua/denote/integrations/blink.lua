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

local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")

local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

function M:enabled()
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

  -- Trigger when typing `denote:` or `[[denote:` or `](denote:`
  if not before:match("denote:[%w%-_]*$") then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return
  end

  local syntax = links.buffer_syntax(ctx.bufnr)
  local in_org_bracket = before:match("%[%[denote:[%w%-_]*$") ~= nil
  local in_md_paren = before:match("%]%(denote:[%w%-_]*$") ~= nil

  local items = {}
  for _, path in ipairs(files.list({ denote_only = true })) do
    local parsed = naming.parse_filename(path)
    if parsed.identifier then
      local title = frontmatter.extract_title(path)
      local insert_text
      if in_org_bracket then
        insert_text = parsed.identifier .. "][" .. title .. "]]"
      elseif in_md_paren then
        insert_text = parsed.identifier .. ")"
      else
        insert_text = links.format_link(parsed.identifier, title, { syntax = syntax })
      end

      local kws = #parsed.keywords > 0 and ("[" .. table.concat(parsed.keywords, ", ") .. "]") or ""
      items[#items + 1] = {
        label = title .. " (" .. parsed.identifier .. ")",
        filterText = parsed.identifier .. " " .. title .. " " .. table.concat(parsed.keywords, " "),
        insertText = insert_text,
        detail = kws,
        kind = 17, -- File
        documentation = {
          kind = "markdown",
          value = string.format(
            "**%s**\n\n- ID: `%s`\n- File: `%s`\n- Keywords: %s",
            title,
            parsed.identifier,
            parsed.filename,
            kws ~= "" and kws or "(none)"
          ),
        },
      }
    end
  end

  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = items,
  })
end

return M
