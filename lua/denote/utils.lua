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

--- Write a string to a file atomically / directly.
---@param path string
---@param content string
---@return boolean, string|nil
function M.write_file(path, content)
  local parent = vim.fn.fnamemodify(path, ":h")
  if parent ~= "" and not M.is_dir(parent) then
    M.ensure_dir(parent)
  end
  local f, err = io.open(path, "wb")
  if not f then
    return false, err
  end
  f:write(content)
  f:close()
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

--- Parse a flexible user date input into a Unix timestamp (seconds).
--- Supports:
--- - number (Unix timestamp)
--- - nil / "" (current time)
--- - "YYYYMMDDTHHMMSS" (Denote identifier)
--- - "YYYY-MM-DD"
--- - "YYYY-MM-DD HH:MM" / "YYYY-MM-DD HH:MM:SS"
--- - "YYYY-MM-DDTHH:MM:SS" (ISO-8601)
--- - "today", "yesterday", "tomorrow"
--- - "+Nd" / "-Nd" / "+Nw" / "-Nw"
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
    return now - 86400, nil
  elseif low == "tomorrow" then
    return now + 86400, nil
  end

  local sign, num, unit = low:match("^([%+%-])(%d+)([dwm])$")
  if sign then
    local n = tonumber(num) * (sign == "-" and -1 or 1)
    if unit == "d" then
      return now + n * 86400, nil
    elseif unit == "w" then
      return now + n * 7 * 86400, nil
    elseif unit == "m" then
      local t = os.date("*t", now)
      t.month = t.month + n
      return os.time(t), nil
    end
  end

  -- Denote identifier: 20261123T191500
  local y, m, d, H, Mi, S = s:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)$")
  if y then
    return os.time({
      year = tonumber(y),
      month = tonumber(m),
      day = tonumber(d),
      hour = tonumber(H),
      min = tonumber(Mi),
      sec = tonumber(S),
    }),
      nil
  end

  -- ISO-8601 or YYYY-MM-DD [HH:MM[:SS]]
  y, m, d, H, Mi, S = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d):(%d%d)")
  if y then
    return os.time({
      year = tonumber(y),
      month = tonumber(m),
      day = tonumber(d),
      hour = tonumber(H),
      min = tonumber(Mi),
      sec = tonumber(S),
    }),
      nil
  end

  y, m, d, H, Mi = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d)")
  if y then
    return os.time({
      year = tonumber(y),
      month = tonumber(m),
      day = tonumber(d),
      hour = tonumber(H),
      min = tonumber(Mi),
      sec = 0,
    }),
      nil
  end

  y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y then
    local cur = os.date("*t", now)
    return os.time({
      year = tonumber(y),
      month = tonumber(m),
      day = tonumber(d),
      hour = cur.hour,
      min = cur.min,
      sec = cur.sec,
    }),
      nil
  end

  return nil, "Could not parse date: " .. s
end

--- Format local timezone offset as "+HH:MM" / "-HH:MM" (for ISO-8601).
---@param ts integer
---@return string
function M.tz_offset(ts)
  local raw = os.date("%z", ts) or "+0000"
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
