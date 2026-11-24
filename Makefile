.PHONY: test lint format docs bench media publish-media fixtures typecheck

test:
	@d=$$(mktemp -d) && XDG_DATA_HOME=$$d XDG_CACHE_HOME=$$d/cache nvim --headless -u tests/minimal_init.lua -l tests/run.lua $(SPEC); \
	s=$$?; rm -rf $$d; exit $$s

lint:
	stylua --check lua plugin tests scripts

format:
	stylua lua plugin tests scripts

# Benchmark against a generated vault: make bench N=10000
bench:
	@nvim --headless -u tests/minimal_init.lua -l scripts/bench.lua $(N)

# Regenerate the Emacs Denote golden fixtures (tests/fixtures/emacs) with the real Denote.
# Denote is installed from GNU ELPA into .cache/emacs-fixtures (never ~/.emacs.d).
EMACS ?= emacs
fixtures:
	LC_ALL=C LANG=C $(EMACS) --batch -Q -l scripts/emacs-fixtures/generate.el


# API reference generator (https://github.com/mrcjkb/vimcats). v1.2.0+ is needed
# for `---@nodoc` (not on crates.io yet, so install from the tag):
#   cargo install --git https://github.com/mrcjkb/vimcats --tag v1.2.0 --features=cli --locked
#   make docs VIMCATS=/path/to/vimcats
VIMCATS ?= vimcats
VIMCATS_FLAGS ?= --prefix-func --prefix-type
# Modules rendered into doc/denote-api.txt, in this order.
API_MODULES := init config create links backlinks query search preview report \
	rename frontmatter naming files explorer sequence silo
API_SOURCES := $(patsubst %,lua/denote/%.lua,$(API_MODULES))

# Regenerates doc/denote-api.txt unconditionally (no timestamp checks, so CI can
# detect stale docs), then rebuilds doc/tags. The awk step moves a section tag
# onto its own line when a long module title leaves no space before it (Vim's
# :helptags only recognises `*tag*` after whitespace).
docs:
	@command -v $(VIMCATS) >/dev/null 2>&1 || { \
	  echo "error: '$(VIMCATS)' not found; install it with:" >&2; \
	  echo "  cargo install --git https://github.com/mrcjkb/vimcats --tag v1.2.0 --features=cli --locked" >&2; \
	  exit 1; }
	@set -e; api=$$($(VIMCATS) $(VIMCATS_FLAGS) $(API_SOURCES)); \
	{ printf '%s\n\n' '*denote-api.txt*  denote.nvim Lua API reference (generated, do not edit)'; \
	  printf '%s\n' 'Generated from the LuaCATS annotations in lua/denote/ by `make docs`.'; \
	  printf '%s\n\n' 'For the user guide, see |denote.txt|.'; \
	  printf '%s\n' "$$api" | awk '{ if (match($$0, /[^ *]\*[^ *]+\*$$/)) { printf "%s\n%78s\n", substr($$0, 1, RSTART), substr($$0, RSTART + 1) } else print }'; \
	} > doc/denote-api.txt; \
	echo "Generated doc/denote-api.txt"
	nvim --headless --clean -c "try | helptags doc | catch | call writefile([v:exception], '/dev/stderr') | cquit 1 | endtry" -c "qa!"

# Re-record the README GIFs (needs vhs and BlexMono Nerd Font; see docs/media/README.md).
media:
	@for t in docs/media/tapes/*.tape; do \
	  case $$t in */common.tape) ;; *) vhs $$t & ;; esac; \
	done; wait

# Commit the recorded GIFs in docs/media to the orphan `media` branch and push it.
publish-media:
	@set -e; \
	git fetch -q origin media 2>/dev/null || true; \
	d=$$(mktemp -d); \
	if git rev-parse --verify origin/media >/dev/null 2>&1; then \
	  git worktree add -q --detach $$d origin/media; \
	else \
	  git worktree add -q --orphan -b media $$d; \
	fi; \
	for f in docs/media/*.gif docs/media/*.png; do if [ -e "$$f" ]; then cp "$$f" $$d/; fi; done; \
	git -C $$d add -A; \
	if git -C $$d diff --cached --quiet; then \
	  echo "media: nothing new to publish"; \
	else \
	  git -C $$d commit -q -m "docs(media): update README demo GIFs" && git -C $$d push -q origin HEAD:media; \
	fi; \
	git worktree remove --force $$d

