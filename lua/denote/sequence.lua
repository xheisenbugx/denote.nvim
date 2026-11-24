---@mod denote.sequence Folgezettel / hierarchical sequence notes (matching `denote-sequence`)
---@brief [[
--- Supports both sequence schemes from Emacs `denote-sequence`:
--- - `"numeric"`:      `1`, `2`, `1=1`, `1=2`, `1=1=1`
--- - `"alphanumeric"`: `1`, `2`, `1a`, `1b`, `1a1`, `1a2`, `1a1a`
---
--- Provides:
--- - `new_parent`, `new_child`, `new_sibling`
--- - `relatives` / `find_relatives` (parent, children, siblings, all)
--- - `find` / `link` / `reparent`
---@brief ]]

local config = require("denote.config")
local create = require("denote.create")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local links = require("denote.links")
local naming = require("denote.naming")
local pickers = require("denote.pickers")
local rename = require("denote.rename")
local sort = require("denote.sort")
local utils = require("denote.utils")

local M = {}

--- Return the active sequence scheme ("numeric" or "alphanumeric").
---@return 'numeric'|'alphanumeric'
function M.scheme()
  local s = config.opts.sequence and config.opts.sequence.scheme or "numeric"
  return s == "alphanumeric" and "alphanumeric" or "numeric"
end

