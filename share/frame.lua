-- otis-frame's nvim: a picker's list in a terminal on the left and, where
-- its preview was, nvim itself. start() lays the two windows out and runs
-- the picker (otis-frame's script) in the left one. The rest is for what
-- the picker runs, through $NVIM (otis-frame --open, --text, --run,
-- --focus, --key): a file shown on the right, or a row's preview where it has no
-- file, the list keeping the keys, the pane's keys passed on, and enter's step into the code. The windows are
-- kept on the tab, as this file is loaded afresh on every call.
local M = {}

-- Loaded once: it keeps what it has read, and this file is loaded afresh on every call.
local function marks()
  package.loaded.otis_diffmarks = package.loaded.otis_diffmarks or dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/diffmarks.lua")
  return package.loaded.otis_diffmarks
end

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

-- tell_list(key): a key pressed in the list, whichever window you are in: its terminal is what reads its keys.
local function tell_list(key)
  local list = vim.t.otis_list
  local job = valid(list) and vim.b[vim.api.nvim_win_get_buf(list)].terminal_job_id
  if job then
    vim.api.nvim_chan_send(job, key)
  end
end

-- No gutter beside the list or a preview: they are drawn as wide as their
-- window, and a file's line numbers are not theirs.
local gutter = { number = false, relativenumber = false, signcolumn = "no", statuscolumn = "", foldcolumn = "0" }
-- The list's window options: no gutter, and a width it keeps whatever the
-- windows around it do (winfixwidth: closing a split beside the code, or a
-- config evening the windows out on a resize, leaves it be). A split made
-- from it takes them, and the code window gives them back. No sidescrolloff:
-- a config's slid the list sideways as you left it, its cursor near the edge.
local list_opts = vim.tbl_extend("force", gutter, { spell = false, winfixwidth = true, wrap = false, list = false, sidescrolloff = 0 })

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
  -- And no tab line: a config turns one on as it loads, unannounced too.
  if vim.o.showtabline ~= 0 then
    vim.o.showtabline = 0
  end
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

-- keep(b): where the code window is in the preview, kept for the row it
-- shows (text's key) before something else is drawn there, as the picker's
-- pane keeps each row's scroll.
local function keep(b)
  local code, key = vim.t.otis_code, vim.b[b].otis_key
  if key and valid(code) and vim.api.nvim_win_get_buf(code) == b then
    local views = vim.b[b].otis_views or {}
    views[key] = vim.api.nvim_win_call(code, vim.fn.winsaveview)
    vim.b[b].otis_views = views
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
    -- Named, or the first file opened took it (:edit reuses an empty buffer
    -- with no name), and every preview after was written into that file.
    vim.api.nvim_buf_set_name(b, "otis://preview")
    vim.b[b].otis_text = true
    vim.t.otis_preview = b
    -- A file opened in its place: back on the row, where you were.
    vim.api.nvim_create_autocmd("BufWinLeave", {
      buffer = b,
      callback = function()
        keep(b)
      end,
    })
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

-- underline(): what the lit row's symbol uses underlined in its lines of the
-- file that row opened (open's otis_lit) while it is in the code window,
-- matched as the picker's diff preview matched them (git-symbols' mark_awk):
-- not after a dot unless a spread's, nor before a colon or a ?.
local function underline()
  local ns, lit = vim.api.nvim_create_namespace("otis_frame_names"), nil
  -- Again after a colorscheme, whose :hi clear takes it.
  local function hl()
    vim.api.nvim_set_hl(0, "OtisFrameChanged", { underline = true })
  end
  hl()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = hl })
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf)
      lit = vim.t.otis_lit
      lit = lit and win == vim.t.otis_code and buf == lit.buf and next(lit.names) and lit or nil
      return lit ~= nil
    end,
    on_line = function(_, _, buf, row)
      if row + 1 < lit.lines[1] or row + 1 > lit.lines[2] then
        return
      end
      local l = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      for s, word, e in l:gmatch("()([%w_$]+)()") do
        if lit.names[word] and (l:sub(s - 1, s - 1) ~= "." or l:sub(s - 3, s - 1) == "...") and not l:find("^%s*[:?]", e) then
          vim.api.nvim_buf_set_extmark(buf, ns, row, s - 1, { end_col = e - 1, hl_group = "OtisFrameChanged", ephemeral = true })
        end
      end
    end,
  })
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
  -- Where a change has a base: what it did drawn on each file that shows, however you got there (diffmarks.lua).
  -- And in the code, the same walk the list has, so reading on never means leaving the file: enter on and backspace
  -- back, as in a pager, where neither does anything a reader misses.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    callback = function(ev)
      if ev.buf == buf or vim.fn.win_gettype() ~= "" then
        return
      end
      if vim.env.NVIM_DIFF_BASE then
        marks().attach(ev.buf)
      end
      vim.keymap.set("n", "<CR>", function()
        M.key("]")
      end, { buffer = ev.buf, desc = "otis: read on" })
      vim.keymap.set("n", "<BS>", function()
        M.key("[")
      end, { buffer = ev.buf, desc = "otis: read back" })
      vim.keymap.set("n", "<leader>mv", function()
        tell_list("v")
      end, { buffer = ev.buf, desc = "otis: this row viewed" })
      vim.keymap.set("n", "<leader>ma", function()
        vim.api.nvim_set_current_win(vim.t.otis_list)
        tell_list("A")
      end, { buffer = ev.buf, desc = "otis: approve" })
    end,
  })
  -- Moving in the code moves the list: gd into a helper the change touches and its row lights up. Only from the code,
  -- or a row you just left would come back and take the cursor from you. Asked for a moment after you stop.
  local timer = vim.uv.new_timer()
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    callback = function()
      timer:start(120, 0, vim.schedule_wrap(function()
        local code = vim.t.otis_code
        if not valid(code) or vim.api.nvim_get_current_win() ~= code then
          return
        end
        local b = vim.api.nvim_win_get_buf(code)
        if vim.bo[b].buftype ~= "" then
          return
        end
        local at = vim.env.OTIS_NVIM_FRAME .. "/at"
        vim.fn.writefile({ vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":.") .. "\t" .. vim.api.nvim_win_get_cursor(code)[1] }, at .. ".new")
        vim.uv.fs_rename(at .. ".new", at)
      end))
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
  underline()
  vim.cmd.startinsert()
