#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- otis-frame: a picker inside nvim, its output and exit status its own.
# With another editor, or inside a frame already, the command runs as it is.
expect frame/not-nvim "$(OTIS_EDITOR=$tmp/eds/cursor otis-frame sh -c 'echo out; exit 3'; echo "rc=$?")" "out
rc=3"
expect frame/inside-frame "$(OTIS_NVIM_FRAME=1 OTIS_EDITOR=$tmp/eds/nvim otis-frame sh -c 'echo out'; echo "rc=$?")" "out
rc=0"
if command -v nvim >/dev/null 2>&1; then
  # A file shows right of the list, which keeps 30% and 46 columns at least
  # (of 80), the cursor on the column asked for or, with 0, the first
  # non-blank; the keys stay with the list, and the code's width is where
  # the picker reads it.
  printf 'one\n  two words\n' > "$tmp/frame.txt"
  fopen() { OTIS_NVIM_FRAME=$tmp nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua dofile('$share/frame.lua').open('$tmp/frame.txt', 2, $1, false)" \
    -c 'lua io.stdout:write(#vim.api.nvim_tabpage_list_wins(0), " ", vim.bo.buftype, " ", table.concat(vim.api.nvim_win_get_cursor(vim.t.otis_code), ","), " ", vim.api.nvim_win_get_width(vim.t.otis_list), " ", vim.fn.readfile(vim.env.OTIS_NVIM_FRAME .. "/cols")[1])' -c 'qa!' 2>&1; }
  expect frame/open-col "$(fopen 7)" "2 terminal 2,6 46 33"
  expect frame/open-line "$(fopen 0)" "2 terminal 2,2 46 33"
  # A file's line is lit where it opens, and a preview after it has none.
  printf 'hello\n' > "$tmp/pv0.txt"
  expect frame/open-lit "$(OTIS_NVIM_FRAME=$tmp nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua local f = dofile('$share/frame.lua'); f.open('$tmp/frame.txt', 2, 0, false); io.stdout:write(tostring(vim.wo[vim.t.otis_code].cursorline), ' '); f.text('$tmp/pv0.txt'); io.stdout:write(tostring(vim.wo[vim.t.otis_code].cursorline))" -c 'qa!' 2>&1)" "true false"
  # A preview after a file is written into a buffer of its own, never into
  # the file's, which shows as it was when opened again.
  expect frame/preview-apart "$(OTIS_NVIM_FRAME=$tmp nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua local f = dofile('$share/frame.lua'); f.open('$tmp/frame.txt', 1, 0, false); f.text('$tmp/pv0.txt'); f.open('$tmp/frame.txt', 1, 0, false); io.stdout:write(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(vim.t.otis_code), 0, 1, false)[1])" -c 'qa!' 2>&1)" "one"
  # What the lit row's symbol uses underlined in its lines of the file it
  # opened, as _name_: not after a dot unless a spread's, nor before a colon.
  # The next row's take their place; none in a base beside it, a preview, the
  # file come back to after a case, or a row that uses nothing.
  printf 'exec sleep 9\n' > "$tmp/frun"
  printf 'new Cart(); helper(c.helper())\nconst o = { helper: 1, Cart }\nf(...helper)\n' > "$tmp/u.ts"
  printf 'helper Cart\n' > "$tmp/pv4.txt"
  cat > "$tmp/underline.lua" <<'EOF'
local f, seen = dofile(vim.env.SHARE .. "/frame.lua"), {}
local set = vim.api.nvim_buf_set_extmark
vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, o)
  if o.hl_group == "OtisFrameChanged" then
    seen[buf .. ":" .. row .. ":" .. col] = { row, col, o.end_col }
  end
  return set(buf, ns, row, col, o)
end
local function shown()
  local buf = vim.api.nvim_get_current_buf()
  seen = {}
  vim.cmd("redraw!")
  local lines, at = vim.api.nvim_buf_get_lines(buf, 0, -1, false), {}
  for k, m in pairs(seen) do
    if k:match("^" .. buf .. ":") then
      table.insert(at, m)
    end
  end
  table.sort(at, function(a, b) return a[1] > b[1] or a[1] == b[1] and a[2] > b[2] end)
  for _, m in ipairs(at) do
    local l = lines[m[1] + 1]
    lines[m[1] + 1] = l:sub(1, m[2]) .. "_" .. l:sub(m[2] + 1, m[3]) .. "_" .. l:sub(m[3] + 1)
  end
  io.stdout:write(table.concat(lines, "|"), "\n")
