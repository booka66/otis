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
  fkeys() { OTIS_NVIM_FRAME=$tmp OTIS_T_CODEBG='48;2;1;2;3' nvim --clean --headless -c terminal -c 'let t:otis_list = win_getid() | let t:otis_code_opts = {}' -c "lua local f = dofile('$share/frame.lua'); f.$1; for _, k in ipairs({ ']', ']', ']', '[', '[' }) do f.key(k); io.stdout:write(vim.api.nvim_win_get_cursor(vim.t.otis_code)[1], ' ') end" -c 'qa!' 2>&1; }
  ( mkdir -p "$tmp/fk" && cd "$tmp/fk" && seq 1 60 > n.txt && git init -q . && git add n.txt && git -c user.email=t@t -c user.name=t commit -qm n && sed -i.bak -e '5s/.*/a/' -e 20d -e '40s/.*/x/' n.txt )
  expect frame/key-file "$(fkeys "open('$tmp/fk/n.txt', 1, 0, false)")" "5 19 39 19 5 "
  expect frame/key-symbol "$(fkeys "open('$tmp/fk/n.txt', 10, 0, false, '10 45 10 46')")" "19 39 39 19 19 "
  expect frame/key-removed "$(fkeys "open('$tmp/fk/n.txt', 1, 0, false, '0 0 20 20')")" "19 19 19 19 19 "
  printf 'a\n\033[48;2;1;2;3mcode\033[m\n\033[48;2;0;50;0m+new\033[m\nb\n\033[48;2;50;0;0m-old\033[m\n' > "$tmp/pv3.txt"
  expect frame/key-preview "$(fkeys "text('$tmp/pv3.txt')")" "3 5 5 3 3 "
fi
# F on the board (otis-find): nvim opened straight into your own fuzzy finder
# (share/find.lua), which reads what git config otis.finder names.
expect find/nvim "$(OTIS_EDITOR=$tmp/eds/nvim otis-find)" "-c luafile $root/share/find.lua"

