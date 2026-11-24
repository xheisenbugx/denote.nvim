-- Benchmark denote.nvim against a generated vault.
-- Usage: make bench [N=5000]
--   nvim --headless -u tests/minimal_init.lua -l scripts/bench.lua [N]

local n = tonumber(_G.arg and _G.arg[1]) or 5000
local uv = vim.uv or vim.loop
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- Generate N notes in 20 subdirectories; every note links to its predecessor.
local ids = {}
local base = os.time({ year = 2020, month = 1, day = 1, hour = 0 })
for i = 1, n do
  local id = os.date("%Y%m%dT%H%M%S", base + i * 60)
  ids[i] = id
  local sub = dir .. "/d" .. (i % 20)
  if i <= 20 then
    vim.fn.mkdir(sub, "p")
  end
  local body =
    { "---", 'title: "Note ' .. i .. '"', "identifier: " .. id, "---", "", "Body text for note " .. i .. "." }
  if i > 1 then
    body[#body + 1] = "See [prev](denote:" .. ids[i - 1] .. ")."
  end
  write(sub .. "/" .. id .. "--note-" .. i .. "__bench.md", table.concat(body, "\n") .. "\n")
end

local denote = require("denote")
denote.setup({ directory = dir, mappings = { enabled = false } })
local files = require("denote.files")
local search = require("denote.search")

local function time(label, fn, reps)
  reps = reps or 1
  local t0 = uv.hrtime()
  local res
  for _ = 1, reps do
    res = fn()
  end
  local ms = (uv.hrtime() - t0) / 1e6 / reps
  io.stdout:write(string.format("%-42s %9.2f ms\n", label, ms))
  return res
end

io.stdout:write(string.format("denote.nvim benchmark: %d notes in %s\n\n", n, dir))
time("files.list (cold scan)", function()
  files.invalidate()
  return files.list()
end)
time("files.list (warm, revalidated)", function()
  return files.list()
end, 10)
time("files.find_by_id (warm)", function()
  return files.find_by_id(ids[math.floor(n / 2)])
end, 100)
time("frontmatter.extract_title x100 (warm)", function()
  for i = 1, 100 do
    require("denote.frontmatter").extract_title(files.find_by_id(ids[i]))
  end
end)

for _, use_rg in ipairs(vim.fn.executable("rg") == 1 and { true, false } or { false }) do
  require("denote.config").opts.search = { ripgrep = use_rg }
  search.reset()
  local tag = use_rg and "rg" or "lua"
  time("backlinks.find (" .. tag .. ")", function()
    return require("denote.backlinks").find(ids[10])
  end)
  time("query.search_contents (" .. tag .. ")", function()
    return require("denote.query").search_contents("note 4.*")
  end)
  time("report.check (" .. tag .. ")", function()
    return require("denote.report").check({ quickfix = false })
  end)
end

vim.fn.delete(dir, "rf")
vim.cmd("qall!")
