# Denote 4.0 full-text grep with live narrowing + query-contents links
Output docs/media/grep-and-query.gif
Source docs/media/tapes/common.tape

Hide
Type "export DENOTE_DEMO_DIR=/tmp/denote-demo-grep DEMO_SNACKS=1; clear; nvim -u docs/media/demo/init.lua $DENOTE_DEMO_DIR/20261118T091500==1--plain-text-note-taking-with-denote__emacs_neovim_philosophy.md" Enter
Sleep 2.5s
Show
Sleep 800ms

Hide
Ctrl+G
Type@5ms `Cap <leader>ng grep across Denote notes` Enter
Show
Type " ng"
Sleep 600ms
Type "links" Enter
Sleep 1.8s

Hide
Ctrl+G
Type@5ms `Cap f narrow results live` Enter
Show
Type "f"
Sleep 600ms
Type "Org" Enter
Sleep 1.8s

Hide
Ctrl+G
Type@5ms `Cap c clear filters & q close` Enter
Show
Type "c"
Sleep 1s
Type "q"
Sleep 500ms

Type "Go" Escape
Type "iLive search: " Escape
Sleep 300ms

Hide
Ctrl+G
Type@5ms `Cap <leader>nqc insert a live query-contents link` Enter
Show
Type " nqc"
Sleep 600ms
Type "Folgezettel" Enter
Sleep 600ms
Ctrl+U
Type "All Folgezettel mentions" Enter
Sleep 1.4s

Type "0f("
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <CR> execute the live query link` Enter
Show
Enter
Sleep 2.5s

Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
