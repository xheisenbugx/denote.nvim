---@mod denote.commands :Denote command dispatcher and tab completion

local M = {}

--- Map of `:Denote <subcommand>` -> handler function(args).
---@return table<string, fun(args: string[])>
local function subcommands()
  local d = require("denote")
  return {
    note = function(args)
      if #args > 0 then
        d.note({ title = table.concat(args, " "), keywords = {}, interactive = false })
      else
        d.note()
      end
    end,
    open = function()
      d.open_or_create()
    end,
    open_or_create = function()
      d.open_or_create()
    end,
    open_with_command = function()
      d.open_or_create_with_command()
    end,
    type = function()
      d.type()
    end,
    date = function()
      d.date()
    end,
    subdirectory = function()
      d.subdirectory()
    end,
    template = function()
      d.template()
    end,
    signature = function()
      d.signature()
    end,
    link = function()
      d.link()
    end,
    link_id_only = function()
      d.link({ id_only = true })
    end,
    link_or_create = function()
      d.link_or_create()
    end,
    link_or_create_with_command = function()
      d.link_or_create_with_command()
    end,
    link_after_creating = function()
      d.link_after_creating()
    end,
    link_to_heading = function()
      d.link_to_heading()
    end,
    link_to_file_with_contents = function(args)
      d.link_to_file_with_contents(#args > 0 and table.concat(args, " ") or nil)
    end,
    link_to_all_files_with_contents = function(args)
      d.link_to_all_files_with_contents(#args > 0 and table.concat(args, " ") or nil)
    end,
    add_links = function(args)
      d.add_links(#args > 0 and table.concat(args, " ") or nil)
    end,
    follow = function()
      d.follow_link()
    end,
    find_link = function()
      d.find_link()
    end,
    backlinks = function()
      d.backlinks()
    end,
    find_backlink = function()
      d.find_backlink()
    end,
    find_backlink_with_location = function()
      d.find_backlink_with_location()
    end,
    grep = function(args)
      d.grep(#args > 0 and table.concat(args, " ") or nil)
    end,
    query_contents_link = function(args)
      d.query_contents_link(#args > 0 and table.concat(args, " ") or nil)
    end,
    query_filenames_link = function(args)
      d.query_filenames_link(#args > 0 and table.concat(args, " ") or nil)
    end,
    explorer = function(args)
      d.explorer({ regexp = #args > 0 and table.concat(args, " ") or nil })
    end,
    sort_dired = function()
      d.sort_dired()
    end,
    rename = function()
      d.rename_file()
    end,
    rename_title = function()
      d.rename_file_title()
    end,
    rename_keywords = function()
      d.rename_file_keywords()
    end,
    rename_signature = function()
      d.rename_file_signature()
    end,
    rename_date = function()
      d.rename_file_date()
    end,
    rename_identifier = function()
      d.rename_file_identifier()
    end,
    rename_from_front_matter = function()
      d.rename_file_using_front_matter()
    end,
    change_file_type = function(args)
      d.change_file_type_and_front_matter(nil, #args > 0 and args[1] or nil)
    end,
    add_front_matter = function()
      d.add_front_matter()
    end,
    keywords_add = function(args)
      d.keywords_add(#args > 0 and args or nil)
    end,
    keywords_remove = function(args)
      d.keywords_remove(#args > 0 and args or nil)
    end,
    convert_to_file_links = function()
      local n = d.convert_links_to_file_paths()
      require("denote.utils").notify(string.format("Converted %d link(s) to file paths", n))
    end,
    convert_to_denote_links = function()
      local n = d.convert_links_to_denote_paths()
      require("denote.utils").notify(string.format("Converted %d link(s) to denote: links", n))
    end,
    journal = function(args)
      d.journal_new_or_existing_entry({ date = #args > 0 and table.concat(args, " ") or nil })
    end,
    journal_new = function(args)
      d.journal_new_entry({ date = #args > 0 and table.concat(args, " ") or nil })
    end,
    journal_link = function(args)
      d.journal_link_or_create_entry({ date = #args > 0 and table.concat(args, " ") or nil })
    end,
    journal_calendar = function(args)
      d.journal_calendar({ date = #args > 0 and table.concat(args, " ") or nil })
    end,
    sequence_parent = function()
      d.sequence_new_parent()
    end,
    sequence_child = function()
      d.sequence_new_child()
    end,
    sequence_sibling = function()
      d.sequence_new_sibling()
    end,
    sequence_find = function()
      d.sequence_find()
    end,
    sequence_relatives = function()
      d.sequence_find_relatives()
    end,
    sequence_link = function()
      d.sequence_link()
    end,
    sequence_reparent = function()
      d.sequence_reparent()
    end,
    silo_create = function()
      d.silo_create_note()
    end,
    silo_open = function()
      d.silo_open_or_create()
    end,
    silo_explorer = function()
      d.silo_explorer()
    end,
    silo_switch = function(args)
      if #args > 0 then
        d.silo_switch(table.concat(args, " "))
      else
        require("denote.silo").pick(function(dir)
          d.silo_switch(dir)
        end, "Switch Active Silo")
      end
    end,
    dblock_links = function(args)
      d.org_dblock_insert_links(#args > 0 and table.concat(args, " ") or nil)
    end,
    dblock_backlinks = function()
      d.org_dblock_insert_backlinks()
    end,
    dblock_files = function(args)
      d.org_dblock_insert_files(#args > 0 and table.concat(args, " ") or nil)
    end,
    preview = function()
      d.preview()
    end,
    unlinked_mentions = function()
      d.unlinked_mentions()
    end,
    link_mention = function()
      d.link_mention()
    end,
    check = function()
      d.check()
    end,
    reindex = function()
      require("denote.files").invalidate()
      require("denote.frontmatter").clear_cache()
      require("denote.backlinks").clear_cache()
      require("denote.search").reset()
      require("denote.utils").notify("Denote index cleared")
    end,
    capture = function(args)
      d.capture({ key = args[1] })
    end,
    dblock_update = function()
      local n = d.org_dblock_update()
      require("denote.utils").notify(string.format("Updated %d dynamic block(s)", n))
    end,
  }
end

--- Register `:Denote` and `:DenoteRegion` user commands.
function M.register()
  vim.api.nvim_create_user_command("Denote", function(cmd_opts)
    require("denote.ui").ensure_highlights()
    local fargs = cmd_opts.fargs or {}
    local sub = fargs[1]
    if not sub or sub == "" then
      require("denote").note()
      return
    end
    local cmds = subcommands()
    local handler = cmds[sub]
    if not handler then
      require("denote.utils").error("Unknown Denote subcommand: " .. sub)
      return
    end
    local rest = vim.list_slice(fargs, 2)
    handler(rest)
  end, {
    nargs = "*",
    desc = "Denote note-taking command dispatcher",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local up_to_cursor = cursor_pos and cmd_line:sub(1, cursor_pos) or cmd_line
      local ends_ws = up_to_cursor:match("%s$") ~= nil
      local parts = vim.split(up_to_cursor, "%s+", { trimempty = true })
      local arg_idx = #parts + (ends_ws and 1 or 0)
      local function filter(list)
        return vim.tbl_filter(function(name)
          return name:sub(1, #arg_lead) == arg_lead
        end, list)
      end
      if arg_idx <= 2 then
        local names = vim.tbl_keys(subcommands())
        table.sort(names)
        return filter(names)
      end
      local sub = parts[2]
      if arg_idx == 3 then
        if sub == "capture" then
          return filter(require("denote.capture").keys())
        elseif sub == "change_file_type" then
          local fts = vim.tbl_keys(require("denote.frontmatter").file_types())
          table.sort(fts)
          return filter(fts)
        elseif sub == "silo_switch" then
          return filter(require("denote.silo").list())
        end
      end
      if sub == "keywords_add" then
        return filter(require("denote.files").keywords())
      elseif sub == "keywords_remove" then
        local path = vim.api.nvim_buf_get_name(0)
        local kws = path ~= "" and require("denote.naming").parse_filename(path).keywords or {}
        return filter(kws)
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("DenoteRegion", function(cmd_opts)
    require("denote.ui").ensure_highlights()
    require("denote").region({ line1 = cmd_opts.line1, line2 = cmd_opts.line2 })
  end, {
    range = true,
    desc = "Create a Denote note from the selected region",
  })

  vim.api.nvim_create_user_command("DenoteCapture", function(cmd_opts)
    require("denote.ui").ensure_highlights()
    require("denote").capture({
      key = cmd_opts.args ~= "" and cmd_opts.args or nil,
      line1 = cmd_opts.range > 0 and cmd_opts.line1 or nil,
      line2 = cmd_opts.range > 0 and cmd_opts.line2 or nil,
    })
  end, {
    range = true,
    nargs = "?",
    complete = function(arg_lead)
      return vim.tbl_filter(function(k)
        return k:sub(1, #arg_lead) == arg_lead
      end, require("denote.capture").keys())
    end,
    desc = "Capture a Denote note from a capture template (range: selection becomes %i)",
  })

  vim.api.nvim_create_user_command("DenoteGrepRegion", function(cmd_opts)
    require("denote.ui").ensure_highlights()
    require("denote").grep_files_referenced_in_region(
      cmd_opts.args ~= "" and cmd_opts.args or nil,
      { line1 = cmd_opts.line1, line2 = cmd_opts.line2 }
    )
  end, {
    range = true,
    nargs = "?",
    desc = "Grep inside Denote files referenced in the selected region",
  })
end

return M
