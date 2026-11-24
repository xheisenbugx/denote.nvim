---@mod denote.search Shared full-text search engine (ripgrep with pure-Lua fallback)
---
--- Every content search in denote.nvim (grep, query links, backlinks, unlinked mentions)
--- goes through `M.run`, so results are consistent no matter which backend runs:
---
--- - `rg` is used when installed (`search.ripgrep = true`), always with `--no-ignore --hidden`
---   so `.gitignore`d or dot-directories never hide notes. Candidates are always filtered by the
---   Denote file index, so excluded directories/files behave the same as in the Lua path.
--- - Exit code 1 ("no matches") is a valid empty result, not a reason to rescan in Lua.
--- - Loaded buffers with unsaved changes are searched from the buffer, not from disk.
--- - Case handling is the same everywhere: "smart" (default) is case-insensitive unless the
---   pattern contains an uppercase letter.
--- - Regex dialect: Rust regex with `rg`, Vim "very magic" (`\v`) without it. Both treat
---   `| ( ) + ? {n}` as operators, so common patterns behave the same.
---
--- Pass a callback to run asynchronously (UI never blocks); omit it to get results directly.

local config = require("denote.config")
local utils = require("denote.utils")

local M = {}

---@class denote.SearchMatch
---@field file string Absolute path
---@field lnum integer 1-based line number
---@field col integer 1-based byte column of the first match on the line
---@field text string Trimmed line text

---@class denote.SearchSpec
---@field pattern string Regex (or literal string with `fixed = true`)
---@field files string[] Candidate files (only matches inside these are returned)
---@field fixed? boolean Treat `pattern` as a literal string
---@field case? "smart"|"sensitive"|"insensitive" Default "smart"
---@field root? string Directory to hand to `rg` when there are many candidates

local rg_available
--- Return true when ripgrep should be used.
---@return boolean
function M.use_ripgrep()
  local opt = config.opts.search and config.opts.search.ripgrep
  if opt == false then
    return false
  end
  if rg_available == nil then
    rg_available = vim.fn.executable("rg") == 1
  end
  return rg_available
end

--- Reset the cached `rg` executable check (tests / PATH changes).
function M.reset()
  rg_available = nil
end

---@param spec denote.SearchSpec
---@return boolean
local function is_case_sensitive(spec)
  local case = spec.case or "smart"
  if case == "sensitive" then
    return true
  elseif case == "insensitive" then
    return false
  end
  return spec.pattern:find("%u") ~= nil
end

--- Build a line matcher for the pure-Lua path. Returns fun(line): col|nil.
---@param spec denote.SearchSpec
---@return fun(line: string): integer|nil
function M.matcher(spec)
  local sensitive = is_case_sensitive(spec)
  if spec.fixed then
    local needle = sensitive and spec.pattern or spec.pattern:lower()
    return function(line)
      return (sensitive and line or line:lower()):find(needle, 1, true)
    end
  end
  local case_flag = sensitive and "\\C" or "\\c"
  local ok_re, re = pcall(vim.regex, "\\v" .. case_flag .. spec.pattern)
  if not ok_re then
    ok_re, re = pcall(vim.regex, case_flag .. spec.pattern)
  end
  if ok_re and re then
    return function(line)
      local s = re:match_str(line)
      return s and (s + 1) or nil
    end
  end
  -- Invalid regex in both dialects: fall back to a literal search.
  return M.matcher(vim.tbl_extend("force", spec, { fixed = true }))
end

--- Buffers whose unsaved contents must take precedence over the file on disk.
---@param allowed table<string, boolean>
---@return table<string, integer> path -> bufnr
local function modified_buffers(allowed)
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local norm = utils.normalize(name)
        if not allowed[norm] then
          local real = (vim.uv or vim.loop).fs_realpath(norm)
          norm = real or norm
        end
        if allowed[norm] then
          out[norm] = bufnr
        end
      end
    end
  end
  return out
end

---@param lines string[]
---@param path string
---@param match fun(line: string): integer|nil
---@param out denote.SearchMatch[]
local function scan_lines(lines, path, match, out)
  for lnum, line in ipairs(lines) do
    local col = match(line)
    if col then
      out[#out + 1] = { file = path, lnum = lnum, col = col, text = vim.trim(line) }
    end
  end
end

--- Pure-Lua search over `paths`.
---@param spec denote.SearchSpec
---@param paths string[]
---@param buffers table<string, integer>
---@return denote.SearchMatch[]
local function lua_search(spec, paths, buffers)
  local match = M.matcher(spec)
  local out = {}
  for _, path in ipairs(paths) do
    local bufnr = buffers[path]
    local lines = bufnr and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) or utils.read_lines(path)
    scan_lines(lines, path, match, out)
  end
  return out
end

--- Above this many candidates, `rg` searches the root directory instead of an explicit file list.
M.MAX_EXPLICIT_FILES = 200

