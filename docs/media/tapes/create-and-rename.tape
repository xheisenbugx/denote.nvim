# Creating notes & two-way front matter / filename synchronization
Output docs/media/create-and-rename.gif
Source docs/media/tapes/common.tape

Hide
Type "export DENOTE_DEMO_DIR=/tmp/denote-demo-rename DEMO_SNACKS=1; clear; nvim -u docs/media/demo/init.lua" Enter
Sleep 2.5s
Show
Sleep 800ms

Hide
Ctrl+G
Type@5ms `Cap <leader>nn create a Denote note` Enter
Show
Type " nn"
Sleep 600ms
Type "Draft architecture" Enter
Sleep 600ms
Type "draft, neovim" Enter
Sleep 1.8s

Hide
Ctrl+G
Type@5ms `Cap edit title & tags directly in front matter` Enter
Show
Type `gg/Draft` Enter
Sleep 400ms
Type `cwPolished` Escape
Sleep 500ms
Type `/draft` Enter
Sleep 400ms
Type `cwarchitecture` Escape
Sleep 500ms
Type ":w" Enter
Sleep 600ms

Hide
Ctrl+G
Type@5ms `Cap <leader>nR sync filename from front matter` Enter
Show
Type "0"
Type " nR"
Sleep 2.2s

Hide
Ctrl+G
Type@5ms `Cap <leader>nk add keyword to filename & front matter` Enter
Show
Type " nk"
Sleep 700ms
Type "published" Enter
Sleep 2.5s

Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
