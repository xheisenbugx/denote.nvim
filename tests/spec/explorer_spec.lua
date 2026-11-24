local denote = require("denote")

describe("denote.explorer", function()
  it("opens explorer with filtered and sorted notes", function()
    with_temp_dir(function(dir)
      denote.setup({ directory = dir, file_type = "markdown-yaml", mappings = { enabled = false } })
      denote.create_sync({ title = "First Note", keywords = { "alpha" }, date = "2026-11-23 09:00:00", open = false })
      denote.create_sync({ title = "Second Note", keywords = { "beta" }, date = "2026-11-23 09:05:00", open = false })

      local buf = denote.explorer({ dir = dir, keyword = "alpha" })
      ok(vim.api.nvim_buf_is_valid(buf))
      local lines = buf_lines(buf)
      local joined = table.concat(lines, "\n")
      ok(joined:find("First note", 1, true) ~= nil)
      eq(nil, joined:find("Second note", 1, true))
    end)
  end)

  it("does not leak [No Name] buffers and safely refreshes after async R rename", function()
    with_temp_dir(function(dir)
      local utils = require("denote.utils")
      denote.setup({ directory = dir, file_type = "org", mappings = { enabled = false } })
      local meta = denote.create_sync({
        title = "Something",
        keywords = { "neovim", "org" },
        date = "2026-11-24 10:58:45",
        open = true,
        save = true,
      })
      vim.api.nvim_buf_set_lines(meta.bufnr, -1, -1, false, { "* Body Heading", "Preserved content line." })
      vim.cmd("silent write")

      local before_unnamed = 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) == "" then
          before_unnamed = before_unnamed + 1
        end
      end

      local exp_buf = denote.explorer({ dir = dir })
      local after_unnamed = 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) == "" then
          after_unnamed = after_unnamed + 1
        end
      end
      eq(before_unnamed, after_unnamed)

      -- Simulate async floating 1-line vim.ui.input (like snacks.input) while pressing R in Explorer
      local orig_input = vim.ui.input
      local answers = { "Renamed Title", "neovim, org", "" }
      local step = 0
      local pending_cb = nil
      local float_win = nil
      vim.ui.input = function(_, on_confirm)
        step = step + 1
        if step == 1 then
          local ibuf = vim.api.nvim_create_buf(false, true)
          float_win = vim.api.nvim_open_win(ibuf, true, {
            relative = "editor",
            width = 30,
            height = 1,
            row = 1,
            col = 1,
          })
          pending_cb = on_confirm
        else
          on_confirm(answers[step])
        end
      end

      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.api.nvim_feedkeys("R", "x", false)
      -- Let any scheduled callbacks run while the 1-line floating input is focused (must NOT crash!)
      vim.wait(50)
      if float_win and vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, true)
      end
      if pending_cb then
        pending_cb(answers[1])
      end
      vim.ui.input = orig_input
      vim.wait(50)

      -- Explorer must now show the renamed note, not the stale deleted path
      local exp_text = table.concat(buf_lines(exp_buf), "\n")
      ok(exp_text:find("Renamed title", 1, true) ~= nil)
      eq(nil, exp_text:find("Something", 1, true))

      -- Pressing <CR> on row 3 opens the renamed file with its full body content intact
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      local opened_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      ok(opened_lines:find("Preserved content line.", 1, true) ~= nil)
      eq(false, utils.exists(meta.path))
    end)
  end)
end)