end
vim.o.showmode = false
f.start()
vim.api.nvim_set_current_win(vim.t.otis_code)
f.open(vim.env.TMP .. "/u.ts", 1, 0, false, "1 2 0 0 helper")
shown()
f.open(vim.env.TMP .. "/u.ts", 1, 0, false, "1 3 0 0 Cart helper")
shown()
local base = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(base, 0, -1, false, { "helper(Cart)" })
vim.bo[base].buftype = "nowrite"
vim.cmd("aboveleft vertical sbuffer " .. base)
shown()
vim.cmd("close")
local file = vim.api.nvim_get_current_buf()
f.text(vim.env.TMP .. "/pv4.txt")
shown()
vim.api.nvim_win_set_buf(vim.t.otis_code, file)
shown()
f.open(vim.env.TMP .. "/u.ts", 2, 0, false, "")
shown()
EOF
  mkdir -p "$tmp/uf"
  expect frame/underline "$(SHARE=$share TMP=$tmp OTIS_NVIM_FRAME=$tmp/uf OTIS_NVIM_FRAME_RUN=$tmp/frun OTIS_NVIM_FRAME_STATUS=$tmp/uf/status nvim --clean --headless -c "luafile $tmp/underline.lua" -c 'qa!' 2>&1)" "new Cart(); _helper_(c.helper())|const o = { helper: 1, Cart }|f(...helper)