--- Split a sequence signature into depth segments.
--- Numeric: `"1=2=1"` -> `{ "1", "2", "1" }`
--- Alphanumeric: `"1a2b"` -> `{ "1", "a", "2", "b" }`
---@param sig string
---@param scheme? 'numeric'|'alphanumeric'
---@return string[]
function M.split(sig, scheme)
  if not sig or sig == "" then
    return {}
  end
  scheme = scheme or M.scheme()
  if scheme == "numeric" then
    return vim.split(sig, "=", { plain = true, trimempty = true })
  end
  -- Alphanumeric alternates digits and lowercase letters
  local parts = {}
  local i = 1
  local n = #sig
  while i <= n do
    local s, e = sig:find("^%d+", i)
    if not s then
      s, e = sig:find("^%a+", i)
    end
    if not s then
      break
    end
    parts[#parts + 1] = sig:sub(s, e):lower()
    i = e + 1
  end
  return parts
end

--- Join sequence segments back into a signature string.
---@param parts string[]
---@param scheme? 'numeric'|'alphanumeric'
---@return string
function M.join(parts, scheme)
  scheme = scheme or M.scheme()
  if scheme == "numeric" then
    return table.concat(parts, "=")
  end
  return table.concat(parts, "")
end

--- Check whether `sig` is a valid sequence signature under `scheme`.
---@param sig string|nil
---@param scheme? 'numeric'|'alphanumeric'
---@return boolean
function M.is_valid(sig, scheme)
  if not sig or sig == "" then
    return false
  end
  scheme = scheme or M.scheme()
  if scheme == "numeric" then
    return sig:match("^[%d=]+$") ~= nil
      and sig:sub(1, 1):match("%d") ~= nil
      and sig:sub(-1):match("%d") ~= nil
      and not sig:find("==", 1, true)
  end
  return sig:match("^%d[%da-zA-Z]*$") ~= nil
end

--- Increment a single letter segment (`"a"` -> `"b"`, `"z"` -> `"za"`).
---@param letters string
---@return string
local function next_alpha(letters)
  if letters == "" then
    return "a"
  end
  local last = letters:sub(-1)
  if last < "z" then
    return letters:sub(1, -2) .. string.char(string.byte(last) + 1)
  end
  return letters .. "a"
end

--- Return the parent signature of `sig`, or nil if `sig` is top-level.
---@param sig string
---@param scheme? 'numeric'|'alphanumeric'
---@return string|nil
function M.parent_of(sig, scheme)
  local parts = M.split(sig, scheme)
  if #parts <= 1 then
    return nil
  end
  table.remove(parts)
  return M.join(parts, scheme)
end

--- Return all Denote files in `dir` that have a valid sequence signature, sorted naturally.
---@param dir? string
---@return string[]
function M.all_files(dir)
  local scheme = M.scheme()
  local all = files.list({ dir = dir, denote_only = true })
  local seq = {}
  for _, p in ipairs(all) do
    local parsed = naming.parse_filename(p)
    if M.is_valid(parsed.signature, scheme) then
      seq[#seq + 1] = p
    end
  end
  return sort.sort_files(seq, "signature", false)
end

--- Return a set `{ [sig] = path }` of existing sequence signatures.
---@param dir? string
---@return table<string, string>
function M.signature_map(dir)
  local map = {}
  for _, p in ipairs(M.all_files(dir)) do
    local sig = naming.parse_filename(p).signature
    if sig then
      map[sig] = p
    end
  end
  return map
end

--- Compute the next available top-level parent signature (`1`, `2`, `3`, ...).
---@param dir? string
---@return string
function M.next_parent(dir)
  local map = M.signature_map(dir)
  local scheme = M.scheme()
  local max_n = 0
  for sig in pairs(map) do
    local parts = M.split(sig, scheme)
    local first = tonumber(parts[1])
    if first and first > max_n then
      max_n = first
    end
  end
  return tostring(max_n + 1)
end

--- Compute the next available child signature under `parent_sig`.
---@param parent_sig string
---@param dir? string
---@return string
function M.next_child(parent_sig, dir)
  local scheme = M.scheme()
  local map = M.signature_map(dir)
  local parts = M.split(parent_sig, scheme)

  if scheme == "numeric" then
    local n = 1
    while true do
      local candidate = M.join(vim.list_extend(vim.deepcopy(parts), { tostring(n) }), scheme)
      if not map[candidate] then
        return candidate
      end
      n = n + 1
    end
  else
    -- Alternate digits and letters
    local last_is_num = parts[#parts] and parts[#parts]:match("^%d+$") ~= nil
    if last_is_num then
      local ch = "a"
      while true do
        local candidate = M.join(vim.list_extend(vim.deepcopy(parts), { ch }), scheme)
        if not map[candidate] then
          return candidate
        end
        ch = next_alpha(ch)
      end
    else
      local n = 1
      while true do
        local candidate = M.join(vim.list_extend(vim.deepcopy(parts), { tostring(n) }), scheme)
        if not map[candidate] then
          return candidate
        end
        n = n + 1
      end
    end
  end
end

--- Compute the next available sibling signature at the same depth as `sig`.
---@param sig string
---@param dir? string
---@return string
function M.next_sibling(sig, dir)
  local scheme = M.scheme()
  local parent = M.parent_of(sig, scheme)
  if not parent then
    return M.next_parent(dir)
  end
  return M.next_child(parent, dir)
end

--- Return relatives of `sig` in `dir`:
--- `{ parent = path|nil, children = path[], siblings = path[], descendants = path[] }`.
---@param sig string
---@param dir? string
---@return { parent: string|nil, children: string[], siblings: string[], descendants: string[] }
function M.relatives(sig, dir)
  local scheme = M.scheme()
  local my_parts = M.split(sig, scheme)
  local my_parent = M.parent_of(sig, scheme)
  local res = { parent = nil, children = {}, siblings = {}, descendants = {} }

  for _, path in ipairs(M.all_files(dir)) do
    local other_sig = naming.parse_filename(path).signature
    if other_sig and other_sig ~= sig then
      local op = M.split(other_sig, scheme)
      if my_parent and other_sig == my_parent then
        res.parent = path
      end
      if M.parent_of(other_sig, scheme) == my_parent then
        res.siblings[#res.siblings + 1] = path
      end
      if #op > #my_parts then
        local is_desc = true
        for i = 1, #my_parts do
          if op[i] ~= my_parts[i] then
            is_desc = false
            break
          end
        end
        if is_desc then
          res.descendants[#res.descendants + 1] = path
          if #op == #my_parts + 1 then
            res.children[#res.children + 1] = path
          end
        end
      end
    end
  end

  return res
end

--- Create a new top-level sequence note (`denote-sequence-new-parent`).
---@param opts? denote.CreateOpts
function M.new_parent(opts)
  opts = vim.deepcopy(opts or {})
  opts.signature = M.next_parent(opts.dir)
  return create.note(opts)
end

--- Resolve base signature from `opts.parent_signature`, current buffer, or picker.
---@param opts? table
---@param title string
---@param callback fun(sig: string)
local function with_base_signature(opts, title, callback)
  if opts and opts.signature then
    callback(opts.signature)
    return
  end
  local cur = vim.api.nvim_buf_get_name(0)
  local cur_sig = cur ~= "" and naming.parse_filename(cur).signature or nil
  if cur_sig and M.is_valid(cur_sig) and not (opts and opts.pick) then
    callback(cur_sig)
    return
  end
  local seq_files = M.all_files(opts and opts.dir)
  if #seq_files == 0 then
    utils.warn("No sequence notes found")
    return
  end
  local items = {}
  for i, p in ipairs(seq_files) do
    items[i] = pickers.file_item(p)
  end
  pickers.pick({
    title = title,
    items = items,
    on_choice = function(chosen)
      if chosen[1] then
        local sig = naming.parse_filename(chosen[1].value).signature
        if sig then
          callback(sig)
        end
      end
    end,
  })
end

--- Create a child sequence note (`denote-sequence-new-child`).
---@param opts? denote.CreateOpts & { parent_signature?: string, pick?: boolean }
function M.new_child(opts)
  opts = vim.deepcopy(opts or {})
  with_base_signature(
    { signature = opts.parent_signature, pick = opts.pick, dir = opts.dir },
    "Parent Sequence Note",
    function(parent_sig)
      opts.signature = M.next_child(parent_sig, opts.dir)
      create.note(opts)
    end
  )
end

--- Create a sibling sequence note (`denote-sequence-new-sibling`).
---@param opts? denote.CreateOpts & { sibling_signature?: string, pick?: boolean }
function M.new_sibling(opts)
  opts = vim.deepcopy(opts or {})
  with_base_signature(
    { signature = opts.sibling_signature, pick = opts.pick, dir = opts.dir },
    "Sibling Sequence Note",
    function(sib_sig)
      opts.signature = M.next_sibling(sib_sig, opts.dir)
      create.note(opts)
    end
  )
end

--- Pick and open a sequence note (`denote-sequence-find`).
---@param opts? { dir?: string }
function M.find(opts)
  opts = opts or {}
  local seq_files = M.all_files(opts.dir)
  if #seq_files == 0 then
    utils.notify("No sequence notes found")
    return
  end
  local items = {}
  for i, p in ipairs(seq_files) do
    items[i] = pickers.file_item(p)
  end
  pickers.pick({
    title = "Denote Sequence Notes",
    items = items,
    on_choice = function(chosen, _, how)
      if chosen[1] then
        utils.open_file(chosen[1].value, how)
      end
    end,
  })
end

--- Pick and open a relative (parent, children, siblings, descendants) of the current sequence note
--- (`denote-sequence-find-relatives-dired` / `denote-sequence-find-next-sibling`).
---@param opts? { dir?: string, file?: string }
function M.find_relatives(opts)
  opts = opts or {}
  local path = opts.file or vim.api.nvim_buf_get_name(0)
  local sig = naming.parse_filename(path).signature
  if not M.is_valid(sig) then
    utils.warn("Current file does not have a valid sequence signature")
    return
  end
  local rel = M.relatives(sig, opts.dir)
  local items = {}
  local function add(label, p)
    local parsed = naming.parse_filename(p)
    items[#items + 1] = {
      display = {
        { string.format("[%-10s] ", label), "DenoteKeywords" },
        { parsed.signature or "", "DenoteSignature" },
        { "  " .. frontmatter.extract_title(p), "DenoteTitle" },
      },
      text = label .. " " .. (parsed.signature or "") .. " " .. frontmatter.extract_title(p),
      filename = p,
      value = p,
    }
  end
  if rel.parent then
    add("parent", rel.parent)
  end
  for _, p in ipairs(rel.siblings) do
    add("sibling", p)
  end
  for _, p in ipairs(rel.children) do
    add("child", p)
  end
  for _, p in ipairs(rel.descendants) do
    if not vim.tbl_contains(rel.children, p) then
      add("descendant", p)
    end
  end

  if #items == 0 then
    utils.notify("No sequence relatives found for " .. sig)
    return
  end

  pickers.pick({
    title = "Relatives of Sequence " .. sig,
    items = items,
    on_choice = function(chosen, _, how)
      if chosen[1] then
        utils.open_file(chosen[1].value, how)
      end
    end,
  })
end

--- Insert a link to a sequence note (`denote-sequence-link`).
---@param opts? { dir?: string, id_only?: boolean }
function M.link(opts)
  opts = opts or {}
  local origin_win = vim.api.nvim_get_current_win()
  local origin_pos = vim.api.nvim_win_get_cursor(origin_win)
  local seq_files = M.all_files(opts.dir)
  if #seq_files == 0 then
    utils.notify("No sequence notes found")
    return
  end
  local items = {}
  for i, p in ipairs(seq_files) do
    items[i] = pickers.file_item(p)
  end
  pickers.pick({
    title = "Link to Sequence Note",
    items = items,
    on_choice = function(chosen)
      if chosen[1] then
        if vim.api.nvim_win_is_valid(origin_win) then
          vim.api.nvim_set_current_win(origin_win)
          pcall(vim.api.nvim_win_set_cursor, origin_win, origin_pos)
        end
        links.link({ target = chosen[1].value, id_only = opts.id_only })
      end
    end,
  })
end

--- Reparent the current note under a chosen parent sequence (`denote-sequence-reparent`).
---@param opts? { file?: string, parent_signature?: string, dir?: string }
function M.reparent(opts)
  opts = opts or {}
  local path = opts.file or vim.api.nvim_buf_get_name(0)
  if path == "" then
    utils.warn("Current buffer has no file name")
    return
  end
  local function apply(parent_sig)
    local new_sig = M.next_child(parent_sig, opts.dir)
    local new_path, err = rename.rename_sync({ file = path, signature = new_sig })
    if err then
      utils.error(err)
    elseif new_path then
      utils.notify("Reparented to signature " .. new_sig)
    end
  end
  if opts.parent_signature then
    apply(opts.parent_signature)
    return
  end
  with_base_signature({ pick = true, dir = opts.dir }, "Select New Parent Sequence", apply)
end

return M
