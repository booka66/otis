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

-- No gutter beside the list or a preview: they are drawn as wide as their
-- window, and a file's line numbers are not theirs.
local gutter = { number = false, relativenumber = false, signcolumn = "no", statuscolumn = "", foldcolumn = "0" }
-- The list's window options: no gutter, and a width it keeps whatever the
-- windows around it do (winfixwidth: closing a split beside the code, or a
-- config evening the windows out on a resize, leaves it be). A split made
-- from it takes them, and the code window gives them back.
local list_opts = vim.tbl_extend("force", gutter, { spell = false, winfixwidth = true, wrap = false, list = false })

-- set(win, opts): the options for what the window shows now, not its own
-- defaults (a window's "global" values are its own in nvim, copied by a
-- split), and only those that differ, as each can resize a terminal.
local function set(win, opts)
  local changed = false
  for opt, v in pairs(opts) do
    if vim.api.nvim_get_option_value(opt, { win = win }) ~= v then
      vim.api.nvim_set_option_value(opt, v, { win = win, scope = "local" })
      changed = true
    end
  end
  return changed
end

-- The list's options again, on every push: a config sets some as it loads,
-- when nvim says nothing of it (coc's signcolumn took two of its columns).
-- nvim narrowed the list's terminal for that gutter and does not widen it
-- again until the window's width changes: a column there and back.
local function hold_list()
  local list = vim.t.otis_list
  if valid(list) and set(list, list_opts) then
    local w = vim.api.nvim_win_get_width(list)
    vim.api.nvim_win_set_width(list, w - 1)
    vim.api.nvim_win_set_width(list, w)
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

-- preview(): the one buffer every preview is drawn into, in place, made the
-- first time. Nothing the frame shows is ever deleted or wiped while it runs:
-- nvim scrolled the list's terminal a line each time a buffer went, which left
-- a row you had been on lit and every line a row off.
function M.preview()
  local b = vim.t.otis_preview
  if not (b and vim.api.nvim_buf_is_valid(b)) then
    b = vim.api.nvim_create_buf(false, true)
    vim.b[b].otis_text = true
    vim.t.otis_preview = b
  end
  return b
end

-- code(): the window right of the list: when it was closed, the last window
-- on the tab showing a file or a preview of the frame's in its place, else a
-- new one (never a quickfix list or a plugin's pane). A diff is of the file
-- the window had, and goes with it.
function M.code()
  hold_list()
  local code = vim.t.otis_code
  if not valid(code) then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if w ~= vim.t.otis_list and vim.fn.win_gettype(w) == "" and (vim.bo[b].buftype == "" or vim.b[b].otis_text) then
        code = w
      end
    end
  end
  if valid(code) and code ~= vim.t.otis_code then
    vim.t.otis_code = code
    sizes()
  end
  if not valid(code) then
    local back = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(vim.t.otis_list)
    vim.cmd("botright vsplit")
    code = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(code, M.preview())
    -- A split from the list takes its options; the code wants yours, as the
    -- first code window had them (otis_code_opts).
    if vim.t.otis_code_opts then
      set(code, vim.t.otis_code_opts)
    end
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

local function list_window(win)
  set(win, list_opts)
  vim.t.otis_list = win
  sizes()
end

function M.start()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.t.otis_list = win
  -- The list is not a file to switch to, and the frame shows one file at a
  -- time: no tab line of buffers, whatever a config turns it on for (which
  -- hides real tabs too; the frame is one).
  vim.bo[buf].buflisted = false
  vim.o.showtabline = 0
  vim.api.nvim_create_autocmd("OptionSet", {
    pattern = "showtabline",
    callback = function()
      if vim.o.showtabline ~= 0 then
        vim.schedule(function()
          vim.o.showtabline = 0
        end)
      end
    end,
  })
  -- Nothing scrolls sideways: not by the wheel or a trackpad, and the list
  -- never, whatever moves it.
  vim.o.mousescroll = "ver:3,hor:0"
  for _, key in ipairs({ "<ScrollWheelLeft>", "<ScrollWheelRight>", "<S-ScrollWheelUp>", "<S-ScrollWheelDown>" }) do
    vim.keymap.set({ "n", "i", "v", "t" }, key, "<Nop>")
  end
  vim.api.nvim_create_autocmd("WinScrolled", {
    callback = function()
      for _, w in ipairs({ vim.t.otis_list, vim.t.otis_code }) do
        if valid(w) and (w == vim.t.otis_list or vim.b[vim.api.nvim_win_get_buf(w)].otis_text) and vim.api.nvim_win_call(w, vim.fn.winsaveview).leftcol > 0 then
          vim.api.nvim_win_call(w, function()
            vim.fn.winrestview({ leftcol = 0 })
          end)
        end
      end
    end,
  })
  -- A file open in another nvim too opens here without asking about its swap file.
  vim.opt.shortmess:append("A")
  M.code()
  -- Your options for a code window, as the first one has them before the
  -- list's are set: a file goes back to them after a preview turned the
  -- gutter off, and a code window made again takes them.
  local yours = {}
  for opt in pairs(list_opts) do
    yours[opt] = vim.api.nvim_get_option_value(opt, { win = vim.t.otis_code })
  end
  vim.t.otis_code_opts = yours
  list_window(win)
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
  -- A :only in the code took the list's window with it: back at the left.
  local function to_list()
    if not valid(vim.t.otis_list) then
      vim.cmd("topleft vertical sbuffer " .. buf)
      list_window(vim.api.nvim_get_current_win())
    end
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
  local code = M.code()
  vim.api.nvim_win_call(code, function()
    local full = vim.fn.fnamemodify(path, ":p")
    if vim.api.nvim_buf_get_name(0) ~= full then
      local fresh = vim.fn.bufexists(full) == 0
      local ok, err = pcall(vim.cmd, "silent keepalt edit " .. vim.fn.fnameescape(path))
      if not ok then
        vim.notify(err, vim.log.levels.WARN)
        return
      end
      -- A file the frame opened stays loaded as the window moves on (see
      -- preview), off the buffer list, so no list of buffers ever shows it.
      if fresh then
        vim.bo.buflisted = false
      end
    end
    -- A preview there before had the gutter off: a file has yours.
    set(code, vim.t.otis_code_opts)
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

-- A preview's colors, from the SGR codes the picker draws with, as
-- highlights on plain text: a terminal buffer showed it blank first and then
-- filled in, and opening one resized the list's terminal to the whole width.
local ns = vim.api.nvim_create_namespace("otis_frame")
local xterm = { [0] = "000000", "cd0000", "00cd00", "cdcd00", "0000ee", "cd00cd", "00cdcd", "e5e5e5", "7f7f7f", "ff0000", "00ff00", "ffff00", "5c5cff", "ff00ff", "00ffff", "ffffff" }
local function indexed(n)
  if n < 16 then
    local c = vim.g["terminal_color_" .. n]
    return c and c:gsub("^#", "") or xterm[n]
  elseif n < 232 then
    local function c(v)
      return v == 0 and 0 or 55 + v * 40
    end
    n = n - 16
    return ("%02x%02x%02x"):format(c(math.floor(n / 36)), c(math.floor(n / 6) % 6), c(n % 6))
  end
  local g = 8 + (n - 232) * 10
  return ("%02x%02x%02x"):format(g, g, g)
end
local function sgr(st, params)
  local p = {}
  for x in ((params == "" and "0" or params):gsub(":", ";") .. ";"):gmatch("([^;]*);") do
    table.insert(p, x)
  end
  local i = 1
  while i <= #p do
    local n = tonumber(p[i]) or 0
    if n == 0 then
      st.fg, st.bg, st.bold, st.italic, st.underline = nil, nil, nil, nil, nil
    elseif n == 1 then
      st.bold = true
    elseif n == 3 then
      st.italic = true
    elseif n == 4 then
      st.underline = true
    elseif n == 22 then
      st.bold = nil
    elseif n == 23 then
      st.italic = nil
    elseif n == 24 then
      st.underline = nil
    elseif n == 39 then
      st.fg = nil
    elseif n == 49 then
      st.bg = nil
    elseif n >= 30 and n <= 37 or n >= 90 and n <= 97 then
      st.fg = indexed(n % 10 + (n >= 90 and 8 or 0))
    elseif n >= 40 and n <= 47 or n >= 100 and n <= 107 then
      st.bg = indexed(n % 10 + (n >= 100 and 8 or 0))
    elseif n == 38 or n == 48 then
      local key = n == 38 and "fg" or "bg"
      if p[i + 1] == "2" then
        -- 38;2;r;g;b, or 38:2::r:g:b with its empty color space
        if p[i + 2] == "" and #p >= i + 5 then
          i = i + 1
        end
        st[key] = ("%02x%02x%02x"):format(tonumber(p[i + 2]) or 0, tonumber(p[i + 3]) or 0, tonumber(p[i + 4]) or 0)
        i = i + 4
      elseif p[i + 1] == "5" then
        st[key] = indexed(tonumber(p[i + 2]) or 0)
        i = i + 2
      end
    end
    i = i + 1
  end
end
-- render(raw): the lines as text, and the highlights over them as
-- { row, from, to, group } in bytes, a line's to of -1 its background on to
-- the window's edge (\e[K).
local function render(raw)
  local lines, marks, made, st = {}, {}, {}, {}
  local function group()
    local name = ("OtisFrame_%s_%s_%s%s%s"):format(st.fg or "n", st.bg or "n", st.bold and "b" or "", st.italic and "i" or "", st.underline and "u" or "")
    if not made[name] then
      vim.api.nvim_set_hl(0, name, { fg = st.fg and "#" .. st.fg, bg = st.bg and "#" .. st.bg, bold = st.bold, italic = st.italic, underline = st.underline })
      made[name] = true
    end
    return name
  end
  for row, l in ipairs(raw) do
    local out, col, pos = {}, 0, 1
    local function put(text)
      text = text:gsub("\30", "")
      if text == "" then
        return
      end
      table.insert(out, text)
      if st.fg or st.bg or st.bold or st.italic or st.underline then
        table.insert(marks, { row - 1, col, col + #text, group() })
      end
      col = col + #text
    end
    while true do
      local s = l:find("\27", pos, true)
      if not s then
        put(l:sub(pos))
        break
      end
      put(l:sub(pos, s - 1))
      local _, e, params, final = l:find("^%[([%d;:?]*)(%a)", s + 1)
      if e then
        if final == "m" then
          sgr(st, params)
        elseif final == "K" and st.bg then
          table.insert(marks, { row - 1, col, -1, group() })
        end
      else
        -- An OSC (a link), to its BEL or ST, or a lone escape.
        _, e = l:find("^%].-\7", s + 1)
        if not e then
          _, e = l:find("^%].-\27\\", s + 1)
        end
      end
      pos = (e or s) + 1
    end
    lines[row] = table.concat(out)
  end
  return lines, marks
end

-- text(file): a row's preview, colors and all, in the code window, for a
-- row with no file to open (a case, a heading): drawn whole before it shows,
-- with no gutter, as wide as the window it was drawn for. The lines the
-- picker marks for itself (\036) are its own.
function M.text(file)
  local code = M.code()
  local raw = {}
  for _, l in ipairs(vim.fn.readfile(file)) do
    if not l:match("^\30") then
      table.insert(raw, l)
    end
  end
  local lines, marks = render(raw)
  -- From the code window, the buffer shown before anything is set on it, in
  -- the one redraw: what nvim does to a buffer in no window (an option set)
  -- it does through a window of its own as wide as the screen, which from
  -- the list's resized the list's terminal to all of it.
  vim.api.nvim_win_call(code, function()
    local b = M.preview()
    if vim.api.nvim_win_get_buf(code) ~= b then
      vim.api.nvim_win_set_buf(code, b)
    end
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
    for _, m in ipairs(marks) do
      if m[3] == -1 then
        pcall(vim.api.nvim_buf_set_extmark, b, ns, m[1], m[2], { end_row = m[1] + 1, end_col = 0, hl_group = m[4], hl_eol = true })
      else
        vim.api.nvim_buf_set_extmark(b, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
      end
    end
    vim.bo[b].modifiable = false
    -- No listchars either: a preview pads its lines with spaces, which a
    -- trail:- drew as dashes.
    set(code, vim.tbl_extend("force", gutter, { wrap = false, list = false }))
    vim.api.nvim_win_set_cursor(code, { 1, 0 })
    vim.fn.winrestview({ topline = 1, leftcol = 0 })
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
