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
  local match_start = before:find("denote:[%w%-_]*$")
  if not match_start then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return
  end

  local syntax = links.buffer_syntax(ctx.bufnr)
  local in_org_bracket = before:match("%[%[denote:[%w%-_]*$") ~= nil
  local in_md_paren = before:match("%]%(denote:[%w%-_]*$") ~= nil
  local row0 = (ctx.cursor and ctx.cursor[1] or 1) - 1

  local items = {}
  for _, path in ipairs(files.list({ denote_only = true })) do
    local parsed = naming.parse_filename(path)
    if parsed.identifier then
      local title = frontmatter.extract_title(path)
      local item = {
        label = title .. " (" .. parsed.identifier .. ")",
        filterText = parsed.identifier .. " " .. title .. " " .. table.concat(parsed.keywords, " "),
        detail = #parsed.keywords > 0 and ("[" .. table.concat(parsed.keywords, ", ") .. "]") or "",
        kind = 17, -- File
        documentation = {
          kind = "markdown",
          value = string.format(
            "**%s**\n\n- ID: `%s`\n- File: `%s`\n- Keywords: %s",
            title,
            parsed.identifier,
            parsed.filename,
            #parsed.keywords > 0 and ("[" .. table.concat(parsed.keywords, ", ") .. "]") or "(none)"
          ),
        },
      }
      if in_org_bracket then
        item.insertText = parsed.identifier .. "][" .. title .. "]]"
      elseif in_md_paren then
        item.insertText = parsed.identifier .. ")"
      else
        item.textEdit = {
          newText = links.format_link(parsed.identifier, title, { syntax = syntax }),
          range = {
            start = { line = row0, character = match_start - 1 },
            ["end"] = { line = row0, character = col },
          },
        }
      end
      items[#items + 1] = item
    end
  end

  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = items,
  })
end

return M