---@param spec denote.SearchSpec
---@return string[]
local function rg_command(spec)
  local cmd = {
    "rg",
    "--vimgrep",
    "--no-heading",
    "--color=never",
    "--no-ignore",
    "--hidden",
    "--no-messages",
    "--no-config",
  }
  if spec.fixed then
    cmd[#cmd + 1] = "--fixed-strings"
  end
  local case = spec.case or "smart"
  cmd[#cmd + 1] = case == "sensitive" and "--case-sensitive"
    or case == "insensitive" and "--ignore-case"
    or "--smart-case"
  cmd[#cmd + 1] = "-e"
  cmd[#cmd + 1] = spec.pattern
  cmd[#cmd + 1] = "--"
  if spec.root and #spec.files > M.MAX_EXPLICIT_FILES then
    cmd[#cmd + 1] = spec.root
  else
    vim.list_extend(cmd, spec.files)
  end
  return cmd
end

---@param stdout string
---@param allowed table<string, boolean>
---@param skip table<string, integer>
---@return denote.SearchMatch[]
local function parse_rg(stdout, allowed, skip)
  local out, seen = {}, {}
  for line in stdout:gmatch("[^\r\n]+") do
    local fpath, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if fpath then
      local norm = utils.normalize(fpath)
      local key = norm .. ":" .. lnum
      if allowed[norm] and not skip[norm] and not seen[key] then
        seen[key] = true
        out[#out + 1] = { file = norm, lnum = tonumber(lnum) or 1, col = tonumber(col) or 1, text = vim.trim(text) }
      end
    end
  end
  return out
end

--- Stable ordering: by candidate order, then line number.
---@param matches denote.SearchMatch[]
---@param files string[]
---@return denote.SearchMatch[]
local function order(matches, files)
  local rank = {}
  for i, f in ipairs(files) do
    rank[f] = i
  end
  table.sort(matches, function(a, b)
    local ra, rb = rank[a.file] or math.huge, rank[b.file] or math.huge
    if ra ~= rb then
      return ra < rb
    end
    return a.lnum < b.lnum
  end)
  return matches
end

---@class denote.SearchHandle
---@field cancel fun()

--- Run a search. With `on_done`, runs asynchronously and returns a handle; otherwise blocks
--- and returns the matches.
---@param spec denote.SearchSpec
---@param on_done? fun(matches: denote.SearchMatch[])
---@return denote.SearchMatch[]|denote.SearchHandle
function M.run(spec, on_done)
  local files = {}
  for i, f in ipairs(spec.files or {}) do
    files[i] = utils.normalize(f)
  end
  spec = vim.tbl_extend("force", spec, { files = files })

  if not spec.pattern or spec.pattern == "" or #files == 0 then
    if on_done then
      vim.schedule(function()
        on_done({})
      end)
      return { cancel = function() end }
    end
    return {}
  end

  local allowed = {}
  for _, f in ipairs(files) do
    allowed[f] = true
  end
  local buffers = modified_buffers(allowed)

  local function finish_rg(res)
    local out
    if res.code == 0 or (res.code == 1 and (res.stdout or "") == "") then
      out = parse_rg(res.stdout or "", allowed, buffers)
    elseif res.code == 2 and (res.stdout or "") ~= "" then
      -- Partial failure (e.g. an unreadable file) but real matches were found.
      out = parse_rg(res.stdout, allowed, buffers)
    else
      -- rg could not run the pattern (e.g. Vim-only regex syntax): use the Lua engine.
      return order(lua_search(spec, files, buffers), files)
    end
    local dirty = vim.tbl_keys(buffers)
    if #dirty > 0 then
      vim.list_extend(out, lua_search(spec, dirty, buffers))
    end
    return order(out, files)
  end

  if not M.use_ripgrep() then
    if on_done then
      local cancelled = false
      vim.schedule(function()
        if not cancelled then
          on_done(order(lua_search(spec, files, buffers), files))
        end
      end)
      return {
        cancel = function()
          cancelled = true
        end,
      }
    end
    return order(lua_search(spec, files, buffers), files)
  end

  local cmd = rg_command(spec)
  if not on_done then
    local ok_sys, proc = pcall(vim.system, cmd, { text = true })
    if not ok_sys then
      return order(lua_search(spec, files, buffers), files)
    end
    return finish_rg(proc:wait())
  end

  local cancelled = false
  local ok_sys, proc = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      if not cancelled then
        on_done(finish_rg(res))
      end
    end)
  end)
  if not ok_sys then
    vim.schedule(function()
      if not cancelled then
        on_done(order(lua_search(spec, files, buffers), files))
      end
    end)
  end
  return {
    cancel = function()
      cancelled = true
      if ok_sys and proc then
        pcall(proc.kill, proc, 15)
      end
    end,
  }
end

return M
