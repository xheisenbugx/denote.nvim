# README media

The GIFs in the main README are recorded with [VHS](https://github.com/charmbracelet/vhs), so they can be re-recorded cleanly whenever the UI changes.

The recorded `.gif` files are **not** committed to `main`: they live on the orphan [`media`](https://github.com/xheisenbugx/denote.nvim/tree/media) branch, and the README links to them via `https://raw.githubusercontent.com/xheisenbugx/denote.nvim/media/<name>.gif`. That keeps the repository tiny for plugin managers (`lazy.nvim`, `vim.pack`, etc.).

- `tapes/*.tape`: one script per demo. `common.tape` holds the shared terminal size, font, and color theme.
- `demo/init.lua`: standalone Neovim config used by the tapes. It copies `demo/notes/*` into `$DENOTE_DEMO_DIR` (a temp directory), wires up `:Cap` for bottom-right key captions, and optionally loads `snacks.nvim` (`DEMO_SNACKS=1`) and `org.nvim` (`DEMO_ORG=1`).

## Re-recording

You need `vhs` (`brew install vhs`) and the [BlexMono Nerd Font](https://www.nerdfonts.com/font-downloads). From the repository root:

```sh
make media                                 # record every tape in parallel
vhs docs/media/tapes/hero.tape             # record a single tape
make publish-media                         # push GIFs to the orphan `media` branch
```
