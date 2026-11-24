---@mod denote.mappings Default keymaps, buffer-local link following, and autocmds

local config = require("denote.config")
local links = require("denote.links")
local naming = require("denote.naming")
local ui = require("denote.ui")

local M = {}

local augroup = vim.api.nvim_create_augroup("denote_nvim", { clear = true })

--- Register global keymaps under `config.opts.mappings.prefix` (default `<leader>n`).
function M.setup_global()
  local m = config.opts.mappings
  if not m or m.enabled == false then
    return
  end
  local p = m.prefix or "<leader>n"
  local denote = require("denote")

  local specs = {
    { p .. "n", denote.note, "New note" },
    { p .. "o", denote.open_or_create, "Open or create note" },
    { p .. "t", denote.type, "New note (choose file type)" },
    { p .. "d", denote.date, "New note (custom date)" },
    { p .. "s", denote.subdirectory, "New note (subdirectory)" },
    { p .. "T", denote.template, "New note (template)" },
    { p .. "S", denote.signature, "New note (signature)" },
    { p .. "l", denote.link, "Insert link" },
    { p .. "L", denote.link_or_create, "Link or create note" },
    { p .. "h", denote.link_to_heading, "Link to heading" },
    { p .. "a", denote.add_links, "Add links matching regexp" },
    { p .. "f", denote.find_link, "Find outbound link" },
    { p .. "b", denote.backlinks, "Open backlinks buffer" },
    { p .. "B", denote.find_backlink, "Find backlink (picker)" },
    { p .. "g", denote.grep, "Grep notes" },
    { p .. "u", denote.unlinked_mentions, "Unlinked mentions" },
    { p .. "U", denote.link_mention, "Link mention on this line" },
    { p .. "c", denote.check, "Check broken links & orphans" },
    { p .. "qc", denote.query_contents_link, "Insert query-contents link" },
    { p .. "qf", denote.query_filenames_link, "Insert query-filenames link" },
    { p .. "e", denote.explorer, "Open Denote explorer" },
    { p .. "r", denote.rename_file, "Rename file" },
    { p .. "R", denote.rename_file_using_front_matter, "Rename from front matter" },
    { p .. "k", denote.keywords_add, "Add keywords" },
    { p .. "K", denote.keywords_remove, "Remove keywords" },
    { p .. "j", denote.journal_new_or_existing_entry, "Today's journal entry" },
    { p .. "J", denote.journal_link_or_create_entry, "Link to today's journal" },
    { p .. "C", denote.journal_calendar, "Journal calendar" },
    { p .. "zp", denote.sequence_new_parent, "Sequence: new parent" },
    { p .. "zc", denote.sequence_new_child, "Sequence: new child" },
    { p .. "zs", denote.sequence_new_sibling, "Sequence: new sibling" },
    { p .. "zf", denote.sequence_find, "Sequence: find note" },
    { p .. "zr", denote.sequence_find_relatives, "Sequence: find relatives" },
    { p .. "zl", denote.sequence_link, "Sequence: insert link" },
    { p .. "wc", denote.silo_create_note, "Silo: create note" },
    { p .. "wo", denote.silo_open_or_create, "Silo: open or create" },
    { p .. "we", denote.silo_explorer, "Silo: explorer" },
  }

  for _, s in ipairs(specs) do
    vim.keymap.set("n", s[1], s[2], { desc = "Denote: " .. s[3], silent = true })
  end

  -- Visual mode: create note from region
  vim.keymap.set("x", p .. "n", ":<C-u>DenoteRegion<CR>", { desc = "Denote: New note from region", silent = true })

  -- Optional which-key group labels
  if config.opts.integrations and config.opts.integrations.which_key ~= false then
    local ok_wk, wk = pcall(require, "which-key")
    if ok_wk and type(wk.add) == "function" then
      pcall(wk.add, {
        { p, group = "denote" },
        { p .. "q", group = "query links" },
        { p .. "z", group = "sequence" },
        { p .. "w", group = "silos" },
      })
    end
  end
end