new _Cart_(); _helper_(c.helper())|const o = { helper: 1, _Cart_ }|f(..._helper_)
helper(Cart)
helper Cart
new Cart(); helper(c.helper())|const o = { helper: 1, Cart }|f(...helper)
new Cart(); helper(c.helper())|const o = { helper: 1, Cart }|f(...helper)"
  # The list stays put when its cursor sits at a row's end, where a config's
  # sidescrolloff slid it sideways as you left it for the code.
  printf 'printf %%046d 0; exec sleep 9\n' > "$tmp/frun2"
  mkdir -p "$tmp/uf2"
  expect frame/list-stays "$(SHARE=$share OTIS_NVIM_FRAME=$tmp/uf2 OTIS_NVIM_FRAME_RUN=$tmp/frun2 OTIS_NVIM_FRAME_STATUS=$tmp/uf2/status nvim --clean --headless -c 'set sidescrolloff=8 noshowmode' -c "lua local f = dofile('$share/frame.lua'); f.start(); local l = vim.t.otis_list
    vim.wait(2000, function() return #vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(l), 0, 1, false)[1] >= 46 end)
    vim.api.nvim_win_set_cursor(l, { 1, 45 }); vim.cmd('redraw'); io.stdout:write(vim.api.nvim_win_call(l, vim.fn.winsaveview).leftcol)" -c 'qa!' 2>&1)" "0"
  # A row with no file shows its preview there, less the lines the picker
  # marks for itself.
  printf '\036pin 1\nhello there\nworld\n' > "$tmp/pv.txt"
  expect frame/text "$(OTIS_NVIM_FRAME=$tmp nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua dofile('$share/frame.lua').text('$tmp/pv.txt')" -c 'sleep 200m' \
    -c 'lua local b = vim.api.nvim_win_get_buf(vim.t.otis_code); io.stdout:write(vim.bo.buftype, " ", table.concat(vim.tbl_filter(function(x) return x ~= "" end, vim.api.nvim_buf_get_lines(b, 0, -1, false)), "|"))' -c 'qa!' 2>&1)" "terminal hello there|world"
  # Its colors are highlights on the plain text, with no gutter beside it.
  printf '\033[38;2;250;189;47mhi\033[0m there\n' > "$tmp/pv2.txt"
  expect frame/text-colors "$(OTIS_NVIM_FRAME=$tmp nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua dofile('$share/frame.lua').text('$tmp/pv2.txt')" \
    -c 'lua local c = vim.t.otis_code; local b = vim.api.nvim_win_get_buf(c); local m = vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })[1]; io.stdout:write(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], " ", m[3], "-", m[4].end_col, " ", ("%06x"):format(vim.api.nvim_get_hl(0, { name = m[4].hl_group }).fg), " number=", tostring(vim.wo[c].number))' -c 'qa!' 2>&1)" "hi there 0-2 fabd2f number=false"
  # A case read down to line 30 stays there as it is drawn again (a thread
  # landed), and when you come back to it from another case or a file; a new
  # case, or a preview with no key, is at its top.
  seq 1 80 > "$tmp/pv5.txt"
  expect frame/text-keeps-place "$(OTIS_NVIM_FRAME=$tmp nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua local f = dofile('$share/frame.lua')
    local function top() io.stdout:write(vim.api.nvim_win_call(vim.t.otis_code, vim.fn.winsaveview).topline, ' ') end
    f.text('$tmp/pv5.txt', 'a'); vim.api.nvim_win_call(vim.t.otis_code, function() vim.fn.winrestview({ lnum = 30, topline = 30 }) end)
    f.text('$tmp/pv5.txt', 'a'); top(); f.text('$tmp/pv5.txt', 'b'); top(); f.text('$tmp/pv5.txt', 'a'); top()
    f.open('$tmp/frame.txt', 1, 0, false); f.text('$tmp/pv5.txt', 'a'); top(); f.text('$tmp/pv5.txt'); top()" -c 'qa!' 2>&1)" "30 1 30 30 1 "
  # ] and [ pressed in the list go to the code's next and last change: a
  # file's since the base (5 and 40 changed, 20 taken out), a symbol's own on
  # its row (lines 10 to 45, never 5), a removed one's where it was, and a
  # preview's on a diff's background but the code's own.
  fkeys() { OTIS_NVIM_FRAME=$tmp OTIS_T_CODEBG='48;2;1;2;3' nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua local f = dofile('$share/frame.lua'); f.$1; for _, k in ipairs({ ']', ']', ']', '[', '[' }) do f.key(k); vim.wait(260); io.stdout:write(vim.api.nvim_win_get_cursor(vim.t.otis_code)[1], ' ') end" -c 'qa!' 2>&1; }
  ( mkdir -p "$tmp/fk" && cd "$tmp/fk" && seq 1 60 > n.txt && git init -q . && git add n.txt && git -c user.email=t@t -c user.name=t commit -qm n && sed -i.bak -e '5s/.*/a/' -e 20d -e '40s/.*/x/' n.txt )
  expect frame/key-file "$(fkeys "open('$tmp/fk/n.txt', 1, 0, false)")" "5 19 39 19 5 "
  expect frame/key-symbol "$(fkeys "open('$tmp/fk/n.txt', 10, 0, false, '10 45 10 46')")" "19 39 39 19 10 "
  expect frame/key-removed "$(fkeys "open('$tmp/fk/n.txt', 1, 0, false, '0 0 20 20')")" "19 19 19 1 1 "
  # Come back to with [, a row opens on its last change; where it opened is a stop on the way back out.
  expect frame/key-back-to-last "$(fkeys "open('$tmp/fk/n.txt', 10, 0, false, '10 45 10 46', 'last')")" "39 39 39 19 10 "
  # Enter stays on what you are looking at when the row already shows; on another row it opens that one.
  expect frame/enter-stays "$(OTIS_NVIM_FRAME=$tmp nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua local f = dofile('$share/frame.lua'); local c = function() return vim.api.nvim_win_get_cursor(vim.t.otis_code)[1] end; f.open('$tmp/fk/n.txt', 10, 0, false, '10 45 10 46'); f.key(']'); vim.wait(260); f.open('$tmp/fk/n.txt', 10, 0, false, '10 45 10 46', 'here'); io.stdout:write(c(), ' '); f.open('$tmp/fk/n.txt', 30, 0, false, '30 45 30 46', 'here'); io.stdout:write(c())" -c 'qa!' 2>&1)" "19 30"
  # A removed symbol's row opens on no line of the file: [ goes on to the row before, and is no error.
  expect frame/key-removed-back "$(fkeys "open('$tmp/fk/n.txt', 0, 0, false, '0 0 70 70')")" "1 1 1 1 1 "
  printf 'a\n\033[48;2;1;2;3mcode\033[m\n\033[48;2;0;50;0m+new\033[m\nb\n\033[48;2;50;0;0m-old\033[m\n' > "$tmp/pv3.txt"
  expect frame/key-preview "$(fkeys "text('$tmp/pv3.txt')")" "3 5 5 3 3 "
