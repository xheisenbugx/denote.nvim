# Seamless org.nvim integration: denote: links, heading jumps & dynamic blocks
Output docs/media/org-integration.gif
Source docs/media/tapes/common.tape

Hide
Type "export DENOTE_DEMO_DIR=/tmp/denote-demo-org DEMO_ORG=1 DEMO_SNACKS=1 DEMO_FT=org; clear; nvim -u docs/media/demo/init.lua $DENOTE_DEMO_DIR/20261121T163000--org-mode-knowledge-base__emacs_neovim_org.org" Enter
Sleep 3s
Show
Sleep 1.2s

Type "/Direct heading" Enter
Sleep 400ms
Type "f["
Sleep 400ms

Hide
Ctrl+G
Type@5ms `Cap <CR> org.nvim follows denote:ID::#custom-id` Enter
Show
Enter
Sleep 2s

Hide
Ctrl+G
Type@5ms `Cap <C-o> jump back to index note` Enter
Show
Ctrl+O
Sleep 1.2s

Type "/#+BEGIN:" Enter
Sleep 600ms

Hide
Ctrl+G
Type@5ms `Cap :Denote dblock_update | populate denote-links dynamic block` Enter
Show
Type ":Denote dblock_update" Enter
Sleep 2.5s

Hide
Ctrl+G
Type@5ms `Cap <leader>nb backlinks across Org & Markdown` Enter
Show
Type " nb"
Sleep 2.5s

Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