end

-- changes(win): the runs of lines to read in the window, { first, last } in order: a preview's, found as it was drawn
-- (text), or a file's since the change's base (NVIM_DIFF_BASE, else HEAD), less those that only moved. In the lit
-- row's file, its symbol's alone: those that touch its lines here or in the base, cut to its lines here.
local function changes(win)
  local b = vim.api.nvim_win_get_buf(win)
  if vim.b[b].otis_text then
    return vim.b[b].otis_changes or {}
  end
  local lit, runs = vim.t.otis_lit, {}
  lit = lit and lit.buf == b and lit or nil
  local function meets(at, n, lines)
    return n > 0 and at <= lines[2] and at + n > lines[1]
  end
  for _, h in ipairs(marks().hunks(b)) do
    if not h.moved then
      if not lit then
        table.insert(runs, { h[1], h[2] })
      elseif meets(h[1], h.count, lit.lines) then
        table.insert(runs, { math.max(h[1], lit.lines[1]), math.min(h[2], lit.lines[2]) })
      elseif meets(h[3], h.base_count, lit.base) then
        table.insert(runs, { h[1], h[2] })
      end
    end
  end
  return runs
end

-- open(path, line, col, readonly, symbol): the file in the code window, its
-- cursor on line and col (bytes, 1-based; 0 is the line's first non-blank).
-- symbol, "<first> <last> <base first> <base last> <name>...", is the row's
-- (git-symbols --deps): its lines here and in the change's base, 0 0 for
-- none, where ] and [ stay, and the changed symbols it uses, underlined in
-- its lines while the file shows here. how: "stay", the cursor is already where you want it (the list following you,
-- not you following the list), so it does not move; "last", you came back to this row with [, so on its last change,
-- as ] left it. line is the row's first stop either way (otis_home), where [ comes to before it leaves the row.
function M.open(path, line, col, readonly, symbol, how)
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
      -- preview), off the buffer list, so no list of buffers ever shows it:
      -- each time it shows, since :edit puts an unlisted buffer back on.
      if fresh or vim.b.otis_shown then
        vim.b.otis_shown = true
        vim.bo.buflisted = false
      end
    end
    -- A preview there before had the gutter off: a file has yours, and the
    -- line a row opens on lit, as the list lights the row, whatever yours is.
    set(code, vim.tbl_extend("force", vim.t.otis_code_opts, { cursorline = true }))
    if readonly then
      vim.bo.readonly = true
      vim.bo.modifiable = false
    end
    if vim.env.NVIM_DIFF_BASE then
      marks().attach(vim.api.nvim_get_current_buf())
    end
    if how ~= "stay" then
      pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(col - 1, 0) })
      if col == 0 then
        vim.cmd("normal! ^")
      end
      vim.cmd("normal! zz")
    end
    -- A removed symbol's row asks for line 0: home is where that left you.
    vim.t.otis_home = how == "stay" and math.max(line, 1) or vim.fn.line(".")
    local w, names = vim.split(symbol or "", " ", { trimempty = true }), {}
    for i = 5, #w do
      names[w[i]] = true
    end
    vim.t.otis_lit = w[4] and { buf = vim.api.nvim_get_current_buf(), lines = { tonumber(w[1]), tonumber(w[2]) }, base = { tonumber(w[3]), tonumber(w[4]) }, names = names } or nil
    if how == "last" then
      local runs = changes(code)
      if #runs > 0 then
        pcall(vim.api.nvim_win_set_cursor, 0, { runs[#runs][1], 0 })
        vim.cmd("normal! zz")
      end
    end
    -- A move inside the code window from here is no CursorMoved: you are in the list.
    if how ~= "stay" then
      marks().land(vim.api.nvim_get_current_buf(), vim.fn.line("."))
    end
  end)
  -- A row can land while its file already shows, so no window event says it: for what draws on files (mr-comments.lua).
  vim.api.nvim_exec_autocmds("User", { pattern = "OtisFrameOpen" })
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

-- text(file, key): a row's preview, colors and all, in the code window, for a
-- row with no file to open (a case, a heading): drawn whole before it shows,
-- with no gutter, as wide as the window it was drawn for. The lines the
-- picker marks for itself (\036) are its own. key names the row: drawn again
-- (something landed) or come back to, it is where you left it, else at its top.
function M.text(file, key)
  local code = M.code()
  local raw = {}
  for _, l in ipairs(vim.fn.readfile(file)) do
    if not l:match("^\30") then
      table.insert(raw, l)
    end
  end
  local lines, marks = render(raw)
  -- The lit row is no symbol's: nothing underlined, whatever comes back here.
  vim.t.otis_lit = nil
  vim.t.otis_home = nil
  -- From the code window, the buffer shown before anything is set on it, in
  -- the one redraw: what nvim does to a buffer in no window (an option set)
  -- it does through a window of its own as wide as the screen, which from
  -- the list's resized the list's terminal to all of it.
  vim.api.nvim_win_call(code, function()
    local b = M.preview()
    keep(b)
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
    -- Its changes, for ] and [ (key): runs of lines on a diff's background,
    -- the code's own (OTIS_T_CODEBG) aside, as the picker's pane finds them.
    local codebg, runs = vim.env.OTIS_T_CODEBG or "", {}
    for i, l in ipairs(raw) do
      if l:find("\27[48;", 1, true) and (codebg == "" or not l:find("\27[" .. codebg .. "m", 1, true)) then
        local last = runs[#runs]
        if last and last[2] == i - 1 then
          last[2] = i
        else
          table.insert(runs, { i, i })
        end
      end
    end
    vim.b[b].otis_changes = runs
    -- No listchars either: a preview pads its lines with spaces, which a
    -- trail:- drew as dashes. Nor a lit line: its first is no symbol's.
    set(code, vim.tbl_extend("force", gutter, { wrap = false, list = false, cursorline = false }))
    vim.b[b].otis_key = key
    vim.fn.winrestview(key and (vim.b[b].otis_views or {})[key] or { lnum = 1, col = 0, topline = 1, leftcol = 0 })
  end)
end

-- run(cmd, arg): an Ex command in the code window, the keys left with the
-- list: a review's :GmrDeleted, a deleted file beside its base, no symbol's
-- to underline.
function M.run(cmd, arg)
  vim.t.otis_lit = nil
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

-- glide(win, lnum, top): the window's view there, the code sliding rather than jumping so your eye can follow it. A key
-- pressed meanwhile finishes it at once (package.loaded.otis_glide, this file being loaded afresh on every call).
local function glide(win, lnum, top)
  local from = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
  local function place(t, l)
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ lnum = l, col = 0, topline = t })
    end)
  end
  if from == top then
    place(top, lnum)
    return
  end
  local timer, step, steps = vim.uv.new_timer(), 0, 8
  local function finish()
    package.loaded.otis_glide = nil
    timer:stop()
    timer:close()
    if valid(win) then
      place(top, lnum)
    end
  end
  package.loaded.otis_glide = finish
  local h = vim.api.nvim_win_get_height(win)
  timer:start(0, 20, vim.schedule_wrap(function()
    if package.loaded.otis_glide ~= finish then
      return
    end
    step = step + 1
    if step >= steps or not valid(win) then
      finish()
      return
    end
    local t = step / steps
    local at = math.floor(from + (top - from) * (1 - (1 - t) ^ 2))
    place(at, math.max(math.min(lnum, at + h - 1), at))
  end))
