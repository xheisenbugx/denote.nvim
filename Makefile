.PHONY: test lint format docs

test:
	@d=$$(mktemp -d) && XDG_DATA_HOME=$$d XDG_CACHE_HOME=$$d/cache nvim --headless -u tests/minimal_init.lua -l tests/run.lua $(SPEC); \
	s=$$?; rm -rf $$d; exit $$s

lint:
	stylua --check lua plugin tests

format:
	stylua lua plugin tests

docs:
	nvim --headless --clean -c "helptags doc" -c "qa!"
