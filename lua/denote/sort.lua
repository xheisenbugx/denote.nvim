---@mod denote.sort Sorting Denote files by component (matching `denote-sort.el`)
---
--- Supports sorting by:
--- - `"identifier"` (timestamp)
--- - `"title"`
--- - `"keywords"`
--- - `"signature"` (sequence-aware natural ordering so `1=2` < `1=10` and `1a` < `1b` < `1a1`)
--- - `"mtime"` (file modification time)
--- in ascending or descending (`reverse = true`) order.

local files = require("denote.files")
local naming = require("denote.naming")

local M = {}

M.COMPONENTS = { "identifier", "title", "keywords", "signature", "last-modified", "random" }

--- Split a signature string into comparable tokens (numbers as integers, letters as strings)
--- so that Folgezettel sequences sort naturally (`1`, `1=1`, `1=2`, `1=10`, `1a`, `1a1`, `1b`, `2`).
---@param sig string
---@return (integer|string)[]
local function signature_tokens(sig)
  local tokens = {}
  local i = 1
  local n = #sig
  while i <= n do
    local ch = sig:sub(i, i)
    if ch == "=" or ch == "-" or ch == "." then
      i = i + 1
    elseif ch:match("%d") then
      local s, e = sig:find("^%d+", i)
      ---@cast s integer
      ---@cast e integer
      tokens[#tokens + 1] = tonumber(sig:sub(s, e))
      i = e + 1
    else
      local s, e = sig:find("^[^%d=%-%.]+", i)
      ---@cast s integer
      ---@cast e integer
      tokens[#tokens + 1] = sig:sub(s, e):lower()
      i = e + 1
    end
  end
  return tokens
end

--- Compare two signature strings using sequence-aware natural order.
---@param a string
---@param b string
---@return integer -1 if a < b, 0 if equal, 1 if a > b
function M.compare_signatures(a, b)
  if a == b then
    return 0
  end
  -- Empty signatures sort after non-empty signatures (matching Emacs `denote-sort-signature-lessp`)
  if a == "" then
    return 1
  end
  if b == "" then
    return -1
  end
  local ta = signature_tokens(a)
  local tb = signature_tokens(b)
  for i = 1, math.min(#ta, #tb) do
    local va, vb = ta[i], tb[i]
    if va ~= vb then
      if type(va) == type(vb) then
        return va < vb and -1 or 1
      end
      -- numbers sort before strings
      return type(va) == "number" and -1 or 1
    end
  end
  if #ta ~= #tb then
    return #ta < #tb and -1 or 1
  end
  return a < b and -1 or 1
end

--- Sort a list of file paths by `component`.
--- Returns a new sorted list (does not mutate input).
---@param paths string[]
---@param component? "identifier"|"title"|"keywords"|"signature"|"last-modified"|"mtime"|"random"
---@param reverse? boolean
---@return string[]
function M.sort_files(paths, component, reverse)
  component = component or "identifier"
  -- Accept Emacs aliases
  if component == "keyword" then
    component = "keywords"
  elseif component == "mtime" then
    component = "last-modified"
  end

  if component == "random" then
    local out = vim.deepcopy(paths)
    for i = #out, 2, -1 do
      local j = math.random(i)
      out[i], out[j] = out[j], out[i]
    end
    return out
  end

  local entries = {}
  for i, path in ipairs(paths) do
    local p = naming.parse_filename(path)
    entries[i] = {
      path = path,
      parsed = p,
      mtime = component == "last-modified" and files.mtime(path) or 0,
    }
  end

  table.sort(entries, function(a, b)
    local cmp = 0
    if component == "title" then
      local ta = (a.parsed.title or ""):lower()
      local tb = (b.parsed.title or ""):lower()
      if ta ~= tb then
        cmp = ta < tb and -1 or 1
      end
    elseif component == "keywords" then
      local ka = table.concat(a.parsed.keywords or {}, "_"):lower()
      local kb = table.concat(b.parsed.keywords or {}, "_"):lower()
      if ka == "" and kb ~= "" then
        cmp = 1
      elseif ka ~= "" and kb == "" then
        cmp = -1
      elseif ka ~= kb then
        cmp = ka < kb and -1 or 1
      end
    elseif component == "signature" then
      cmp = M.compare_signatures(a.parsed.signature or "", b.parsed.signature or "")
    elseif component == "last-modified" then
      if a.mtime ~= b.mtime then
        cmp = a.mtime < b.mtime and -1 or 1
      end
    else
      -- identifier
      local ia = a.parsed.identifier or ""
      local ib = b.parsed.identifier or ""
      if ia ~= ib then
        cmp = ia < ib and -1 or 1
      end
    end

    if cmp == 0 then
      -- Tie-breaker: identifier, then path
      local ia = a.parsed.identifier or ""
      local ib = b.parsed.identifier or ""
      if ia ~= ib then
        cmp = ia < ib and -1 or 1
      else
        cmp = a.path < b.path and -1 or (a.path > b.path and 1 or 0)
      end
    end

    if reverse then
      return cmp > 0
    end
    return cmp < 0
  end)

  local out = {}
  for i, e in ipairs(entries) do
    out[i] = e.path
  end
  return out
end

return M
