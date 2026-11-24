---@mod denote Emacs Denote, rebuilt for Neovim in pure Lua
---
--- File-naming-first note-taking for Neovim with zero dependencies, full
--- Org mode (`org.nvim`), Markdown (YAML & TOML), and plain text support,
--- backlinks, live query links, explorer, silos, daily journal, and
--- Folgezettel sequences.

local config = require("denote.config")

local M = {}

--- Initialize denote.nvim with user configuration.
---@param opts? table
---@return denote.Config
function M.setup(opts)
  local cfg = config.setup(opts)
  require("denote.ui").setup_highlights()
  require("denote.commands").register()
  require("denote.mappings").setup_global()
  require("denote.mappings").setup_autocmds()

  if cfg.integrations and cfg.integrations.org ~= false then
    require("denote.integrations.org").attach()
  end

  return cfg
end

-- Creation
M.note = function(...)
  return require("denote.create").note(...)
end
M.create_sync = function(...)
  return require("denote.create").create_sync(...)
end
M.type = function(...)
  return require("denote.create").type(...)
end
M.date = function(...)
  return require("denote.create").date(...)
end
M.subdirectory = function(...)
  return require("denote.create").subdirectory(...)
end
M.template = function(...)
  return require("denote.create").template(...)
end
M.signature = function(...)
  return require("denote.create").signature(...)
end
M.open_or_create = function(...)
  return require("denote.create").open_or_create(...)
end
M.open_or_create_with_command = function(...)
  return require("denote.create").open_or_create_with_command(...)
end
M.region = function(...)
  return require("denote.create").region(...)
end
M.capture = function(...)
  return require("denote.capture").capture(...)
end

-- Renaming & Front Matter
M.rename_file = function(...)
  return require("denote.rename").rename_file(...)
end
M.rename_sync = function(...)
  return require("denote.rename").rename_sync(...)
end
M.rename_file_title = function(...)
  return require("denote.rename").rename_file_title(...)
end
M.rename_file_keywords = function(...)
  return require("denote.rename").rename_file_keywords(...)
end
M.rename_file_signature = function(...)
  return require("denote.rename").rename_file_signature(...)
end
M.rename_file_date = function(...)
  return require("denote.rename").rename_file_date(...)
end
M.rename_file_identifier = function(...)
  return require("denote.rename").rename_file_identifier(...)
end
M.rename_file_using_front_matter = function(...)
  return require("denote.rename").rename_file_using_front_matter(...)
end
M.change_file_type_and_front_matter = function(...)
  return require("denote.rename").change_file_type_and_front_matter(...)
end
M.add_front_matter = function(...)
  return require("denote.rename").add_front_matter(...)
end
M.keywords_add = function(...)
  return require("denote.rename").keywords_add(...)
end
M.keywords_remove = function(...)
  return require("denote.rename").keywords_remove(...)
end
M.statusline = function(...)
  return require("denote.rename").format_buffer_name(...)
end

-- Linking & Navigation
M.link = function(...)
  return require("denote.links").link(...)
end
M.link_or_create = function(...)
  return require("denote.links").link_or_create(...)
end
M.link_or_create_with_command = function(...)
  return require("denote.links").link_or_create_with_command(...)
end
M.link_after_creating = function(...)
  return require("denote.links").link_after_creating(...)
end
M.link_to_heading = function(...)
  return require("denote.links").link_to_heading(...)
end
M.link_to_file_with_contents = function(...)
  return require("denote.links").link_to_file_with_contents(...)
end
M.link_to_all_files_with_contents = function(...)
  return require("denote.links").link_to_all_files_with_contents(...)
end
M.add_links = function(...)
  return require("denote.links").add_links(...)
end
M.follow_link = function(...)
  return require("denote.links").follow_link(...)
end
M.follow_target = function(...)
  return require("denote.links").follow_target(...)
end
M.find_link = function(...)
  return require("denote.links").find_link(...)
end
M.convert_links_to_file_paths = function(...)
  return require("denote.links").convert_links_to_file_paths(...)
end
M.convert_links_to_denote_paths = function(...)
  return require("denote.links").convert_links_to_denote_paths(...)
end

-- Backlinks & Query / Grep
M.backlinks = function(...)
  return require("denote.backlinks").open(...)
end
M.find_backlink = function(...)
  return require("denote.backlinks").find_backlink(...)
end
M.find_backlink_with_location = function(...)
  return require("denote.backlinks").find_backlink_with_location(...)
end
M.grep = function(...)
  return require("denote.query").grep(...)
end
M.grep_files_referenced_in_region = function(...)
  return require("denote.query").grep_files_referenced_in_region(...)
end
M.query_contents_link = function(...)
  return require("denote.query").query_contents_link(...)
end
M.query_filenames_link = function(...)
  return require("denote.query").query_filenames_link(...)
end

-- Preview & Reports
M.preview = function(...)
  return require("denote.preview").open(...)
end
M.unlinked_mentions = function(...)
  return require("denote.report").unlinked_mentions(...)
end
M.link_mention = function(...)
  return require("denote.report").link_mention(...)
end
M.check = function(...)
  return require("denote.report").check(...)
end

-- Explorer & Sort
M.explorer = function(...)
  return require("denote.explorer").open(...)
end
M.sort_dired = function(...)
  return require("denote.explorer").sort_dired(...)
end

-- Journal
M.journal_new_entry = function(...)
  return require("denote.journal").new_entry(...)
end
M.journal_new_or_existing_entry = function(...)
  return require("denote.journal").new_or_existing_entry(...)
end
M.journal_link_or_create_entry = function(...)
  return require("denote.journal").link_or_create_entry(...)
end
M.journal_calendar = function(...)
  return require("denote.calendar").open(...)
end

-- Sequences (Folgezettel)
M.sequence_new_parent = function(...)
  return require("denote.sequence").new_parent(...)
end
M.sequence_new_child = function(...)
  return require("denote.sequence").new_child(...)
end
M.sequence_new_sibling = function(...)
  return require("denote.sequence").new_sibling(...)
end
M.sequence_find = function(...)
  return require("denote.sequence").find(...)
end
M.sequence_find_relatives = function(...)
  return require("denote.sequence").find_relatives(...)
end
M.sequence_link = function(...)
  return require("denote.sequence").link(...)
end
M.sequence_reparent = function(...)
  return require("denote.sequence").reparent(...)
end

-- Silos
M.silo_create_note = function(...)
  return require("denote.silo").create_note(...)
end
M.silo_open_or_create = function(...)
  return require("denote.silo").open_or_create(...)
end
M.silo_explorer = function(...)
  return require("denote.silo").explorer(...)
end
M.silo_switch = function(...)
  return require("denote.silo").switch(...)
end

-- Org Dynamic Blocks
M.org_dblock_insert_links = function(...)
  return require("denote.integrations.org").dblock_insert_links(...)
end
M.org_dblock_insert_backlinks = function(...)
  return require("denote.integrations.org").dblock_insert_backlinks(...)
end
M.org_dblock_insert_files = function(...)
  return require("denote.integrations.org").dblock_insert_files(...)
end
M.org_dblock_update = function(...)
  return require("denote.integrations.org").update_dblocks(...)
end

return M
