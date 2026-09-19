-- Loaded by git-commit-edit when the editor is nvim: the message stays in the
-- current window, and the diff being committed opens read-only in a split
-- below, as a real diff buffer rather than comments under a cut line.
-- ctrl-d/u/e/y in the message window scroll the diff, and quitting the
-- message closes both.
local diff_path = vim.env.GCM_DIFF
if not diff_path or vim.fn.filereadable(diff_path) == 0 then
  return
end

local msg_win = vim.api.nvim_get_current_win()
local msg_buf = vim.api.nvim_get_current_buf()

-- A scratch buffer colored by the classic diff syntax, not a .diff file with
-- filetype=diff: that path runs treesitter, and a parser out of step with its
-- highlight queries makes it throw before the window is usable.
vim.cmd("botright new")
local diff_win = vim.api.nvim_get_current_win()
local diff_buf = vim.api.nvim_get_current_buf()
vim.bo[diff_buf].buftype = "nofile"
vim.bo[diff_buf].bufhidden = "wipe"
vim.bo[diff_buf].buflisted = false
vim.bo[diff_buf].swapfile = false
vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, vim.fn.readfile(diff_path))
vim.bo[diff_buf].syntax = "diff"
vim.bo[diff_buf].modifiable = false
for option, value in pairs({
  wrap = false, number = false, relativenumber = false, spell = false,
  colorcolumn = "", signcolumn = "no", foldenable = false, cursorline = false,
}) do
  vim.wo[diff_win][option] = value
end
vim.api.nvim_win_set_height(diff_win, math.floor(vim.o.lines * 0.6))
vim.api.nvim_set_current_win(msg_win)

-- Buffer-local, so they win over any global smooth-scroll mappings.
local scroll = { ["<C-d>"] = "\4", ["<C-u>"] = "\21", ["<C-e>"] = "\5", ["<C-y>"] = "\25" }
for key, keys in pairs(scroll) do
  vim.keymap.set("n", key, function()
    if vim.api.nvim_win_is_valid(diff_win) then
      vim.api.nvim_win_call(diff_win, function()
        vim.cmd("normal! " .. keys)
      end)
    end
  end, { buffer = msg_buf, desc = "Scroll the diff" })
end

vim.api.nvim_create_autocmd("QuitPre", {
  buffer = msg_buf,
  once = true,
  callback = function()
    if vim.api.nvim_win_is_valid(diff_win) then
      vim.api.nvim_win_close(diff_win, true)
    end
  end,
})
