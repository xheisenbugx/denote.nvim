# Hero demo: Explorer, creating a note, linking, following, and backlinks
Output docs/media/hero.gif
Source docs/media/tapes/common.tape

Hide
Type "export DENOTE_DEMO_DIR=/tmp/denote-demo-hero DEMO_SNACKS=1; clear; nvim -u docs/media/demo/init.lua $DENOTE_DEMO_DIR/20261118T091500==1--plain-text-note-taking-with-denote__emacs_neovim_philosophy.md" Enter
Sleep 2.5s
Show
Sleep 1s

Hide
Ctrl+G
Type@5ms `Cap <leader>ne Denote Explorer` Enter
Show
Type " ne"
Sleep 2s
Type "q"
Sleep 400ms

Hide
Ctrl+G
Type@5ms `Cap <leader>nn create a new note` Enter
Show
Type " nn"
Sleep 600ms
Type "Durable notes in Neovim" Enter
Sleep 600ms
Type "neovim, philosophy" Enter
Sleep 1.2s

Type "iBuilding on "
Escape
Sleep 300ms

Hide
Ctrl+G
Type@5ms `Cap <leader>nl insert an immutable denote: link` Enter
Show
Type " nl"
Sleep 900ms
Type@100ms "Plain-text"
Sleep 800ms
Enter
Sleep 700ms
Enter
Sleep 1.2s

Type ":w" Enter
Sleep 400ms
Type "0f("
Sleep 400ms

Hide
Ctrl+G
Type@5ms `Cap <CR> follow denote: link` Enter
Show
Enter
Sleep 1.2s

Hide
Ctrl+G
Type@5ms `Cap <leader>nb open backlinks split` Enter
Show
Type " nb"
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 1s