end

-- What the list's scrolling keys are in the code window: nvim's own.
local scrolls = { ["ctrl-d"] = "\4", ["ctrl-u"] = "\21", ["ctrl-e"] = "\5", ["ctrl-y"] = "\25" }

-- key(name): a key of the picker's pane, done in the code window: ctrl-d, ctrl-u, ctrl-e and ctrl-y scroll it, and ]
-- and [ read on and back, each the exact way back of the other. A row's stops are where it opened and then its runs; ]
-- is the next screen of a run too long for the window, else the next stop, put in the middle. Past the row's last stop
-- the list goes on to its next row (its . and ,), so one key reads the whole change.
function M.key(name)
  local code = vim.t.otis_code
  if not valid(code) then
    return
  end
  if package.loaded.otis_glide then
    package.loaded.otis_glide()
  end
  if scrolls[name] then
    vim.api.nvim_win_call(code, function()
      vim.cmd("normal! " .. scrolls[name])
    end)
    return
  end
  local b = vim.api.nvim_win_get_buf(code)
  local at, to, runs = vim.api.nvim_win_get_cursor(code)[1], nil, changes(code)
  local top = vim.fn.line("w0", code)
  local bottom = vim.fn.line("w$", code)
  -- Where you end up lit at once; the code comes to it.
  local function arrive(lnum, want_top)
    marks().land(b, lnum)
    glide(code, lnum, want_top)
  end
  for _, r in ipairs(runs) do
    if name == "]" and at >= r[1] and at <= r[2] and r[2] > bottom then
      arrive(bottom, math.max(bottom - 2, 1))
      return
    end
    if name == "]" and r[1] > at and not to or name == "[" and r[1] < at then
      to = r
    end
  end
  local home = vim.t.otis_home
  if name == "[" and home and home < at and (not to or home > to[1]) then
    to = { home, home }
  end
  if not to then
    -- Held down, one row at a time: the next row is still being opened.
    local now = vim.uv.now()
    if now - (vim.t.otis_went or 0) > 150 then
      vim.t.otis_went = now
      tell_list(name == "]" and "." or ",")
    end
    return
  end
  -- Already in view, the code stays still and only the light moves. Else in the middle, or from near the top when it
  -- is taller than the window, as the pane put it.
  local h = vim.api.nvim_win_get_height(code)
  local want = top
  if to[1] < top or to[2] > bottom then
    want = math.max(to[2] - to[1] < h and math.floor((to[1] + to[2] - h) / 2) + 1 or to[1] - 3, 1)
  end
  arrive(to[1], want)
end

-- comment(): into the code and a comment on the line you are on (mr-comments.lua), the box under that line.
function M.comment()
  M.focus()
  vim.api.nvim_exec_autocmds("User", { pattern = "OtisComment" })
end

return M
