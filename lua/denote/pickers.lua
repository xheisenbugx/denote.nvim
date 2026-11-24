---@mod denote.pickers Unified zero-dependency picker layer
---
--- Supports snacks.nvim, fzf-lua, telescope.nvim, mini.pick, and Neovim's
--- built-in `vim.ui.select`. Backends are loaded lazily with `pcall(require)`
--- only when a picker opens.

local config = require("denote.config")
local frontmatter = require("denote.frontmatter")
local naming = require("denote.naming")
local utils = require("denote.utils")

local M = {}

---@class denote.PickerItem
---@field display { [1]: string, [2]?: string }[] Highlighted chunks
---@field text? string Plain searchable text
---@field filename? string File path for preview
---@field lnum? integer 1-based line number for preview
---@field value any Value returned to on_choice

---@class denote.PickerSpec
---@field title string
---@field items denote.PickerItem[]
---@field multi? boolean
---@field allow_query? boolean Allow confirming typed query even when no item matches
---@field create_label? string Label offered in select/mini when allow_query is true
---@field preview? boolean
---@field on_choice fun(items: denote.PickerItem[], query?: string, how?: string)
---@field on_cancel? fun()

--- Extract plain text from a PickerItem.
---@param item denote.PickerItem
---@return string
function M.item_text(item)
  if item.text then
    return item.text
  end
  local parts = {}
  for i, chunk in ipairs(item.display or {}) do
    parts[i] = chunk[1]
  end
  return table.concat(parts)
end

--- Resolve the active picker backend name.
---@return "snacks"|"fzf-lua"|"telescope"|"mini"|"select"
function M.resolve_backend()
  local pref = config.opts.picker or "auto"
  if pref ~= "auto" then
    return pref
  end
  if _G.Snacks and _G.Snacks.picker then
    return "snacks"
  end
  if pcall(require, "fzf-lua") then
    return "fzf-lua"
  end
  if pcall(require, "telescope.pickers") then
    return "telescope"
  end
  if pcall(require, "mini.pick") then
    return "mini"
  end
  return "select"
end

