---@mod denote.utils Shared filesystem, string, date, and Neovim helpers

local M = {}

local uv = vim.uv or vim.loop

--- Normalize a filesystem path with forward slashes and no trailing slash.
---@param path string
---@return string
function M.normalize(path)
  if not path or path == "" then
    return ""
  end
  local norm = vim.fs.normalize(path)
  if #norm > 1 then
    norm = norm:gsub("/+$", "")
  end
  return norm
end

--- Check whether a path exists on disk.
---@param path string
---@return boolean
function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

--- Check whether a path is a directory.
---@param path string
---@return boolean
function M.is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

--- Check whether a path is a regular file.
---@param path string
---@return boolean
function M.is_file(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

--- Ensure a directory exists (mkdir -p).
---@param dir string
---@return boolean
function M.ensure_dir(dir)
  if M.is_dir(dir) then
    return true
  end
  return vim.fn.mkdir(dir, "p") == 1
end

--- Read entire file contents as a string, or nil on error.
---@param path string
---@return string|nil
function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

--- Read file lines as a string list (strips trailing CR).
---@param path string
---@param max_lines? integer Optional maximum number of lines to read
---@return string[]
function M.read_lines(path, max_lines)
  local f = io.open(path, "rb")
  if not f then
    return {}
  end
  local lines = {}
  local count = 0
  for line in f:lines() do
    count = count + 1
    lines[count] = line:gsub("\r$", "")
    if max_lines and count >= max_lines then
      break
    end
  end
  f:close()
  return lines
end

--- Tell the file index that the filesystem changed (lazy require avoids a load cycle).
function M.notify_fs_change()
  local ok, files = pcall(require, "denote.files")
  if ok then
    files.invalidate()
  end
end

local write_seq = 0

--- Write a string to a file atomically via sibling temp file + rename.
---@param path string
---@param content string
---@return boolean, string|nil
function M.write_file(path, content)
  local parent = vim.fn.fnamemodify(path, ":h")
  if parent ~= "" and not M.is_dir(parent) then
    if not M.ensure_dir(parent) then
      return false, "Failed to create directory: " .. parent
    end
  end
  write_seq = write_seq + 1
  local tmp = string.format("%s.denote.tmp.%d.%d", path, write_seq, uv.hrtime())
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, err
  end
  local ok_w, werr = f:write(content)
  local ok_c, cerr = f:close()
  if not ok_w or not ok_c then
    pcall(os.remove, tmp)
    return false, tostring(werr or cerr or "Write failed")
  end
  local ok_mv, merr = uv.fs_rename(tmp, path)
  if not ok_mv then
    pcall(os.remove, tmp)
    return false, tostring(merr or "Rename failed")
  end
  M.notify_fs_change()
  return true, nil
end

--- Write a list of lines to a file with trailing newline.
---@param path string
---@param lines string[]
---@return boolean, string|nil
function M.write_lines(path, lines)
  return M.write_file(path, table.concat(lines, "\n") .. "\n")
end

--- Highlight `line` (0-based) from byte `col_start` to `col_end` (-1 = end of line) with
--- `group`. Extmark-based replacement for the deprecated `nvim_buf_add_highlight`.
---@param bufnr integer
---@param ns integer
---@param group string
---@param line integer
---@param col_start integer
---@param col_end integer
function M.add_highlight(bufnr, ns, group, line, col_start, col_end)
  local opts = { hl_group = group, strict = false }
  if col_end == -1 then
    opts.end_row = line + 1
    opts.end_col = 0
  else
    opts.end_col = col_end
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, col_start, opts)
end

--- Find an existing loaded buffer for `path` (normalized).
---@param path string
---@return integer|nil
function M.find_buffer(path)
  local target = M.normalize(path)
  local target_base = vim.fs.basename(target)
  local target_real
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local norm = M.normalize(name)
        if norm == target then
          return bufnr
        end
        -- Only pay for realpath() when basenames agree (symlinked parent directories).
        if vim.fs.basename(norm) == target_base then
          target_real = target_real or uv.fs_realpath(target) or false
          if target_real then
            local real = uv.fs_realpath(norm)
            if real and real == target_real then
              return bufnr
            end
          end
        end
      end
    end
  end
  return nil
end

