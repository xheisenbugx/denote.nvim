# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Cached file index (`denote.files`): directory listings, identifier lookups, and
  per-file Denote/text flags are cached per root and revalidated with one `stat` per
  directory. `:Denote reindex` clears every cache.
- Shared search engine (`denote.search`) used by grep, query links, backlinks, unlinked
  mentions, and `:Denote check`, with optional async callbacks and cancellation.
- Broken `denote:` links are reported through `vim.diagnostic` (`ui.diagnostics`,
  `ui.diagnostics_severity`).
- `:Denote preview` and buffer-local `K` hover preview of the linked note
  (`mappings.preview_link`, `preview.max_lines`, `preview.border`).
- `:Denote unlinked_mentions` (`<leader>nu`) and `:Denote link_mention` (`<leader>nU`).
- `:Denote check` (`<leader>nc`): quickfix report of broken links and orphan notes.
- `make bench` benchmark against a generated vault.
- CI on macOS and with/without ripgrep; issue templates.

### Changed

- Backlinks now use ripgrep when available (previously always pure Lua).
- The Backlinks and Query buffers search asynchronously and no longer block the UI.
- The statusline `%b` backlinks indicator is cached and refreshed in the background
  (`search.backlinks_indicator_ttl`).
- Link decorations are debounced (`ui.debounce_ms`) and also refresh on `FocusGained`.
- The Denote directory is resolved through symlinks (e.g. macOS `/var` → `/private/var`).
- Front matter titles are cached by file mtime and size.

### Fixed

- Test suite failures on macOS caused by mixing symlinked and resolved paths.
- A search with no ripgrep matches (exit code 1) re-ran the whole search in Lua.
- ripgrep skipped notes ignored by `.gitignore` / `.ignore` and notes in hidden directories.
- The ripgrep and Lua backends used different regex and case semantics; the Lua path
  ignored the pattern in case-sensitive mode and honoured `'ignorecase'` otherwise.
- Searches ignored unsaved buffer changes when ripgrep was used.
- Broken-link highlighting flagged valid links to notes in silos or `journal.directory`.
- Leaving insert mode rescanned the whole notes directory for every buffer with links.
