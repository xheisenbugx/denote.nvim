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
    dblock_update = function()
      local n = d.org_dblock_update()
      require("denote.utils").notify(string.format("Updated %d dynamic block(s)", n))
    end,
  }
end

--- Register `:Denote` and `:DenoteRegion` user commands.
function M.register()
  vim.api.nvim_create_user_command("Denote", function(cmd_opts)
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
    complete = function(arg_lead, cmd_line)
      local parts = vim.split(cmd_line, "%s+", { trimempty = true })
      if #parts <= 2 and not cmd_line:match("%s$") or (#parts == 1 and cmd_line:match("%s$")) then
        local names = vim.tbl_keys(subcommands())
        table.sort(names)
        return vim.tbl_filter(function(name)
          return name:sub(1, #arg_lead) == arg_lead
        end, names)
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("DenoteRegion", function(cmd_opts)
    require("denote").region({ line1 = cmd_opts.line1, line2 = cmd_opts.line2 })
  end, {
    range = true,
    desc = "Create a Denote note from the selected region",
  })

  vim.api.nvim_create_user_command("DenoteGrepRegion", function(cmd_opts)
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
