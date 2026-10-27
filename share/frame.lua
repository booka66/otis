-- otis-frame's nvim: a picker in a terminal on the left and the code it opens
-- on the right. start() runs the picker (otis-frame's script) in the window
-- nvim starts with; code() and open() are for what the picker runs, through
-- $NVIM: the window the code shows in, made the first time, and a file there.
-- The two windows are kept on the tab, as this file is loaded afresh each call.
local M = {}

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.start()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.t.otis_list = win
  local cmd, opts = { "sh", vim.env.OTIS_FRAME_RUN }, {
    on_exit = function(_, code)
      vim.fn.writefile({ tostring(code) }, vim.env.OTIS_FRAME_STATUS)
      -- The picker is the frame: nvim goes with it, unless there are edits.
      vim.schedule(function()
        if not pcall(vim.cmd, "qa") then
          for _, w in ipairs(vim.fn.win_findbuf(buf)) do
            pcall(vim.api.nvim_win_close, w, true)
          end
          vim.notify("the picker is closed; :wqa or :qa! when you are done", vim.log.levels.WARN)
        end
      end)
    end,
  }
  if vim.fn.has("nvim-0.11") == 1 then
    opts.term = true
    vim.fn.jobstart(cmd, opts)
  else
    vim.fn.termopen(cmd, opts)
  end
  for opt, v in pairs({ number = false, relativenumber = false, signcolumn = "no", statuscolumn = "", foldcolumn = "0", spell = false }) do
    vim.wo[win][opt] = v
  end
  -- ctrl-l from the list to the code, ctrl-h from anywhere back to the list,
  -- which takes keys as soon as you are in it, by ctrl-h or a click. ctrl-h
  -- is each buffer's own, so it wins over a config's (LazyVim's moves a
  -- window left, which from a quickfix list at the bottom is nowhere).
  vim.keymap.set("t", "<C-l>", function()
    if valid(vim.t.otis_code) then
      vim.api.nvim_set_current_win(vim.t.otis_code)
    end
  end, { buffer = buf, desc = "otis: the code" })
  local function to_list()
    if valid(vim.t.otis_list) then
      vim.api.nvim_set_current_win(vim.t.otis_list)
    else
      vim.cmd.wincmd("h")
    end
  end
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(ev)
      if ev.buf == buf then
        vim.cmd.startinsert()
      else
        vim.keymap.set("n", "<C-h>", to_list, { buffer = ev.buf, desc = "otis: the list" })
      end
    end,
  })
  vim.cmd.startinsert()
end

-- code(): the code window, current: the one made before, else a new one
-- right of the list, which keeps 40%.
function M.code()
  local code = vim.t.otis_code
  if valid(code) then
    -- A diff is of the file the window had, and goes with it.
    if vim.wo[code].diff then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= code and vim.wo[w].diff then
          vim.api.nvim_win_close(w, true)
        end
      end
      vim.api.nvim_win_call(code, function()
        vim.cmd("diffoff")
      end)
    end
    vim.api.nvim_set_current_win(code)
    return code
  end
  vim.cmd("botright vnew")
  code = vim.api.nvim_get_current_win()
  vim.bo.bufhidden = "wipe"
  -- A split takes the terminal's options; the code wants yours.
  vim.cmd("setlocal number< relativenumber< signcolumn< statuscolumn< foldcolumn< spell<")
  if valid(vim.t.otis_list) then
    vim.api.nvim_win_set_width(vim.t.otis_list, math.floor(vim.o.columns * 0.4))
  end
  vim.t.otis_code = code
  return code
end

-- open(path, line, col, readonly): the file in the code window, the cursor
-- on line and col (bytes, 1-based; 0 is the line's first non-blank), and you
-- in it.
function M.open(path, line, col, readonly)
  local code = M.code()
  if vim.api.nvim_buf_get_name(0) ~= vim.fn.fnamemodify(path, ":p") then
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then
      vim.notify(err, vim.log.levels.WARN)
      return
    end
  end
  if readonly then
    vim.bo.readonly = true
    vim.bo.modifiable = false
  end
  pcall(vim.api.nvim_win_set_cursor, code, { line, math.max(col - 1, 0) })
  if col == 0 then
    vim.cmd("normal! ^")
  end
  vim.cmd("normal! zz")
end

return M