--- Return relative path of `path` with respect to `base`.
---@param path string
---@param base string
---@return string
function M.relpath(path, base)
  local p = M.normalize(path)
  local b = M.normalize(base)
  if p == b then
    return ""
  end
  local prefix = b .. "/"
  if p:sub(1, #prefix) == prefix then
    return p:sub(#prefix + 1)
  end
  -- Retry with symlinks resolved (e.g. macOS `/var` vs `/private/var`) before walking up.
  local canonicalize = require("denote.config").canonicalize
  local p_real, b_real = canonicalize(p), canonicalize(b)
  if p_real ~= p or b_real ~= b then
    p, b = p_real, b_real
    if p == b then
      return ""
    end
    prefix = b .. "/"
    if p:sub(1, #prefix) == prefix then
      return p:sub(#prefix + 1)
    end
  end
  -- Compute ../ relative path when outside base
  local p_parts = vim.split(p, "/", { plain = true, trimempty = true })
  local b_parts = vim.split(b, "/", { plain = true, trimempty = true })
  local common = 0
  for i = 1, math.min(#p_parts, #b_parts) do
    if p_parts[i] == b_parts[i] then
      common = i
    else
      break
    end
  end
  local out = {}
  for _ = common + 1, #b_parts do
    out[#out + 1] = ".."
  end
  for i = common + 1, #p_parts do
    out[#out + 1] = p_parts[i]
  end
  return table.concat(out, "/")
end

--- Escape a string for literal Lua pattern matching.
---@param s string
---@return string
function M.escape_lua_pattern(s)
  return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

--- Return true if `text` matches `query` (supports Vim/Lua regexp or case-insensitive substring).
---@param text string
---@param query string
---@return boolean
function M.matches_pattern(text, query)
  if not query or query == "" then
    return true
  end
  local ok, res = pcall(vim.fn.match, text, query)
  if ok and res >= 0 then
    return true
  end
  -- Fall back to case-insensitive Lua pattern or plain match
  local lok, lres = pcall(string.find, text:lower(), query:lower())
  if lok and lres then
    return true
  end
  return text:lower():find(query:lower(), 1, true) ~= nil
end

--- Validate numeric date components and return local Unix timestamp (or nil, err).
---@param raw string
---@param y integer
---@param m integer
---@param d integer
---@param H integer
---@param Mi integer
---@param S integer
---@return integer|nil, string|nil
local function validate_time(raw, y, m, d, H, Mi, S)
  if m < 1 or m > 12 or d < 1 or d > 31 or H < 0 or H > 23 or Mi < 0 or Mi > 59 or S < 0 or S > 59 then
    return nil, "Invalid date: " .. raw
  end
  local ts = os.time({ year = y, month = m, day = d, hour = H, min = Mi, sec = S })
  if not ts then
    return nil, "Invalid date: " .. raw
  end
  local dt = os.date("*t", ts) --[[@as osdate]]
  if dt.year ~= y or dt.month ~= m or dt.day ~= d then
    return nil, "Invalid date: " .. raw
  end
  return ts, nil
end

--- Parse a flexible user date input into a Unix timestamp (seconds).
--- Supports:
--- - number (Unix timestamp)
--- - nil / "" (current time)
--- - "YYYYMMDDTHHMMSS" (Denote identifier)
--- - "YYYY-MM-DD"
--- - "YYYY-MM-DD HH:MM" / "YYYY-MM-DD HH:MM:SS"
--- - "YYYY-MM-DDTHH:MM:SS" (ISO-8601)
--- - "today", "yesterday", "tomorrow"
--- - "+Nd" / "-Nd" / "+Nw" / "-Nw" / "+Nm" / "-Nm"
---@param input? string|integer
---@return integer|nil, string|nil
function M.parse_date(input)
  if input == nil or input == "" then
    return os.time(), nil
  end
  if type(input) == "number" then
    return math.floor(input), nil
  end
  local s = vim.trim(tostring(input))
  local low = s:lower()
  local now = os.time()
  if low == "today" or low == "now" then
    return now, nil
  elseif low == "yesterday" then
    local t = os.date("*t", now) --[[@as osdate]]
    t.day = t.day - 1
    return os.time(t), nil
  elseif low == "tomorrow" then
    local t = os.date("*t", now) --[[@as osdate]]
    t.day = t.day + 1
    return os.time(t), nil
  end

  local sign, num, unit = low:match("^([%+%-])(%d+)([dwm])$")
  if sign then
    local n = tonumber(num) * (sign == "-" and -1 or 1)
    local t = os.date("*t", now) --[[@as osdate]]
    if unit == "d" then
      t.day = t.day + n
      return os.time(t), nil
    elseif unit == "w" then
      t.day = t.day + n * 7
      return os.time(t), nil
    elseif unit == "m" then
      t.month = t.month + n
      return os.time(t), nil
    end
  end

  -- Denote identifier: 20261123T191500
  local y, m, d, H, Mi, S = s:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)$")
  if y then
    return validate_time(
      s,
      tonumber(y) --[[@as integer]],
      tonumber(m) --[[@as integer]],
      tonumber(d) --[[@as integer]],
      tonumber(H) --[[@as integer]],
      tonumber(Mi) --[[@as integer]],
      tonumber(S) --[[@as integer]]
    )
  end

  -- ISO-8601 or YYYY-MM-DD [HH:MM[:SS]]
  y, m, d, H, Mi, S = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d):(%d%d)")
  if y then
    return validate_time(
      s,
      tonumber(y) --[[@as integer]],
      tonumber(m) --[[@as integer]],
      tonumber(d) --[[@as integer]],
      tonumber(H) --[[@as integer]],
      tonumber(Mi) --[[@as integer]],
      tonumber(S) --[[@as integer]]
    )
  end

  y, m, d, H, Mi = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d)")
  if y then
    return validate_time(
      s,
      tonumber(y) --[[@as integer]],
      tonumber(m) --[[@as integer]],
      tonumber(d) --[[@as integer]],
      tonumber(H) --[[@as integer]],
      tonumber(Mi) --[[@as integer]],
      0
    )
  end

  y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y then
    local cur = os.date("*t", now) --[[@as osdate]]
    return validate_time(
      s,
      tonumber(y) --[[@as integer]],
      tonumber(m) --[[@as integer]],
      tonumber(d) --[[@as integer]],
      cur.hour,
      cur.min,
      cur.sec
    )
  end

  return nil, "Could not parse date: " .. s
end

--- Format local timezone offset as "+HH:MM" / "-HH:MM" (for ISO-8601).
---@param ts integer
---@return string
function M.tz_offset(ts)
  local raw = tostring(os.date("%z", ts) or "+0000")
  if #raw == 5 then
    return raw:sub(1, 3) .. ":" .. raw:sub(4, 5)
  end
  return "+00:00"
end

--- Notify helpers with consistent prefix.
---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify("[denote] " .. msg, level or vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

--- Open a file in Neovim according to `how` ("edit", "split", "vsplit", "tab", "other").
---@param path string
---@param how? string
---@return integer bufnr
function M.open_file(path, how)
  local escaped = vim.fn.fnameescape(path)
  if how == "split" then
    vim.cmd("split " .. escaped)
  elseif how == "vsplit" then
    vim.cmd("vsplit " .. escaped)
  elseif how == "tab" then
    vim.cmd("tabedit " .. escaped)
  elseif how == "other" then
    local cur = vim.api.nvim_get_current_win()
    local target_win
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= cur and vim.api.nvim_win_get_config(w).relative == "" then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].buftype == "" then
          target_win = w
          break
        end
      end
    end
    if target_win then
      vim.api.nvim_set_current_win(target_win)
      vim.cmd("edit " .. escaped)
    else
      vim.cmd("vsplit " .. escaped)
    end
  else
    vim.cmd("edit " .. escaped)
  end
  return vim.api.nvim_get_current_buf()
end

--- Deduplicate and optionally sort a list of strings.
---@param list string[]
---@param sort? boolean
---@return string[]
function M.unique_strings(list, sort)
  local seen, out = {}, {}
  for _, item in ipairs(list or {}) do
    if item ~= "" and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  if sort then
    table.sort(out)
  end
  return out
end

--- Split a comma- or space-separated keyword input string into a clean list.
---@param input string|string[]|nil
---@return string[]
function M.parse_keywords_input(input)
  if input == nil then
    return {}
  end
  if type(input) == "table" then
    local out = {}
    for _, kw in ipairs(input) do
      local trimmed = vim.trim(tostring(kw))
      if trimmed ~= "" then
        out[#out + 1] = trimmed
      end
    end
    return out
  end
  local out = {}
  for part in tostring(input):gmatch("[^,%s_]+") do
    local trimmed = vim.trim(part)
    if trimmed ~= "" then
      out[#out + 1] = trimmed
    end
  end
  return out
end

return M