fi
if command -v nvim >/dev/null 2>&1; then
  # The change drawn on the file (diffmarks.lua): new lines on the diff's ground, the word that changed brighter, what
  # was taken out one dim line until the cursor is on it, then whole. Lines moved from elsewhere stay plain.
  ( mkdir -p "$tmp/dm" && cd "$tmp/dm" && seq 1 40 | sed 's/$/ original line of text/' > n.txt && seq 100 120 | sed 's/$/ this block of words will move away/' > moved.txt &&
    git init -q . && git add . && git -c user.email=t@t -c user.name=t commit -qm base &&
    { sed -e '5s/original/changed/' -e '20,22d' n.txt; seq 100 120 | sed 's/$/ this block of words will move away/'; echo 'brand new line'; } > n.new && mv n.new n.txt && : > moved.txt &&
    git add . && git -c user.email=t@t -c user.name=t commit -qm change )
  dmb=$(git -C "$tmp/dm" rev-parse HEAD~1) dmh=$(git -C "$tmp/dm" rev-parse HEAD)
  cat > "$tmp/dm.lua" <<'EOF'
local marks = dofile(vim.env.SHARE .. "/diffmarks.lua")
vim.cmd("edit n.txt")
local buf = vim.api.nvim_get_current_buf()
marks.attach(buf)
vim.wait(3000, function() return vim.iter(marks.hunks(buf)):any(function(h) return h.moved end) end, 20)
local function report()
  local new, moved, word, old = {}, {}, {}, {}
  for _, ns in ipairs({ "otis_diffmarks", "otis_diffmarks_old" }) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace(ns), 0, -1, { details = true })) do
      local d = m[4]
      if d.line_hl_group then new[#new + 1] = m[2] + 1 end
      if d.sign_text then moved[#moved + 1] = m[2] + 1 end
      if d.hl_group == "OtisDiffNewWord" then word[#word + 1] = (m[2] + 1) .. ":" .. m[3] .. "-" .. d.end_col end
      if d.virt_lines then
        local ls = {}
        for _, l in ipairs(d.virt_lines) do ls[#ls + 1] = vim.trim(l[1][1]) end
        old[#old + 1] = table.concat(ls, "/")
      end
    end
  end
  return ("new %s; moved %d; word %s; old %s"):format(table.concat(new, ","), #moved, table.concat(word, ","), table.concat(old, " | "))
end
io.stdout:write(report(), "\n")
vim.api.nvim_win_set_cursor(0, { 20, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
io.stdout:write(report(), "\n")
local runs = {}
for _, h in ipairs(marks.hunks(buf)) do runs[#runs + 1] = (h.moved and "moved" or "new") .. ":" .. h[1] .. "-" .. h[2] end
io.stdout:write(table.concat(runs, " "), "\n")
vim.cmd("qa!")
EOF
  dm=$(cd "$tmp/dm" && SHARE=$share NVIM_DIFF_BASE=$dmb GMR_RANGE="$dmb..$dmh" nvim --clean --headless -c "luafile $tmp/dm.lua" -c "qa!" 2>&1 | tr -d '\r')
  printf '%s\n' "$dm" > "$tmp/dm.out"
  expect diffmarks/moved-is-no-stop "$(sed -n 3p "$tmp/dm.out")" "new:5-5 new:19-19 new:59-59"
  expect diffmarks/drawn "$(sed -n 1p "$tmp/dm.out")" "new 5,59; moved 21; word 5:2-9; old − 1 line | − 3 lines"
  expect diffmarks/whole-at-the-cursor "$(sed -n 2p "$tmp/dm.out" | sed 's/.*old //')" "− 1 line | 20 original line of text/21 original line of text/22 original line of text"
  # Pressed in the list, with no cursor to see: the change you land on lit, its old lines open, a ▶ on your line.
  cat > "$tmp/dmh.lua" <<'EOF'
local f = dofile(vim.env.SHARE .. "/frame.lua")
vim.t.otis_code_opts = {}
vim.cmd("terminal")
vim.t.otis_list = vim.api.nvim_get_current_win()
f.open(vim.fn.getcwd() .. "/n.txt", 1, 0, false)
local buf = vim.api.nvim_win_get_buf(vim.t.otis_code)
f.key("]"); f.key("]"); vim.wait(260)
local lit, sign, old = {}, nil, {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("otis_diffmarks_here"), 0, -1, { details = true })) do
  if m[4].line_hl_group == "OtisDiffHere" then lit[#lit + 1] = m[2] + 1 end
  if m[4].sign_text then sign = m[2] + 1 end
end
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("otis_diffmarks_old"), 0, -1, { details = true })) do
  old[#old + 1] = #m[4].virt_lines
end
io.stdout:write(("line %d lit %s sign %s old %s"):format(vim.api.nvim_win_get_cursor(vim.t.otis_code)[1], table.concat(lit, ","), tostring(sign), table.concat(old, ",")))
vim.cmd("qa!")
EOF
  expect diffmarks/landing-from-the-list "$(cd "$tmp/dm" && SHARE=$share OTIS_NVIM_FRAME=$tmp NVIM_DIFF_BASE=$dmb nvim --clean --headless -c "luafile $tmp/dmh.lua" -c "qa!" 2>&1 | tr -d '\r')" "line 19 lit  sign 19 old 1,3"
  # leftover.mjs says which lines only moved, a lone } never one of them.
  expect leftover/moved "$(cd "$tmp/dm" && node "$share/leftover.mjs" "$dmb" "$dmh" | cut -f1,2 | sort | uniq -c | awk '{ print $2 ":" $3 ":" $1 }' | tr '\n' ' ')" "new:n.txt:21 old:moved.txt:21 "
  # ] past the row's last change goes on: the list is told to move, as if . was pressed there; [ the other way. A
  # run taller than the window is read a screen at a time first.
  cat > "$tmp/dmk.lua" <<'EOF'
local f = dofile(vim.env.SHARE .. "/frame.lua")
vim.t.otis_code_opts = {}
vim.cmd("terminal sh -c 'stty raw; exec cat > " .. vim.env.SENT .. "'")
vim.t.otis_list = vim.api.nvim_get_current_win()
f.open(vim.env.TALL, 1, 0, false)
local code = vim.t.otis_code
vim.api.nvim_win_set_height(code, 10)
local seen = {}
for _ = 1, 3 do f.key("]"); vim.wait(260); seen[#seen + 1] = vim.api.nvim_win_get_cursor(code)[1] end
io.stdout:write(table.concat(seen, " "), "\n")
for _ = 1, 40 do f.key("]"); vim.wait(5) end
vim.wait(300)
vim.cmd("qa!")
EOF
  ( mkdir -p "$tmp/tl" && cd "$tmp/tl" && echo start > t.txt && git init -q . && git add . && git -c user.email=t@t -c user.name=t commit -qm base && { echo start; seq 1 60; } > t.txt )
  dmk=$(cd "$tmp/tl" && SHARE=$share SENT=$tmp/sent TALL=$tmp/tl/t.txt OTIS_NVIM_FRAME=$tmp nvim --clean --headless -c "luafile $tmp/dmk.lua" -c "qa!" 2>&1 | tr -d '\r')
  expect frame/key-pages-a-tall-run "$(printf '%s' "$dmk" | awk '{ print ($1 == 2 && $2 > $1 && $3 > $2) }')" "1"
  expect frame/key-tells-the-list "$(tr -dc '.' < "$tmp/sent" | wc -c | awk '{ print ($1 >= 1) }')" "1"
fi
# F on the board (otis-find): nvim opened straight into your own fuzzy finder
# (share/find.lua), which reads what git config otis.finder names.
expect find/nvim "$(OTIS_EDITOR=$tmp/eds/nvim otis-find)" "-c luafile $root/share/find.lua"

