---@mod denote Emacs Denote, rebuilt for Neovim in pure Lua
---@brief [[
--- File-naming-first note-taking for Neovim with zero dependencies, full
--- Org mode (`org.nvim`), Markdown (YAML & TOML), and plain text support,
--- backlinks, live query links, explorer, silos, daily journal, and
--- Folgezettel sequences.
---
--- `require("denote")` re-exports the commands of the modules below. Besides
--- the functions listed here, `backlinks()`, `preview()`, and `explorer()` are
--- the same as |denote.backlinks.open|, |denote.preview.open|, and
--- |denote.explorer.open|.
---@brief ]]

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
--- Same as |denote.create.note|.
M.note = function(...)
  return require("denote.create").note(...)
end
--- Same as |denote.create.create_sync|.
M.create_sync = function(...)
  return require("denote.create").create_sync(...)
end
--- Same as |denote.create.type|.
M.type = function(...)
  return require("denote.create").type(...)
end
--- Same as |denote.create.date|.
M.date = function(...)
  return require("denote.create").date(...)
end
--- Same as |denote.create.subdirectory|.
M.subdirectory = function(...)
  return require("denote.create").subdirectory(...)
end
--- Same as |denote.create.template|.
M.template = function(...)
  return require("denote.create").template(...)
end
--- Same as |denote.create.signature|.
M.signature = function(...)
  return require("denote.create").signature(...)
end
--- Same as |denote.create.open_or_create|.
M.open_or_create = function(...)
  return require("denote.create").open_or_create(...)
end
--- Same as |denote.create.open_or_create_with_command|.
M.open_or_create_with_command = function(...)
  return require("denote.create").open_or_create_with_command(...)
end
--- Same as |denote.create.region|.
M.region = function(...)
  return require("denote.create").region(...)
end
M.capture = function(...)
  return require("denote.capture").capture(...)
end

-- Renaming & Front Matter
--- Same as |denote.rename.rename_file|.
M.rename_file = function(...)
  return require("denote.rename").rename_file(...)
end
--- Same as |denote.rename.rename_sync|.
M.rename_sync = function(...)
  return require("denote.rename").rename_sync(...)
end
--- Same as |denote.rename.rename_file_title|.
M.rename_file_title = function(...)
  return require("denote.rename").rename_file_title(...)
end
--- Same as |denote.rename.rename_file_keywords|.
M.rename_file_keywords = function(...)
  return require("denote.rename").rename_file_keywords(...)
end
--- Same as |denote.rename.rename_file_signature|.
M.rename_file_signature = function(...)
  return require("denote.rename").rename_file_signature(...)
end
--- Same as |denote.rename.rename_file_date|.
M.rename_file_date = function(...)
  return require("denote.rename").rename_file_date(...)
end
--- Same as |denote.rename.rename_file_identifier|.
M.rename_file_identifier = function(...)
  return require("denote.rename").rename_file_identifier(...)
end
--- Same as |denote.rename.rename_file_using_front_matter|.
M.rename_file_using_front_matter = function(...)
  return require("denote.rename").rename_file_using_front_matter(...)
end
--- Same as |denote.rename.change_file_type_and_front_matter|.
M.change_file_type_and_front_matter = function(...)
  return require("denote.rename").change_file_type_and_front_matter(...)
end
--- Same as |denote.rename.add_front_matter|.
M.add_front_matter = function(...)
  return require("denote.rename").add_front_matter(...)
end
--- Same as |denote.rename.keywords_add|.
M.keywords_add = function(...)
  return require("denote.rename").keywords_add(...)
end
--- Same as |denote.rename.keywords_remove|.
M.keywords_remove = function(...)
  return require("denote.rename").keywords_remove(...)
end
--- Same as |denote.rename.format_buffer_name|.
M.statusline = function(...)
  return require("denote.rename").format_buffer_name(...)
end

-- Linking & Navigation
--- Same as |denote.links.link|.
M.link = function(...)
  return require("denote.links").link(...)
end
--- Same as |denote.links.link_or_create|.
M.link_or_create = function(...)
  return require("denote.links").link_or_create(...)
end
--- Same as |denote.links.link_or_create_with_command|.
M.link_or_create_with_command = function(...)
  return require("denote.links").link_or_create_with_command(...)
end
--- Same as |denote.links.link_after_creating|.
M.link_after_creating = function(...)
  return require("denote.links").link_after_creating(...)
end
--- Same as |denote.links.link_to_heading|.
M.link_to_heading = function(...)
  return require("denote.links").link_to_heading(...)
end
--- Same as |denote.links.link_to_file_with_contents|.
M.link_to_file_with_contents = function(...)
  return require("denote.links").link_to_file_with_contents(...)
end
--- Same as |denote.links.link_to_all_files_with_contents|.
M.link_to_all_files_with_contents = function(...)
  return require("denote.links").link_to_all_files_with_contents(...)
end
--- Same as |denote.links.add_links|.
M.add_links = function(...)
  return require("denote.links").add_links(...)
end
--- Same as |denote.links.follow_link|.
M.follow_link = function(...)
  return require("denote.links").follow_link(...)
end
--- Same as |denote.links.follow_target|.
M.follow_target = function(...)
  return require("denote.links").follow_target(...)
end
--- Same as |denote.links.find_link|.
M.find_link = function(...)
  return require("denote.links").find_link(...)
