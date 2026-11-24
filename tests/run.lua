-- Zero-dependency headless busted-style test runner for denote.nvim.
-- Usage: nvim --headless -u tests/minimal_init.lua -l tests/run.lua [spec files...]

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local results = { passed = 0, failed = 0, errors = {} }
local stack = {}
local befores = {}
local afters = {}

_G.describe = function(name, fn)
  table.insert(stack, name)
  table.insert(befores, {})
  table.insert(afters, {})
  local ok, err = pcall(fn)
  if not ok then
    results.failed = results.failed + 1
    table.insert(results.errors, { name = table.concat(stack, " > "), err = err })
  end
  table.remove(afters)
  table.remove(befores)
  table.remove(stack)
end

_G.before_each = function(fn)
  table.insert(befores[#befores], fn)
end

_G.after_each = function(fn)
  table.insert(afters[#afters], fn)
end

_G.it = function(name, fn)
  local full = table.concat(stack, " > ") .. " > " .. name
  local ok, err = pcall(function()
    for _, level in ipairs(befores) do
      for _, b in ipairs(level) do
        b()
      end
    end
    fn()
  end)
  for i = #afters, 1, -1 do
    for _, a in ipairs(afters[i]) do
      local aok, aerr = pcall(a)
      if ok and not aok then
        ok, err = false, aerr
      end
    end
  end
  if ok then
    results.passed = results.passed + 1
  else
    results.failed = results.failed + 1
    table.insert(results.errors, { name = full, err = err })
  end
end

_G.eq = function(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error((msg and (msg .. ": ") or "") .. "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual), 2)
  end
end

_G.ok = function(v, msg)
  if not v then
    error(msg or ("expected truthy, got " .. vim.inspect(v)), 2)
  end
end

_G.buf_lines = function(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

--- Wait until an async Denote results buffer (grep / backlinks) has finished searching.
_G.wait_loaded = function(buf, timeout)
  local done = vim.wait(timeout or 5000, function()
    return vim.api.nvim_buf_is_valid(buf) and vim.b[buf].denote_loading == false
  end, 10)
  if not done then
    error("timed out waiting for async results in buffer " .. tostring(buf), 2)
  end
  return buf
end

_G.with_temp_dir = function(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local ok_run, err = pcall(fn, dir)
  vim.cmd("silent! %bwipeout!")
  vim.fn.delete(dir, "rf")
  if not ok_run then
    error(err, 0)
  end
end

local files = _G.arg and #_G.arg > 0 and { unpack(_G.arg) }
  or vim.fn.glob(root .. "/tests/spec/**/*_spec.lua", false, true)
table.sort(files)

for _, f in ipairs(files) do
  local ok_load, err = pcall(dofile, f)
  if not ok_load then
    results.failed = results.failed + 1
    table.insert(results.errors, { name = "load " .. f, err = err })
  end
  vim.cmd("silent! %bwipeout!")
end

for _, e in ipairs(results.errors) do
  io.stdout:write("FAIL: " .. e.name .. "\n    " .. tostring(e.err):gsub("\n", "\n    ") .. "\n")
end
io.stdout:write(string.format("\n%d passed, %d failed (%d spec files)\n", results.passed, results.failed, #files))
vim.cmd(results.failed > 0 and "cquit 1" or "qall!")