--- Build a rich PickerItem for a Denote file path.
---@param path string
---@param opts? { dir?: string, read_title?: boolean }
---@return denote.PickerItem
function M.file_item(path, opts)
  opts = opts or {}
  local parsed = naming.parse_filename(path)
  local chunks = {}

  if parsed.identifier then
    chunks[#chunks + 1] = { parsed.identifier, "DenoteIdentifier" }
  end
  if parsed.signature then
    chunks[#chunks + 1] = { " ==" .. parsed.signature, "DenoteSignature" }
  end

  local title = opts.read_title and frontmatter.extract_title(path)
    or (parsed.title and naming.desluggify("title", parsed.title) or parsed.filename)
  chunks[#chunks + 1] = { "  " .. title, "DenoteTitle" }

  if #parsed.keywords > 0 then
    chunks[#chunks + 1] = { "  [" .. table.concat(parsed.keywords, ", ") .. "]", "DenoteKeywords" }
  end
  if parsed.extension ~= "" then
    chunks[#chunks + 1] = { " " .. parsed.extension, "DenoteExtension" }
  end

  local text_parts = {
    parsed.identifier or "",
    parsed.signature or "",
    title,
    table.concat(parsed.keywords, " "),
    parsed.filename,
  }

  return {
    display = chunks,
    text = table.concat(text_parts, " "),
    filename = path,
    value = path,
  }
end

--- Backend: snacks.picker
local function pick_snacks(spec)
  local snacks_items = {}
  for idx, item in ipairs(spec.items) do
    snacks_items[idx] = {
      idx = idx,
      text = M.item_text(item),
      file = item.filename,
      pos = item.lnum and { item.lnum, 0 } or nil,
      _denote_item = item,
    }
  end

  local handled = false
  local function finish(picker, how)
    handled = true
    local query = picker.input and picker.input:get() or ""
    local selected = picker:selected({ fallback = true })
    picker:close()
    local chosen = {}
    for _, s in ipairs(selected or {}) do
      if s._denote_item then
        chosen[#chosen + 1] = s._denote_item
      end
    end
    vim.schedule(function()
      spec.on_choice(chosen, query, how)
    end)
  end

  _G.Snacks.picker.pick({
    title = spec.title,
    items = snacks_items,
    layout = spec.preview == false and { preset = "select" } or nil,
    format = function(sitem)
      local out = {}
      for _, c in ipairs(sitem._denote_item.display or {}) do
        out[#out + 1] = { c[1], c[2] }
      end
      return out
    end,
    confirm = function(picker)
      finish(picker, "edit")
    end,
    actions = {
      denote_query = function(picker)
        handled = true
        local query = picker.input and picker.input:get() or ""
        picker:close()
        vim.schedule(function()
          spec.on_choice({}, query, "edit")
        end)
      end,
      denote_split = function(picker)
        finish(picker, "split")
      end,
      denote_vsplit = function(picker)
        finish(picker, "vsplit")
      end,
    },
    win = {
      input = {
        keys = {
          ["<M-CR>"] = spec.allow_query and { "denote_query", mode = { "i", "n" } } or nil,
          ["<C-s>"] = { "denote_split", mode = { "i", "n" } },
          ["<C-v>"] = { "denote_vsplit", mode = { "i", "n" } },
        },
      },
    },
    on_close = function()
      if not handled and spec.on_cancel then
        spec.on_cancel()
      end
    end,
  })
end

--- Backend: telescope.nvim
local function pick_telescope(spec)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = spec.title,
      finder = finders.new_table({
        results = spec.items,
        entry_maker = function(item)
          local line = M.item_text(item)
          return {
            value = item,
            display = line,
            ordinal = line,
            filename = item.filename,
            lnum = item.lnum,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = spec.preview ~= false and conf.grep_previewer({}) or nil,
      attach_mappings = function(prompt_bufnr, map)
        local function submit(how)
          local picker = action_state.get_current_picker(prompt_bufnr)
          local query = action_state.get_current_line()
          local multi = picker:get_multi_selection()
          local chosen = {}
          if multi and #multi > 0 then
            for _, entry in ipairs(multi) do
              chosen[#chosen + 1] = entry.value
            end
          else
            local entry = action_state.get_selected_entry()
            if entry then
              chosen[1] = entry.value
            end
          end
          actions.close(prompt_bufnr)
          spec.on_choice(chosen, query, how)
        end

        actions.select_default:replace(function()
          submit("edit")
        end)
        actions.select_horizontal:replace(function()
          submit("split")
        end)
        actions.select_vertical:replace(function()
          submit("vsplit")
        end)
        if spec.allow_query then
          map({ "i", "n" }, "<M-CR>", function()
            local query = action_state.get_current_line()
            actions.close(prompt_bufnr)
            spec.on_choice({}, query, "edit")
          end)
        end
        return true
      end,
    })
    :find()
end

--- Backend: fzf-lua
local function pick_fzf_lua(spec)
  local fzf = require("fzf-lua")
  local lines = {}
  local map = {}
  for idx, item in ipairs(spec.items) do
    local key = string.format("%d\t%s", idx, M.item_text(item))
    lines[idx] = key
    map[key] = item
  end
  fzf.fzf_exec(lines, {
    prompt = spec.title .. "> ",
    fzf_opts = {
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      ["--multi"] = spec.multi and "" or nil,
    },
    actions = {
      ["default"] = function(selected, opts)
        local chosen = {}
        for _, line in ipairs(selected or {}) do
          if map[line] then
            chosen[#chosen + 1] = map[line]
          end
        end
        spec.on_choice(chosen, opts and opts.last_query or "", "edit")
      end,
      ["ctrl-s"] = function(selected, opts)
        local chosen = {}
        for _, line in ipairs(selected or {}) do
          if map[line] then
            chosen[#chosen + 1] = map[line]
          end
        end
        spec.on_choice(chosen, opts and opts.last_query or "", "split")
      end,
      ["ctrl-v"] = function(selected, opts)
        local chosen = {}
        for _, line in ipairs(selected or {}) do
          if map[line] then
            chosen[#chosen + 1] = map[line]
          end
        end
        spec.on_choice(chosen, opts and opts.last_query or "", "vsplit")
      end,
    },
  })
end

--- Backend: mini.pick
local function pick_mini(spec)
  local mini_pick = require("mini.pick")
  local items = vim.deepcopy(spec.items)
  local create_sentinel = nil
  if spec.allow_query then
    create_sentinel = {
      display = { { spec.create_label or "+ Create new note...", "Special" } },
      text = spec.create_label or "+ Create new note...",
      _create = true,
    }
    table.insert(items, 1, create_sentinel)
  end

  local choice = mini_pick.start({
    source = {
      name = spec.title,
      items = items,
      show = function(buf_id, arr, query)
        local str_items = vim.tbl_map(M.item_text, arr)
        mini_pick.default_show(buf_id, str_items, query)
      end,
    },
  })
  if not choice then
    if spec.on_cancel then
      spec.on_cancel()
    end
    return
  end
  if choice._create then
    vim.ui.input({ prompt = (spec.create_label or "New note title") .. ": " }, function(input)
      if input then
        spec.on_choice({}, input, "edit")
      end
    end)
  else
    spec.on_choice({ choice }, "", "edit")
  end
end

--- Backend: built-in vim.ui.select (always available, zero dependencies).
local function pick_select(spec)
  local list = {}
  if spec.allow_query then
    list[#list + 1] = {
      display = { { spec.create_label or "+ Create new note...", "Special" } },
      text = spec.create_label or "+ Create new note...",
      _create = true,
    }
  end
  for _, item in ipairs(spec.items) do
    list[#list + 1] = item
  end

  if #list == 0 then
    if spec.allow_query then
      vim.ui.input({ prompt = (spec.create_label or "New note title") .. ": " }, function(input)
        if input then
          spec.on_choice({}, input, "edit")
        elseif spec.on_cancel then
          spec.on_cancel()
        end
      end)
    else
      utils.notify("No items to select")
      if spec.on_cancel then
        spec.on_cancel()
      end
    end
    return
  end

  vim.ui.select(list, {
    prompt = spec.title .. ": ",
    format_item = function(item)
      return M.item_text(item)
    end,
  }, function(choice)
    if not choice then
      if spec.on_cancel then
        spec.on_cancel()
      end
      return
    end
    if choice._create then
      vim.ui.input({ prompt = (spec.create_label or "Title") .. ": " }, function(input)
        if input then
          spec.on_choice({}, input, "edit")
        elseif spec.on_cancel then
          spec.on_cancel()
        end
      end)
    else
      spec.on_choice({ choice }, "", "edit")
    end
  end)
end

--- Open a picker using the configured or auto-detected backend.
---@param spec denote.PickerSpec
function M.pick(spec)
  local backend = M.resolve_backend()
  if backend == "snacks" then
    local ok = pcall(pick_snacks, spec)
    if ok then
      return
    end
  elseif backend == "fzf-lua" then
    local ok = pcall(pick_fzf_lua, spec)
    if ok then
      return
    end
  elseif backend == "telescope" then
    local ok = pcall(pick_telescope, spec)
    if ok then
      return
    end
  elseif backend == "mini" then
    local ok = pcall(pick_mini, spec)
    if ok then
      return
    end
  end
  pick_select(spec)
end

return M