--- Attach the buffer-local link preview keymap (default `K`). When the cursor is not on a
--- Denote link it falls back to LSP hover (if a client supports it) or the native key.
---@param bufnr integer
function M.attach_preview(bufnr)
  local m = config.opts.mappings
  if not m or not m.preview_link then
    return
  end
  local lhs = m.preview_link
  vim.keymap.set("n", lhs, function()
    if links.link_at_cursor(bufnr) then
      require("denote.preview").open()
      return
    end
    local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
    for _, client in ipairs(get_clients({ bufnr = bufnr })) do
      local supports
      if vim.fn.has("nvim-0.11") == 1 then
        supports = client:supports_method("textDocument/hover")
      else
        supports = client.supports_method("textDocument/hover")
      end
      if supports then
        vim.lsp.buf.hover()
        return
      end
    end
    local key = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    local count = vim.v.count > 0 and tostring(vim.v.count) or ""
    vim.api.nvim_feedkeys(count .. key, "n", false)
  end, { buffer = bufnr, desc = "Denote: Preview linked note" })
end

--- Attach buffer-local link-following keymap to a Markdown / Org / Text buffer.
--- Carefully falls back to the native key behavior when cursor is NOT on a Denote link.
---@param bufnr integer
function M.attach_buffer(bufnr)
  local m = config.opts.mappings
  if not m then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if ft ~= "markdown" and ft ~= "md" and ft ~= "text" and ft ~= "org" then
    return
  end
  M.attach_preview(bufnr)
  if not m.follow_link then
    return
  end
  -- In Org buffers when org.nvim is installed/attached, org.nvim handles <CR> via `links.types.denote`
  if ft == "org" and (package.loaded["org"] or require("denote.integrations.org").is_attached()) then
    return
  end

  local lhs = m.follow_link
  vim.keymap.set("n", lhs, function()
    if links.link_at_cursor(bufnr) then
      links.follow_link()
      return
    end
    if m.follow_link_fallback ~= false then
      local key = vim.api.nvim_replace_termcodes(lhs, true, false, true)
      local count = vim.v.count > 0 and tostring(vim.v.count) or ""
      vim.api.nvim_feedkeys(count .. key, "n", false)
    end
  end, { buffer = bufnr, desc = "Denote: Follow link at cursor" })
end

local decorate_timers = {}

--- Re-decorate `bufnr` after `ui.debounce_ms`, coalescing bursts of events into one pass.
---@param bufnr integer
function M.schedule_decorate(bufnr)
  local uv = vim.uv or vim.loop
  local delay = (config.opts.ui and config.opts.ui.debounce_ms) or 150
  local timer = decorate_timers[bufnr]
  if not timer then
    timer = uv.new_timer()
    decorate_timers[bufnr] = timer
  end
  timer:stop()
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      timer:stop()
      timer:close()
      decorate_timers[bufnr] = nil
      if vim.api.nvim_buf_is_valid(bufnr) then
        ui.decorate_buffer(bufnr)
      end
    end)
  )
end

--- Register autocmds for link highlighting, org.nvim integration, buffer keymaps, and optional auto-rename.
function M.setup_autocmds()
  vim.api.nvim_clear_autocmds({ group = augroup })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      ui.setup_highlights()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
    group = augroup,
    callback = function(ev)
      local bufnr = ev.buf
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local ft = vim.bo[bufnr].filetype
      if ft == "org" and config.opts.integrations and config.opts.integrations.org ~= false then
        local org_int = require("denote.integrations.org")
        if not org_int.is_attached() then
          org_int.attach()
        end
      end
      if ft == "markdown" or ft == "md" or ft == "text" or ft == "org" then
        M.attach_buffer(bufnr)
        ui.decorate_buffer(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave", "FocusGained" }, {
    group = augroup,
    callback = function(ev)
      local bufnr = ev.buf
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local ft = vim.bo[bufnr].filetype
      if ft == "markdown" or ft == "md" or ft == "text" or ft == "org" then
        M.schedule_decorate(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if path ~= "" and naming.is_denote_file(path) then
        require("denote.files").touch()
      end
      if not config.opts.auto_rename_on_save then
        return
      end
      local rename = require("denote.rename")
      if rename.is_renaming(ev.buf) then
        return
      end
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if path ~= "" and naming.is_denote_file(path) then
        rename.rename_file_using_front_matter(path)
      end
    end,
  })
end

return M
