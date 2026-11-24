---@mod denote.report Vault-wide reports: unlinked mentions, broken links, orphan notes
---
--- - `:Denote unlinked_mentions` lists every line in other notes that mentions the current
---   note's title without linking to it (quickfix list). Jump to one and run
---   `:Denote link_mention` to turn that mention into a `denote:` link.
--- - `:Denote check` scans all notes and fills the quickfix list with broken `denote:` links
---   and orphan notes (notes no other note links to).

local config = require("denote.config")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

--- Target of the last `unlinked_mentions` run (used by `link_mention`).
---@type { path: string, identifier: string, title: string }|nil
M.last_mention_target = nil

---@param path string
---@return string[]
local function candidates_excluding(path)
  local out = {}
  local self_real = path and config.canonicalize(path) or nil
  for _, p in ipairs(files.list({ denote_only = true, text_only = true })) do
    if p ~= path and p ~= self_real then
      out[#out + 1] = p
    end
  end
  return out
end

--- Filter raw title matches down to genuine unlinked mentions.
---@param matches denote.SearchMatch[]
---@param identifier string
---@return denote.SearchMatch[]
local function keep_unlinked(matches, identifier)
  local fm_end, out = {}, {}
  for _, m in ipairs(matches) do
    if fm_end[m.file] == nil then
      local fm = frontmatter.parse_file(m.file)
      fm_end[m.file] = (fm and fm.has_front_matter) and fm.end_line or 0
    end
    if m.lnum > fm_end[m.file] and not m.text:find(identifier, 1, true) then
      out[#out + 1] = m
    end
  end
  return out
end

--- Find mentions of a note's title in other notes that do not link to it.
---@param opts? { file?: string, quickfix?: boolean, sync?: boolean }
---@param on_done? fun(matches: denote.SearchMatch[])
---@return denote.SearchMatch[]|denote.SearchHandle|nil
function M.unlinked_mentions(opts, on_done)
  opts = opts or {}
  local path = utils.normalize(opts.file or vim.api.nvim_buf_get_name(0))
  local id = naming.retrieve_identifier(path)
  if not id then
    utils.warn("Current file is not a Denote note (no identifier)")
    return nil
  end
  local title = frontmatter.extract_title(path)
  if not title or vim.trim(title) == "" then
    utils.warn("Current note has no title to search for")
    return nil
  end
  M.last_mention_target = { path = path, identifier = id, title = title }

  local spec = { pattern = title, fixed = true, case = "insensitive", files = candidates_excluding(path) }
  local quickfix = opts.quickfix ~= false and on_done == nil and opts.sync ~= true

  local function present(found)
    local items = {}
    for _, m in ipairs(found) do
      items[#items + 1] = { filename = m.file, lnum = m.lnum, col = m.col, text = m.text }
    end
    vim.fn.setqflist({}, " ", { title = 'Denote: unlinked mentions of "' .. title .. '"', items = items })
    if #items == 0 then
      utils.notify('No unlinked mentions of "' .. title .. '"')
    else
      vim.cmd("botright copen")
    end
  end

  local search = require("denote.search")
  if opts.sync then
    return keep_unlinked(search.run(spec) --[[@as denote.SearchMatch[] ]], id)
  end
  return search.run(spec, function(matches)
    local found = keep_unlinked(matches, id)
    if quickfix then
      present(found)
    end
    if on_done then
      on_done(found)
    end
  end)
end

--- Replace the first mention of the last `unlinked_mentions` target on the current line with
--- a `denote:` link (description keeps the text exactly as written).
---@param target? { identifier: string, title: string }
---@return boolean
function M.link_mention(target)
  target = target or M.last_mention_target
  if not target then
    utils.warn("Run :Denote unlinked_mentions first")
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local s, e = line:lower():find(target.title:lower(), 1, true)
  if not s then
    utils.warn('No mention of "' .. target.title .. '" on this line')
    return false
  end
  local original = line:sub(s, e)
  local link = links.format_link(target.identifier, original, { syntax = links.buffer_syntax(bufnr) })
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line:sub(1, s - 1) .. link .. line:sub(e + 1) })
  return true
end

---@class denote.CheckReport
---@field broken { file: string, lnum: integer, col: integer, identifier: string }[]
---@field orphans string[] Notes no other note links to

--- Build the vault report from all lines containing `denote:` links.
---@param notes string[]
---@param matches denote.SearchMatch[]
---@return denote.CheckReport
local function build_report(notes, matches)
  local linked, broken, known, self_ids = {}, {}, {}, {}
  for _, m in ipairs(matches) do
    local self_id = self_ids[m.file]
    if self_id == nil then
      self_id = naming.retrieve_identifier(m.file) or false
      self_ids[m.file] = self_id
    end
    for _, link in ipairs(links.parse_line(m.text, m.lnum)) do
      local id = link.kind == "id" and link.identifier or nil
      if id then
        if known[id] == nil then
          known[id] = files.has_id(id)
        end
        if id ~= self_id then
          linked[id] = true
        end
        if not known[id] then
          broken[#broken + 1] = { file = m.file, lnum = m.lnum, col = 1, identifier = id }
        end
      end
    end
  end
  local orphans = {}
  for _, path in ipairs(notes) do
    local id = naming.retrieve_identifier(path)
    if id and not linked[id] then
      orphans[#orphans + 1] = path
    end
  end
  return { broken = broken, orphans = orphans }
end

--- Scan every note for broken links and orphans.
--- Without `on_done` returns the report directly; with it, runs asynchronously.
---@param opts? { quickfix?: boolean, orphans?: boolean }
---@param on_done? fun(report: denote.CheckReport)
---@return denote.CheckReport|denote.SearchHandle
function M.check(opts, on_done)
  opts = opts or {}
  local notes = files.list({ denote_only = true })
  local text_notes = vim.tbl_filter(function(p)
    return files.is_text_file(p)
  end, notes)
  local spec = {
    pattern = "denote:",
    fixed = true,
    case = "sensitive",
    files = text_notes,
    root = config.directory(),
  }

  local function present(report)
    local items = {}
    for _, b in ipairs(report.broken) do
      items[#items + 1] = {
        filename = b.file,
        lnum = b.lnum,
        col = b.col,
        type = "W",
        text = "Broken link: no note with identifier " .. b.identifier,
      }
    end
    if opts.orphans ~= false then
      for _, p in ipairs(report.orphans) do
        items[#items + 1] = {
          filename = p,
          lnum = 1,
          col = 1,
          type = "I",
          text = "Orphan: no other note links to " .. frontmatter.extract_title(p),
        }
      end
    end
    vim.fn.setqflist({}, " ", {
      title = string.format("Denote check: %d broken link(s), %d orphan(s)", #report.broken, #report.orphans),
      items = items,
    })
    utils.notify(string.format("Denote check: %d broken link(s), %d orphan note(s)", #report.broken, #report.orphans))
    if #items > 0 then
      vim.cmd("botright copen")
    end
  end

  local search = require("denote.search")
  if not on_done and opts.quickfix == false then
    return build_report(notes, search.run(spec) --[[@as denote.SearchMatch[] ]])
  end
  return search.run(spec, function(matches)
    local report = build_report(notes, matches)
    if opts.quickfix ~= false then
      present(report)
    end
    if on_done then
      on_done(report)
    end
  end)
end

return M