end
--- Same as |denote.links.convert_links_to_file_paths|.
M.convert_links_to_file_paths = function(...)
  return require("denote.links").convert_links_to_file_paths(...)
end
--- Same as |denote.links.convert_links_to_denote_paths|.
M.convert_links_to_denote_paths = function(...)
  return require("denote.links").convert_links_to_denote_paths(...)
end

-- Backlinks & Query / Grep
--- Same as |denote.backlinks.open|. Undocumented here: its tag would clash with |denote.backlinks|.
---@nodoc
M.backlinks = function(...)
  return require("denote.backlinks").open(...)
end
--- Same as |denote.backlinks.find_backlink|.
M.find_backlink = function(...)
  return require("denote.backlinks").find_backlink(...)
end
--- Same as |denote.backlinks.find_backlink_with_location|.
M.find_backlink_with_location = function(...)
  return require("denote.backlinks").find_backlink_with_location(...)
end
--- Same as |denote.query.grep|.
M.grep = function(...)
  return require("denote.query").grep(...)
end
--- Same as |denote.query.grep_files_referenced_in_region|.
M.grep_files_referenced_in_region = function(...)
  return require("denote.query").grep_files_referenced_in_region(...)
end
--- Same as |denote.query.query_contents_link|.
M.query_contents_link = function(...)
  return require("denote.query").query_contents_link(...)
end
--- Same as |denote.query.query_filenames_link|.
M.query_filenames_link = function(...)
  return require("denote.query").query_filenames_link(...)
end

-- Preview & Reports
--- Same as |denote.preview.open|. Undocumented here: its tag would clash with |denote.preview|.
---@nodoc
M.preview = function(...)
  return require("denote.preview").open(...)
end
--- Same as |denote.report.unlinked_mentions|.
M.unlinked_mentions = function(...)
  return require("denote.report").unlinked_mentions(...)
end
--- Same as |denote.report.link_mention|.
M.link_mention = function(...)
  return require("denote.report").link_mention(...)
end
--- Same as |denote.report.check|.
M.check = function(...)
  return require("denote.report").check(...)
end

-- Explorer & Sort
--- Same as |denote.explorer.open|. Undocumented here: its tag would clash with |denote.explorer|.
---@nodoc
M.explorer = function(...)
  return require("denote.explorer").open(...)
end
--- Same as |denote.explorer.sort_dired|.
M.sort_dired = function(...)
  return require("denote.explorer").sort_dired(...)
end

-- Journal
--- Same as `require("denote.journal").new_entry()`.
M.journal_new_entry = function(...)
  return require("denote.journal").new_entry(...)
end
--- Same as `require("denote.journal").new_or_existing_entry()`.
M.journal_new_or_existing_entry = function(...)
  return require("denote.journal").new_or_existing_entry(...)
end
--- Same as `require("denote.journal").link_or_create_entry()`.
M.journal_link_or_create_entry = function(...)
  return require("denote.journal").link_or_create_entry(...)
end
M.journal_calendar = function(...)
  return require("denote.calendar").open(...)
end

-- Sequences (Folgezettel)
--- Same as |denote.sequence.new_parent|.
M.sequence_new_parent = function(...)
  return require("denote.sequence").new_parent(...)
end
--- Same as |denote.sequence.new_child|.
M.sequence_new_child = function(...)
  return require("denote.sequence").new_child(...)
end
--- Same as |denote.sequence.new_sibling|.
M.sequence_new_sibling = function(...)
  return require("denote.sequence").new_sibling(...)
end
--- Same as |denote.sequence.find|.
M.sequence_find = function(...)
  return require("denote.sequence").find(...)
end
--- Same as |denote.sequence.find_relatives|.
M.sequence_find_relatives = function(...)
  return require("denote.sequence").find_relatives(...)
end
--- Same as |denote.sequence.link|.
M.sequence_link = function(...)
  return require("denote.sequence").link(...)
end
--- Same as |denote.sequence.reparent|.
M.sequence_reparent = function(...)
  return require("denote.sequence").reparent(...)
end

-- Silos
--- Same as |denote.silo.create_note|.
M.silo_create_note = function(...)
  return require("denote.silo").create_note(...)
end
--- Same as |denote.silo.open_or_create|.
M.silo_open_or_create = function(...)
  return require("denote.silo").open_or_create(...)
end
--- Same as |denote.silo.explorer|.
M.silo_explorer = function(...)
  return require("denote.silo").explorer(...)
end
--- Same as |denote.silo.switch|.
M.silo_switch = function(...)
  return require("denote.silo").switch(...)
end

-- Org Dynamic Blocks
--- Same as `require("denote.integrations.org").dblock_insert_links()`.
M.org_dblock_insert_links = function(...)
  return require("denote.integrations.org").dblock_insert_links(...)
end
--- Same as `require("denote.integrations.org").dblock_insert_backlinks()`.
M.org_dblock_insert_backlinks = function(...)
  return require("denote.integrations.org").dblock_insert_backlinks(...)
end
--- Same as `require("denote.integrations.org").dblock_insert_files()`.
M.org_dblock_insert_files = function(...)
  return require("denote.integrations.org").dblock_insert_files(...)
end
--- Same as `require("denote.integrations.org").update_dblocks()`.
M.org_dblock_update = function(...)
  return require("denote.integrations.org").update_dblocks(...)
end

return M
