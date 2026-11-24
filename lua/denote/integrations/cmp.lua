---@mod denote.integrations.cmp nvim-cmp completion source for Denote links
---
--- Setup in nvim-cmp:
--- ```lua
--- require("cmp").register_source("denote", require("denote.integrations.cmp").new())
--- ```

local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")

local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

function M:is_available()
  local ft = vim.bo.filetype
  return ft == "org" or ft == "markdown" or ft == "md" or ft == "text"
end

function M:get_trigger_characters()
  return { ":" }
end

function M:get_keyword_pattern()
  return [[denote:[%w%-_]*]]
end

function M:complete(params, callback)
  local before = params.context.cursor_before_line or ""
  if not before:match("denote:[%w%-_]*$") then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local in_org_bracket = before:match("%[%[denote:[%w%-_]*$") ~= nil
  local items = {}

  for _, path in ipairs(files.list({ denote_only = true })) do
    local parsed = naming.parse_filename(path)
    if parsed.identifier then
      local title = frontmatter.extract_title(path)
      local kws = #parsed.keywords > 0 and ("[" .. table.concat(parsed.keywords, ", ") .. "]") or ""
      items[#items + 1] = {
        label = title .. " (" .. parsed.identifier .. ")",
        filterText = "denote:" .. parsed.identifier .. " " .. title,
        insertText = in_org_bracket and ("denote:" .. parsed.identifier .. "][" .. title .. "]]")
          or ("denote:" .. parsed.identifier),
        detail = kws,
        kind = 17,
      }
    end
  end

  callback({ items = items, isIncomplete = false })
end

return M
