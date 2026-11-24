---@mod denote.explorer Interactive Denote Explorer (Dired / Menu / Sort-Dired buffer)
---
--- Combines Emacs `denote-dired-mode`, `denote-sort-dired`, and `denote-menu` into
--- an idiomatic, colorized Neovim buffer with filtering, sorting, marking, and
--- single or batch renaming.

local config = require("denote.config")
local create = require("denote.create")
local files = require("denote.files")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local pickers = require("denote.pickers")
local rename = require("denote.rename")
local sort = require("denote.sort")
local utils = require("denote.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("denote_explorer")

--- Open the interactive Denote Explorer buffer.
---@param opts? { dir?: string, regexp?: string, keyword?: string, sort_by?: string, reverse?: boolean, denote_only?: boolean }
---@return integer bufnr
function M.open(opts)
  opts = opts or {}
  local origin_buf = vim.api.nvim_get_current_buf()
  local default_comp = config.opts.sort_dired_default_sort_component or "identifier"
  local default_rev = config.opts.sort_dired_default_reverse_sort
  if default_rev == nil then
    default_rev = true
  end

  local state = {
    dir = config.directory(opts.dir),
    regexp = opts.regexp or "",
    exclude_regexp = "",
    keyword = opts.keyword or "",
    sort_by = opts.sort_by or default_comp,
    reverse = opts.reverse == nil and default_rev or opts.reverse,
    denote_only = opts.denote_only ~= false,
    marked = {}, -- { [path] = true }
    rows = {}, -- { [lnum] = path }
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "denote-explorer"
  pcall(vim.api.nvim_buf_set_name, buf, "denote://explorer/" .. vim.fn.fnamemodify(state.dir, ":t"))

  local function collect_files()
    local list = files.list({
      dir = state.dir,
      denote_only = state.denote_only,
      regexp = state.regexp ~= "" and state.regexp or nil,
      not_regexp = state.exclude_regexp ~= "" and state.exclude_regexp or nil,
    })
    if state.keyword ~= "" then
      local kw_slug = naming.sluggify_keyword(state.keyword)
      list = vim.tbl_filter(function(p)
        local parsed = naming.parse_filename(p)
        return vim.tbl_contains(parsed.keywords or {}, kw_slug)
      end, list)
    end
    return sort.sort_files(list, state.sort_by, state.reverse)
  end

  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local list = collect_files()
    state.rows = {}
    local lines, hls = {}, {}

    local filters = {}
    if state.regexp ~= "" then
      filters[#filters + 1] = "/" .. state.regexp .. "/"
    end
    if state.keyword ~= "" then
      filters[#filters + 1] = "kw:" .. state.keyword
    end
    if state.exclude_regexp ~= "" then
      filters[#filters + 1] = "!/" .. state.exclude_regexp .. "/"
    end
    local filter_str = #filters > 0 and ("  filter: " .. table.concat(filters, " ")) or ""
    local dir_arrow = state.reverse and "↓" or "↑"
    local marked_count = vim.tbl_count(state.marked)
    local mark_str = marked_count > 0 and string.format("  [%d marked]", marked_count) or ""

    lines[1] = string.format(
      "Denote Explorer: %s  (%d files · sort: %s %s)%s%s  (g? help)",
      vim.fn.fnamemodify(state.dir, ":~"),
      #list,
      state.sort_by,
      dir_arrow,
      filter_str,
      mark_str
    )
    hls[#hls + 1] = { 0, 0, -1, "DenoteBacklinksHeader" }
    lines[2] = string.rep("─", 78)
    hls[#hls + 1] = { 1, 0, -1, "DenoteDelimiter" }

    if #list == 0 then
      lines[3] = "  (no matching Denote files — press `n` to create one, `c` to clear filters)"
      hls[#hls + 1] = { 2, 0, -1, "Comment" }
    else
      for _, path in ipairs(list) do
        local parsed = naming.parse_filename(path)
        local mark = state.marked[path] and "* " or "  "
        local row = #lines + 1
        state.rows[row] = path

        local parts = {}
        local col = 0
        local function push(text, hl)
          if text == "" then
            return
          end
          parts[#parts + 1] = text
          if hl then
            hls[#hls + 1] = { row - 1, col, col + #text, hl }
          end
          col = col + #text
        end

        push(mark, state.marked[path] and "WarningMsg" or nil)
        if parsed.identifier then
          push(parsed.identifier, "DenoteIdentifier")
        else
          push(string.rep(" ", 15), "Comment")
        end

        if parsed.signature then
          push(" ==" .. parsed.signature, "DenoteSignature")
        end

        local title = parsed.title and naming.desluggify("title", parsed.title) or parsed.filename
        push("  " .. title, "DenoteTitle")

        if #parsed.keywords > 0 then
          push("  __" .. table.concat(parsed.keywords, "_"), "DenoteKeywords")
        end

        if parsed.extension ~= "" then
          push(" " .. parsed.extension, "DenoteExtension")
        end

        lines[row] = table.concat(parts, "")
      end
    end

    local win = vim.fn.bufwinid(buf)
    local has_win = win ~= -1 and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
    local cur_row = has_win and vim.api.nvim_win_get_cursor(win)[1] or 3

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, h[4], h[1], h[2], h[3])
    end

    if has_win then
      local max_row = vim.api.nvim_buf_line_count(buf)
      local target_row = math.min(math.max(3, cur_row), math.max(1, max_row))
      pcall(vim.api.nvim_win_set_cursor, win, { target_row, 0 })
    end
  end

  vim.api.nvim_win_set_buf(0, buf)
  render()
  local init_win = vim.fn.bufwinid(buf)
  if init_win ~= -1 and vim.api.nvim_win_is_valid(init_win) then
    pcall(vim.api.nvim_win_set_cursor, init_win, { math.min(3, vim.api.nvim_buf_line_count(buf)), 0 })
  end

  -- Auto-refresh Explorer whenever a Denote note is renamed or created anywhere
  local exp_augroup = vim.api.nvim_create_augroup("denote_explorer_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = exp_augroup,
    pattern = { "DenoteRenameFile", "DenoteNewNote" },
    callback = function(ev)
      if not vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_del_augroup_by_id, exp_augroup)
        return
      end
      if ev.data and ev.data.old_path and state.marked[ev.data.old_path] then
        state.marked[ev.data.old_path] = nil
      end
      vim.schedule(render)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = exp_augroup,
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, exp_augroup)
    end,
  })

  local function current_file()
    return state.rows[vim.api.nvim_win_get_cursor(0)[1]]
  end

  local function target_files()
    local marked_list = {}
    for p, v in pairs(state.marked) do
      if v and utils.exists(p) then
        marked_list[#marked_list + 1] = p
      end
    end
    if #marked_list > 0 then
      table.sort(marked_list)
      return marked_list
    end
    local f = current_file()
    return f and { f } or {}
  end

  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "denote: " .. desc })
  end

  map("<CR>", function()
    local f = current_file()
    if f then
      utils.open_file(f, "edit")
    end
  end, "open note")
  map("o", function()
    local f = current_file()
    if f then
      utils.open_file(f, "other")
    end
  end, "open note in other window")
  map("v", function()
    local f = current_file()
    if f then
      utils.open_file(f, "vsplit")
    end
  end, "open note in vsplit")
  map("s", function()
    local f = current_file()
    if f then
      utils.open_file(f, "split")
    end
  end, "open note in split")

  map("m", function()
    local f = current_file()
    if f then
      state.marked[f] = true
      render()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if row < vim.api.nvim_buf_line_count(buf) then
        vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      end
    end
  end, "mark file")
  map("u", function()
    local f = current_file()
    if f then
      state.marked[f] = nil
      render()
    end
  end, "unmark file")
  map("U", function()
    state.marked = {}
    render()
  end, "unmark all")

  map("/", function()
    vim.ui.input({ prompt = "Filter regexp: ", default = state.regexp }, function(input)
      if input ~= nil then
        state.regexp = vim.trim(input)
        render()
      end
    end)
  end, "filter by regexp")
  map("f", function()
    vim.ui.input({ prompt = "Filter regexp: ", default = state.regexp }, function(input)
      if input ~= nil then
        state.regexp = vim.trim(input)
        render()
      end
    end)
  end, "filter by regexp")
  map("x", function()
    vim.ui.input({ prompt = "Exclude regexp: ", default = state.exclude_regexp }, function(input)
      if input ~= nil then
        state.exclude_regexp = vim.trim(input)
        render()
      end
    end)
  end, "exclude by regexp")
  map("k", function()
    local kws = files.keywords(state.dir)
    local items = {}
    for _, kw in ipairs(kws) do
      items[#items + 1] = { display = { { kw, "DenoteKeywords" } }, text = kw, value = kw }
    end
    pickers.pick({
      title = "Filter by Keyword",
      items = items,
      preview = false,
      on_choice = function(chosen)
        if chosen[1] then
          state.keyword = chosen[1].value
          render()
        end
      end,
    })
  end, "filter by keyword")
  map("c", function()
    state.regexp = ""
    state.exclude_regexp = ""
    state.keyword = ""
    render()
  end, "clear filters")

  map("S", function()
    local items = {}
    for _, comp in ipairs(sort.COMPONENTS) do
      items[#items + 1] = {
        display = { { comp, comp == state.sort_by and "DenoteIdentifier" or "DenoteTitle" } },
        text = comp,
        value = comp,
      }
    end
    pickers.pick({
      title = "Sort By Component",
      items = items,
      preview = false,
      on_choice = function(chosen)
        if chosen[1] then
          state.sort_by = chosen[1].value
          -- Identifier & last-modified default newest-first; signature/title/keywords ascending
          state.reverse = (state.sort_by == "identifier" or state.sort_by == "last-modified")
          render()
        end
      end,
    })
  end, "sort by component")
  map("r", function()
    state.reverse = not state.reverse
    render()
  end, "reverse sort order")

  map("G", function()
    local targets = target_files()
    if #targets == 0 then
      targets = collect_files()
    end
    require("denote.query").grep(nil, { dir = state.dir, files = targets })
  end, "grep marked / visible files")

  map("L", function()
    local targets = target_files()
    if #targets == 0 then
      return
    end
    local links = require("denote.links")
    local syntax = vim.api.nvim_buf_is_valid(origin_buf) and links.buffer_syntax(origin_buf) or "markdown"
    local out = {}
    for _, p in ipairs(targets) do
      local id = naming.retrieve_identifier(p)
      if id then
        out[#out + 1] = "- " .. links.format_link(id, links.default_description(p), { syntax = syntax, file_path = p })
      end
    end
    if #out == 0 then
      return
    end
    if vim.api.nvim_buf_is_valid(origin_buf) and vim.bo[origin_buf].buftype == "" and vim.bo[origin_buf].modifiable then
      local lc = vim.api.nvim_buf_line_count(origin_buf)
      vim.api.nvim_buf_set_lines(origin_buf, lc, lc, false, out)
      utils.notify(
        string.format(
          "Inserted %d link(s) into %s",
          #out,
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(origin_buf), ":t")
        )
      )
    else
      vim.fn.setreg('"', table.concat(out, "\n") .. "\n")
      utils.notify(string.format("Yanked %d link(s) to default register", #out))
    end
  end, "link marked notes into previous buffer")

  map("R", function()
    local targets = target_files()
    if #targets == 0 then
      return
    end
    if #targets == 1 then
      local target = targets[1]
      rename.rename_file(target, function(new_path)
        if new_path then
          state.marked[target] = nil
        end
        render()
      end)
      return
    end
    -- Batch actions on marked files (matching denote-dired-rename-marked-files*)
    local actions = {
      { display = { { "Set/replace keywords on marked files", "DenoteTitle" } }, value = "set_kw" },
      { display = { { "Add keywords to marked files", "DenoteTitle" } }, value = "add_kw" },
      { display = { { "Remove keywords from marked files", "DenoteTitle" } }, value = "rem_kw" },
      { display = { { "Sync filenames from front matter", "DenoteTitle" } }, value = "from_fm" },
      { display = { { "Add front matter to marked files", "DenoteTitle" } }, value = "add_fm" },
    }
    pickers.pick({
      title = string.format("Batch Rename (%d marked files)", #targets),
      items = actions,
      preview = false,
      on_choice = function(chosen)
        if not chosen[1] then
          return
        end
        local act = chosen[1].value
        if act == "set_kw" then
          vim.ui.input({ prompt = "Set keywords on marked files: " }, function(input)
            if input ~= nil then
              for _, f in ipairs(targets) do
                rename.rename_sync({ file = f, keywords = utils.parse_keywords_input(input) })
              end
              state.marked = {}
              render()
            end
          end)
        elseif act == "add_kw" then
          vim.ui.input({ prompt = "Keywords to add: " }, function(input)
            if input and vim.trim(input) ~= "" then
              for _, f in ipairs(targets) do
                rename.keywords_add(input, f)
              end
              state.marked = {}
              render()
            end
          end)
        elseif act == "rem_kw" then
          vim.ui.input({ prompt = "Keywords to remove: " }, function(input)
            if input and vim.trim(input) ~= "" then
              for _, f in ipairs(targets) do
                rename.keywords_remove(input, f)
              end
              state.marked = {}
              render()
            end
          end)
        elseif act == "from_fm" then
          for _, f in ipairs(targets) do
            rename.rename_file_using_front_matter(f)
          end
          state.marked = {}
          render()
        elseif act == "add_fm" then
          for _, f in ipairs(targets) do
            rename.add_front_matter(f)
          end
          state.marked = {}
          render()
        end
      end,
    })
  end, "rename file / batch rename marked")

  map("D", function()
    local targets = target_files()
    if #targets == 0 then
      return
    end
    local msg = #targets == 1 and ("Delete " .. vim.fn.fnamemodify(targets[1], ":t") .. "?")
      or string.format("Delete %d marked files?", #targets)
    if vim.fn.confirm(msg, "&No\n&Yes", 1) == 2 then
      for _, f in ipairs(targets) do
        local b = utils.find_buffer(f)
        if b then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
        os.remove(f)
        state.marked[f] = nil
      end
      render()
    end
  end, "delete file(s)")

  map("n", function()
    create.note({
      dir = state.dir,
      save = true,
      on_created = function()
        if vim.api.nvim_buf_is_valid(buf) then
          render()
        end
      end,
    })
  end, "create new note")

  map("a", function()
    state.denote_only = not state.denote_only
    render()
  end, "toggle denote-only / all files")

  map("g", render, "refresh")
  map("q", function()
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 and vim.api.nvim_win_is_valid(win) and origin_buf ~= buf and vim.api.nvim_buf_is_valid(origin_buf) then
      pcall(vim.api.nvim_win_set_buf, win, origin_buf)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end, "close explorer")
  map("g?", function()
    require("denote.ui").show_help("Denote Explorer", {
      { "<CR> / o / v / s", "Open note (current / other / vsplit / split)" },
      { "n", "Create a new note in this directory" },
      { "/ or f", "Filter by filename regexp" },
      { "k", "Filter by keyword" },
      { "x", "Exclude by filename regexp" },
      { "c", "Clear all filters" },
      { "S / r", "Change sort component / reverse sort order" },
      { "m / u / U", "Mark / unmark / unmark all files" },
      { "G / L", "Grep marked files / link marked notes into previous buffer" },
      { "R", "Rename file at cursor (or batch rename marked files)" },
      { "D", "Delete file(s) with confirmation" },
      { "a", "Toggle Denote-only vs all files (e.g. PDFs, images)" },
      { "g / q", "Refresh / close explorer" },
    })
  end, "help")

  return buf
end

--- Prompt for a regexp and sort component, then open the explorer (`denote-sort-dired`).
---@param opts? { dir?: string }
function M.sort_dired(opts)
  opts = opts or {}
  vim.ui.input({ prompt = "Match files regexp (empty for all): " }, function(regexp)
    if regexp == nil then
      return
    end
    local items = {}
    for _, comp in ipairs(sort.COMPONENTS) do
      items[#items + 1] = { display = { { comp, "DenoteTitle" } }, text = comp, value = comp }
    end
    pickers.pick({
      title = "Sort By Component",
      items = items,
      preview = false,
      on_choice = function(chosen)
        if chosen[1] then
          M.open({
            dir = opts.dir,
            regexp = vim.trim(regexp),
            sort_by = chosen[1].value,
            reverse = false,
          })
        end
      end,
    })
  end)
end

return M
