-- Loaded by otis-find into nvim: your own fuzzy finder, opened at once on the
-- checkout you are in, and nvim left again when the finder closes with no
-- file chosen, so it is back to otis rather than an empty editor.
--
-- The finder is what OTIS_FINDER names (git config otis.finder) when it
-- names one: the keys of a mapping of your own, which is how to get your
-- finder as you have set it up, filters and all,
--   git config --global otis.finder '<leader><leader>'
-- or an Ex command (anything not starting with <). Else the first of these
-- that nvim has: snacks.nvim's smart picker, Telescope's find_files,
-- fzf-lua's files.
local cmd = vim.env.OTIS_FINDER

local function find()
  if cmd and cmd:sub(1, 1) == "<" then
    -- Typed, as you would type them, so the mapping runs as it does for you.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(cmd, true, false, true), "m", false)
    return
  end
  if cmd and cmd ~= "" then
    vim.cmd(cmd)
    return
  end
  if _G.Snacks and Snacks.picker then
    Snacks.picker.smart()
    return
  end
  local ok, telescope = pcall(require, "telescope.builtin")
  if ok then
    telescope.find_files()
    return
  end
  local okf, fzf = pcall(require, "fzf-lua")
  if okf then
    fzf.files()
    return
  end
  vim.notify(
    "otis: nvim has no fuzzy finder it knows (snacks.nvim, Telescope, fzf-lua); name yours in git config otis.finder",
    vim.log.levels.WARN
  )
end

-- A file is open: a listed buffer with a name that is a file's.
local function chose()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted and vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
      return true
    end
  end
  return false
end

-- The finder's window closing is either a file chosen, which is open a
-- moment later, or the finder left: then nvim goes too. Only until a file
-- has been chosen: after that this is your editor, and a finder you open and
-- close in it is yours to close.
local group = vim.api.nvim_create_augroup("otis_find", { clear = true })
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(ev)
    local ok, buf = pcall(vim.api.nvim_win_get_buf, tonumber(ev.match))
    if not ok then
      return
    end
    local ft = vim.bo[buf].filetype
    if not (ft:match("^snacks_picker") or ft == "TelescopePrompt" or ft == "fzf") then
      return
    end
    vim.defer_fn(function()
      if chose() then
        pcall(vim.api.nvim_del_augroup_by_id, group)
      else
        vim.cmd("qa")
      end
    end, 250)
  end,
})

vim.schedule(find)
