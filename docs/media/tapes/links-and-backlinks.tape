# Immutable links, heading links, following links, and backlinks split
Output docs/media/links-and-backlinks.gif
Source docs/media/tapes/common.tape

Hide
Type "export DENOTE_DEMO_DIR=/tmp/denote-demo-links DEMO_SNACKS=1; clear; nvim -u docs/media/demo/init.lua $DENOTE_DEMO_DIR/20261122T150000--two-way-front-matter-sync__neovim_workflow.md" Enter
Sleep 2.5s
Show
Sleep 1s

Type "Go" Escape
Type "iSee heading: " Escape
Sleep 300ms

Hide
Ctrl+G
Type@5ms `Cap <leader>nh link directly to a heading` Enter
Show
Type " nh"
Sleep 900ms
Type@100ms "Plain-text"
Sleep 800ms
Enter
Sleep 900ms
Type@100ms "Why"
Sleep 800ms
Enter
Sleep 1.5s

Type "0f("
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <CR> jump straight to the target heading` Enter
Show
Enter
Sleep 1.8s

Hide
Ctrl+G
Type@5ms `Cap <leader>nb open interactive backlinks buffer` Enter
Show
Type " nb"
Sleep 1.8s

Hide
Ctrl+G
Type@5ms `Cap f toggle context vs filenames-only` Enter
Show
Type "f"
Sleep 1.5s
Type "f"
Sleep 1.2s

Type "jjj"
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap <CR> jump to linking note` Enter
Show
Enter
Sleep 2s

Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
