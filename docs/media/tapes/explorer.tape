# Interactive Denote Explorer: sort, filter by keyword, mark, and help
Output docs/media/explorer.gif
Source docs/media/tapes/common.tape

Hide
Type "export DENOTE_DEMO_DIR=/tmp/denote-demo-explorer DEMO_SNACKS=1; clear; nvim -u docs/media/demo/init.lua" Enter
Sleep 2.5s
Show
Sleep 600ms

Hide
Ctrl+G
Type@5ms `Cap <leader>ne open Denote Explorer` Enter
Show
Type " ne"
Sleep 1.8s

Hide
Ctrl+G
Type@5ms `Cap S sort by signature (Folgezettel order)` Enter
Show
Type "S"
Sleep 900ms
Type@100ms "sig"
Sleep 700ms
Enter
Sleep 1.8s

Hide
Ctrl+G
Type@5ms `Cap r reverse sort order` Enter
Show
Type "r"
Sleep 1.2s
Type "r"
Sleep 800ms

Hide
Ctrl+G
Type@5ms `Cap k filter by keyword` Enter
Show
Type "k"
Sleep 900ms
Type@100ms "zettel"
Sleep 700ms
Enter
Sleep 1.8s

Hide
Ctrl+G
Type@5ms `Cap c clear filters` Enter
Show
Type "c"
Sleep 1.2s

Hide
Ctrl+G
Type@5ms `Cap m mark files for batch rename` Enter
Show
Type "m"
Sleep 400ms
Type "m"
Sleep 1.2s

Hide
Ctrl+G
Type@5ms `Cap g? list all Explorer keymaps` Enter
Show
Type "g?"
Sleep 2.5s
Type "q"
Sleep 800ms
