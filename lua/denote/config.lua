---@mod denote.config Configuration defaults and accessors

local M = {}

---@class denote.FileTypeSpec
---@field extension string File extension including leading dot (e.g. ".org", ".md")
---@field front_matter string|fun(meta: table): string Front matter template or builder
---@field date_format? string os.date format or special token ("org", "iso8601", "date")
---@field link_format? string Link template with %s placeholders (id, description)
---@field link_id_only_format? string ID-only link template with %s placeholder (id)

---@class denote.JournalConfig
---@field directory? string|nil Directory for journal entries (nil -> <directory>/journal or <directory>)
---@field keyword string Keyword tag added to journal entries
---@field title_format string os.date format for journal note titles (e.g. "%A %e %B %Y")
---@field file_type? string|nil Override default file_type for journal entries
---@field template? string|nil Template name for journal entries

---@class denote.SequenceConfig
---@field scheme "numeric"|"alphanumeric" Sequence signature scheme (default: "numeric")
---@field default_depth? integer Default depth for new sequences

---@class denote.MappingsConfig
---@field enabled boolean Register default global keymaps
---@field prefix string Leader prefix for global keymaps (default: "<leader>n")
---@field follow_link string|false Buffer-local keymap to follow a denote: link (default: "<CR>")
---@field follow_link_fallback boolean Fall back to native keymap when cursor is not on a denote: link

---@class denote.Config
M.defaults = {
  --- Primary directory for Denote notes.
  directory = "~/Documents/notes",

  --- Default file type for new notes: "org", "markdown-yaml", "markdown-toml", "text", or custom key.
  file_type = "markdown-yaml",

  --- Predefined keywords always suggested in completion.
  known_keywords = { "emacs", "neovim", "philosophy", "politics", "economics" },

  --- Automatically collect keywords from existing Denote files in the active directory.
  infer_keywords = true,

  --- Pattern (Lua/Vim regex) of keywords to exclude when inferring keywords (Denote 4.2.0).
  keywords_to_not_infer_pattern = nil,

  --- Sort keywords alphabetically in filenames and front matter.
  sort_keywords = true,

  --- Default prompt sequence for `:Denote` / `denote.note()`.
  --- Supported prompts: "title", "keywords", "file_type", "subdirectory", "date", "template", "signature"
  prompts = { "title", "keywords" },

  --- Order of filename components.
  --- When "identifier" is not first, Denote prefixes it with "@@" per Denote 3.x/4.x spec.
  file_name_components_order = { "identifier", "signature", "title", "keywords" },

  --- Always include `@@` before the identifier even when it is first (Denote 4.1.0).
  identifier_delimiter_always_present = false,

  --- Regexps (Lua patterns) of directories/files to exclude from Denote scans.
  excluded_directories_patterns = { "^%.git$", "^node_modules$", "^%.obsidian$", "^%.trash$", "^ltximg$" },
  excluded_files_patterns = {},

  --- Excluded punctuation characters removed during sluggification (Lua pattern character set).
  excluded_punctuation_pattern = "[%[%]{}!@#$%%^&*()=+'\"?,%.|;:~`‘’“”/\\<>]",

  --- Optional custom slug functions per component: { title = fn, signature = fn, keyword = fn }
  file_name_slug_functions = {},

  --- Whether to preserve case when sluggifying titles/signatures (default false = lowercase).
  preserve_case = false,

  --- Front matter components kept even when empty (e.g. { "signature" }).
  front_matter_components_present_even_if_empty = {},

  --- Date format in front matter (nil uses each file type's canonical Denote format).
  date_format = nil,

  --- Named body templates: { [name] = string | fun(meta: table): string }
  templates = {},

  --- Save newly created notes to disk immediately.
  save_buffer_after_creation = false,

  --- Ask for confirmation before renaming files on disk ("rewrite_front_matter", "modify_file_name", "add_front_matter").
  rename_confirmations = {},

  --- Automatically sync filename from front matter on `:w` (BufWritePost).
  auto_rename_on_save = false,

  --- Rename buffer display metadata (accessible via `denote.statusline()`).
  --- Specifiers (matching Emacs Denote): %t title, %T filename title, %i/%d identifier,
  --- %I formatted date, %D DWIM (title -> date -> id), %s signature, %k keywords,
  --- %b backlinks indicator, %% literal %.
  rename_buffer_format = "%D",

  --- Indicator inserted by `%b` in `rename_buffer_format` when a note has backlinks.
  rename_buffer_backlinks_indicator = " <-->",

  --- Optional prefix prepended to formatted buffer names (e.g. "[D] ").
  buffer_name_prefix = "",

  --- Default sort component & direction in the Denote Explorer (`denote-sort-dired`).
  sort_dired_default_sort_component = "identifier",
  sort_dired_default_reverse_sort = true,

  --- Link format style for Markdown files:
  --- "denote" -> [Description](denote:ID) (canonical Denote)
  --- "wiki"   -> [[denote:ID|Description]]
  --- "relative" -> [Description](relative-filename.md)
  markdown_link_style = "denote",

  --- Link description format: string with %t/%s/%i/%k specifiers, or fun(file: string, meta: table): string.
  --- Nil uses Denote's default (signature + two spaces + title when signature exists, else title).
  link_description_format = nil,

  --- Backwards-compatible alias for `link_description_format` as a function.
  link_description_function = nil,

  --- Optional custom link opener: fun(path: string, how?: string)
  open_link_function = nil,

  --- Hooks called after creating a note or renaming a file (function or list of functions).
  --- Neovim User autocmds `DenoteNewNote` and `DenoteRenameFile` are also emitted.
  after_new_note_hook = nil,
  after_rename_file_hook = nil,

  --- Show context lines in the backlinks buffer by default.
  backlinks_show_context = true,

  --- Split command for backlinks, explorer, and query result buffers.
  window_cmd = "botright 15split",

  --- Picker backend: "auto", "snacks", "fzf-lua", "telescope", "mini", "select".
  picker = "auto",

  --- Silo directories (isolated Denote repositories).
  silos = {},

  --- Journal configuration (`denote-journal`).
  journal = {
    directory = nil,
    keyword = "journal",
    title_format = "%A %e %B %Y",
    file_type = nil,
    template = nil,
  },

  --- Sequence / Folgezettel configuration (`denote-sequence`).
  sequence = {
    scheme = "numeric",
  },

  --- Highlighting & visual decorations in Markdown/Text buffers.
  ui = {
    highlight_links = true,
    conceal_links = false,
    check_broken_links = true,
  },

  --- Integrations with other Neovim plugins.
  integrations = {
    org = true,
    which_key = true,
  },

  --- Keymap configuration.
  mappings = {
    enabled = true,
    prefix = "<leader>n",
    follow_link = "<CR>",
    follow_link_fallback = true,
  },

  --- Extra custom file types merged on top of built-ins (org, markdown-yaml, markdown-toml, text).
  file_types = {},
}

---@type denote.Config
M.opts = vim.deepcopy(M.defaults)

--- Active silo override (nil means use `M.opts.directory`).
---@type string|nil
M.active_directory = nil

--- Merge user options into `M.opts`.
---@param user_opts? table
---@return denote.Config
function M.setup(user_opts)
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
  M.active_directory = nil
  return M.opts
end

--- Return the currently active Denote directory (expanded and normalized).
---@param dir? string Optional explicit directory override
---@return string
function M.directory(dir)
  local raw = dir or M.active_directory or M.opts.directory
  if type(raw) == "function" then
    raw = raw()
  end
  local expanded = vim.fn.expand(raw)
  return (vim.fs.normalize(expanded):gsub("/+$", ""))
end

return M
