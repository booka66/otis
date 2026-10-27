-- otis-frame's nvim: a picker's list in a terminal on the left and, where
-- its preview was, nvim itself. start() lays the two windows out and runs
-- the picker (otis-frame's script) in the left one. The rest is for what
-- the picker runs, through $NVIM (otis-frame --open, --text, --run,
-- --focus): a file shown on the right, or a row's preview where it has no
-- file, the list keeping the keys, and enter's step into the code. The windows are
-- kept on the tab, as this file is loaded afresh on every call.
local M = {}

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

-- One file at a time: a file the frame opened goes once the code window
-- shows something else, unless you changed it or it is up elsewhere too.
local function let_go(buf)
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].otis_shown and not vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 0 then
    pcall(vim.api.nvim_buf_delete, buf, {})
  end
end

-- The list as wide as the picker's own beside its preview (30%, 46 columns
-- at least), and the code's width where the picker reads it for its rows'
-- previews and positions.
local function sizes()
  if valid(vim.t.otis_list) then
    vim.api.nvim_win_set_width(vim.t.otis_list, math.max(math.floor(vim.o.columns * 0.3), 46))
  end
  if valid(vim.t.otis_code) then
    vim.fn.writefile({ tostring(vim.api.nvim_win_get_width(vim.t.otis_code)) }, vim.env.OTIS_NVIM_FRAME .. "/cols")
  end
end

-- code(): the window right of the list, made again if it was closed. A diff
-- is of the file the window had, and goes with it.
function M.code()
  local code = vim.t.otis_code
  if not valid(code) then
    local back = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(vim.t.otis_list)
    vim.cmd("botright vnew")
    code = vim.api.nvim_get_current_win()
    vim.bo.bufhidden = "wipe"
    -- A split takes the terminal's options; the code wants yours.
    vim.cmd("setlocal number< relativenumber< signcolumn< statuscolumn< foldcolumn< spell<")
    vim.t.otis_code = code
    vim.api.nvim_set_current_win(back)
    sizes()
  elseif vim.wo[code].diff then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= code and vim.wo[w].diff then
        vim.api.nvim_win_close(w, true)
      end
    end
    vim.api.nvim_win_call(code, function()
      vim.cmd("diffoff")
    end)
  end
  return code
end

function M.start()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.t.otis_list = win
  M.code()
  for opt, v in pairs({ number = false, relativenumber = false, signcolumn = "no", statuscolumn = "", foldcolumn = "0", spell = false }) do
    vim.wo[win][opt] = v
  end
  -- A window opened or closed beside the code changes its width as a
  -- resize of the whole does.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { callback = sizes })
  local cmd, opts = { "sh", vim.env.OTIS_NVIM_FRAME_RUN }, {
    on_exit = function(_, code)
      vim.fn.writefile({ tostring(code) }, vim.env.OTIS_NVIM_FRAME_STATUS)
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
  -- ctrl-l from the list to the code, ctrl-h from anywhere back to the list,
  -- which takes keys as soon as you are in it, by ctrl-h or a click. ctrl-h
  -- is each buffer's own, so it wins over a config's (LazyVim's moves a
  -- window left, which from a quickfix list at the bottom is nowhere).
  vim.keymap.set("t", "<C-l>", M.focus, { buffer = buf, desc = "otis: the code" })
  local function to_list()
    vim.api.nvim_set_current_win(vim.t.otis_list)
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
  -- What the change did, marked down the side of the code as its preview
  -- marked it: gitsigns against the change's base, where there are both.
  if vim.env.NVIM_DIFF_BASE then
    vim.schedule(function()
      pcall(function()
        require("gitsigns").change_base(vim.env.NVIM_DIFF_BASE, true)
      end)
    end)
  end
  vim.cmd.startinsert()
end

-- open(path, line, col, readonly): the file in the code window, its cursor
-- on line and col (bytes, 1-based; 0 is the line's first non-blank).
function M.open(path, line, col, readonly)
  vim.api.nvim_win_call(M.code(), function()
    local full, was = vim.fn.fnamemodify(path, ":p"), vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_get_name(0) ~= full then
      local fresh = vim.fn.bufexists(full) == 0
      local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
      if not ok then
        vim.notify(err, vim.log.levels.WARN)
        return
      end
      if fresh then
        vim.b.otis_shown = true
      end
      let_go(was)
    end
    if readonly then
      vim.bo.readonly = true
      vim.bo.modifiable = false
    end
    pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(col - 1, 0) })
    if col == 0 then
      vim.cmd("normal! ^")
    end
    vim.cmd("normal! zz")
  end)
end

-- text(file): a row's preview, colors and all, in the code window, for a
-- row with no file to open (a case, a heading). The lines the picker marks
-- for itself (\036) are its own.
function M.text(file)
  local code = M.code()
  local lines = {}
  for _, l in ipairs(vim.fn.readfile(file)) do
    if not l:match("^\30") then
      table.insert(lines, l)
    end
  end
  local b, was = vim.api.nvim_create_buf(false, true), vim.api.nvim_win_get_buf(code)
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(code, b)
  let_go(was)
  vim.api.nvim_chan_send(vim.api.nvim_open_term(b, {}), table.concat(lines, "\r\n"))
  vim.schedule(function()
    if valid(code) and vim.api.nvim_win_get_buf(code) == b then
      pcall(vim.api.nvim_win_set_cursor, code, { 1, 0 })
    end
  end)
end

-- run(cmd, arg): an Ex command in the code window, the keys left with the
-- list: a review's :GmrDeleted, a deleted file beside its base.
function M.run(cmd, arg)
  vim.api.nvim_win_call(M.code(), function()
    vim.cmd({ cmd = cmd, args = { arg } })
  end)
end

-- focus(): into the code, enter's step after its open.
function M.focus()
  if valid(vim.t.otis_code) then
    vim.api.nvim_set_current_win(vim.t.otis_code)
  end
end

return M
