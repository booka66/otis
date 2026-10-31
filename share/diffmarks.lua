-- diffmarks.lua: what a change did, drawn on the real file in the frame's nvim, so reading a change is reading the
-- file: its syntax, your motions and your language server all still there. New lines on the diff's green, the words
-- a line changed brighter, lines that only moved plain with a ⇄ in the gutter. What was taken out is one dim line
-- until the cursor comes to it, then whole, so old and new are never shuffled together.
--   attach(buf)  draw on a file's buffer, and keep it drawn as it is edited and the cursor moves
--   hunks(buf)   what to read in it, in order: { first, last, base_first, base_last, moved = bool, count, base_count }
--   redraw(buf)  again, after a window went into or out of a diff (which shows all this itself)
local M = {}
local lines_ns = vim.api.nvim_create_namespace("otis_diffmarks")
local old_ns = vim.api.nvim_create_namespace("otis_diffmarks_old")
local kept = {} -- buf -> { tick, hunks, base, at }: a file is diffed once per edit, not on every key

local function colors()
  local function bg(env, group)
    local own = vim.env[env]
    if own and own:match("^#") then
      return own
    end
    local had = vim.api.nvim_get_hl(0, { name = group, link = false }).bg
    return had and ("#%06x"):format(had) or nil
  end
  local faint = vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg
  vim.api.nvim_set_hl(0, "OtisDiffNew", { bg = bg("OTIS_T_PLUS", "DiffAdd") })
  vim.api.nvim_set_hl(0, "OtisDiffNewWord", { bg = bg("OTIS_T_PLUS_WORD", "DiffText") })
  vim.api.nvim_set_hl(0, "OtisDiffOld", { bg = bg("OTIS_T_MINUS", "DiffDelete") })
  vim.api.nvim_set_hl(0, "OtisDiffOldWord", { bg = bg("OTIS_T_MINUS_WORD", "DiffDelete") })
  vim.api.nvim_set_hl(0, "OtisDiffGone", { fg = faint, italic = true })
  vim.api.nvim_set_hl(0, "OtisDiffMoved", { fg = faint })
end

-- The change's moved lines, from the diff alone (leftover.mjs), a review's only: only a review has the two ends.
-- Behind the first file, drawn again when they land. moved.new[path][line], moved.old[path][line].
local moved = { new = {}, old = {} }
local asked = false
local function ask_moved()
  local range = vim.env.GMR_RANGE
  if asked or not range then
    return
  end
  asked = true
  local base, head = range:match("^(.-)%.%.(.*)$")
  local script = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/leftover.mjs"
  pcall(vim.system, { "node", script, base, head }, { text = true }, function(res)
    vim.schedule(function()
      for side, path, line in (res.stdout or ""):gmatch("(%l+)\t([^\t\n]+)\t(%d+)") do
        moved[side][path] = moved[side][path] or {}
        moved[side][path][tonumber(line)] = true
      end
      kept = {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[b].otis_diffmarks and vim.api.nvim_buf_is_loaded(b) then
          M.redraw(b)
        end
      end
    end)
  end)
end

local function repo_path(name)
  local top = vim.system({ "git", "-C", vim.fs.dirname(name), "rev-parse", "--show-toplevel" }, { text = true }):wait().stdout:gsub("%s+$", "")
  local real = vim.fn.resolve(name)
  return real:sub(1, #top + 1) == top .. "/" and real:sub(#top + 2) or real
end

local function read(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local was = kept[buf]
  if was and was.tick == tick then
    return was
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local ref = vim.env.NVIM_DIFF_BASE or "HEAD"
  local base = vim.system({ "git", "-C", vim.fs.dirname(name), "show", ref .. ":./" .. vim.fs.basename(name) }, { text = true }):wait()
  local before = base.code == 0 and base.stdout or ""
  local now = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
  local path = repo_path(name)
  local new_moved, old_moved = moved.new[path] or {}, moved.old[path] or {}
  local hunks = {}
  for _, h in ipairs((vim.text and vim.text.diff or vim.diff)(before, now, { result_type = "indices" })) do
    local one = { first = h[3], count = h[4], base_first = h[1], base_count = h[2], lines = {} }
    -- A hunk is moved when nothing in it is new. A blank line goes with the moved line above it.
    local all = true
    for i = one.first, one.first + one.count - 1 do
      local blank = (vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""):match("^%s*$") ~= nil
      one.lines[i] = new_moved[i] or (blank and one.lines[i - 1]) or false
      all = all and (one.lines[i] or blank)
    end
    for i = one.base_first, one.base_first + one.base_count - 1 do
      all = all and old_moved[i] == true
    end
    one.moved = all
    table.insert(hunks, one)
  end
  kept[buf] = { tick = tick, hunks = hunks, base = vim.split(before, "\n", { plain = true }) }
  return kept[buf]
end

-- Runs of lines to go to: a hunk's new lines here, those it only moved left out; or for lines only taken out, the line
-- they were under. A hunk with nothing new is one run, marked moved, for what wants to pass it.
function M.hunks(buf)
  local out = {}
  for _, h in ipairs(read(buf).hunks) do
    local first = math.max(h.first, 1)
    local function run(a, b, count, base_count, was_moved)
      table.insert(out, { a, b, h.base_first, h.base_first + h.base_count - 1, moved = was_moved, count = count, base_count = base_count })
    end
    local from, base_left, found = nil, h.base_count, false
    local function close(last)
      if from then
        run(from, last, last - from + 1, base_left, false)
        from, base_left, found = nil, 0, true
      end
    end
    if not h.moved then
      for i = h.first, h.first + h.count - 1 do
        if h.lines[i] then
          close(i - 1)
        else
          from = from or i
        end
      end
      close(h.first + h.count - 1)
    end
    if not found then
      run(first, math.max(h.first + h.count - 1, first), h.count, h.base_count, h.moved)
    end
  end
  return out
end

-- middle(a, b): the bytes of a and of b that differ, between what they start and end with in common, or nil when
-- nothing is in common and marking the words would only say the whole line again.
local function middle(a, b)
  local s = 0
  while s < #a and s < #b and a:byte(s + 1) == b:byte(s + 1) do
    s = s + 1
  end
  local e = 0
  while e < #a - s and e < #b - s and a:byte(#a - e) == b:byte(#b - e) do
    e = e + 1
  end
  if s + e == 0 then
    return nil
  end
  return s, #a - e, #b - e
end

local function in_a_diff(buf)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.wo[w].diff then
      return true
    end
  end
  return false
end

local function draw_new(buf, r)
  vim.api.nvim_buf_clear_namespace(buf, lines_ns, 0, -1)
  for _, h in ipairs(r.hunks) do
    for i = h.first, h.first + h.count - 1 do
      if h.lines[i] then
        vim.api.nvim_buf_set_extmark(buf, lines_ns, i - 1, 0, { sign_text = "⇄", sign_hl_group = "OtisDiffMoved", priority = 5 })
      else
        vim.api.nvim_buf_set_extmark(buf, lines_ns, i - 1, 0, { line_hl_group = "OtisDiffNew", priority = 5 })
      end
    end
    if h.count == h.base_count then
      for n = 0, h.count - 1 do
        local now = vim.api.nvim_buf_get_lines(buf, h.first + n - 1, h.first + n, false)[1] or ""
        local s, _, e = middle(r.base[h.base_first + n] or "", now)
        if s and e > s and not h.lines[h.first + n] then
          vim.api.nvim_buf_set_extmark(buf, lines_ns, h.first + n - 1, s, { end_col = e, hl_group = "OtisDiffNewWord", priority = 5 })
        end
      end
    end
  end
end

-- whole(buf, r, h, width): the lines a hunk took out, each on the diff's red to the window's edge, and the words it
-- changed brighter. The tabs as the buffer shows them, since a virtual line draws one as a single cell.
local function whole(buf, r, h, width)
  local tab = (" "):rep(vim.bo[buf].tabstop)
  local out = {}
  for n = 0, h.base_count - 1 do
    local was = r.base[h.base_first + n] or ""
    local chunks = {}
    local s, e
    if h.count == h.base_count then
      local now = vim.api.nvim_buf_get_lines(buf, h.first + n - 1, h.first + n, false)[1] or ""
      s, e = middle(was, now)
    end
    local function part(from, to, group)
      if to > from then
        table.insert(chunks, { was:sub(from + 1, to):gsub("\t", tab), group })
      end
    end
    if s and e > s then
      part(0, s, "OtisDiffOld")
      part(s, e, "OtisDiffOldWord")
      part(e, #was, "OtisDiffOld")
    else
      part(0, #was, "OtisDiffOld")
    end
    local shown = vim.fn.strdisplaywidth(was:gsub("\t", tab), 0)
    table.insert(chunks, { (" "):rep(math.max(width - shown, 0)), "OtisDiffOld" })
    table.insert(out, chunks)
  end
  return out
end

-- The hunk the cursor is on: on its lines, or for lines only taken out, on the line under them.
local function hunk_at(r, line)
  for i, h in ipairs(r.hunks) do
    local last = h.first + h.count - 1
    if h.count > 0 and line >= h.first and line <= last or h.count == 0 and (line == h.first or line == h.first + 1) then
      return i
    end
  end
end

local function draw_old(buf, r, at)
  vim.api.nvim_buf_clear_namespace(buf, old_ns, 0, -1)
  local win = vim.fn.win_findbuf(buf)[1]
  local width, height = win and vim.api.nvim_win_get_width(win) or 80, win and vim.api.nvim_win_get_height(win) or 40
  for i, h in ipairs(r.hunks) do
    if h.base_count > 0 then
      local plural = h.base_count == 1 and "" or "s"
      local virt
      if h.moved then
        virt = { { { ("− %d line%s moved"):format(h.base_count, plural), "OtisDiffGone" } } }
      elseif i ~= at then
        virt = { { { ("− %d line%s"):format(h.base_count, plural), "OtisDiffGone" } } }
      elseif h.base_count > height - 4 then
        -- A virtual line cannot scroll: more than the window would never be seen whole.
        virt = { { { ("− %d lines, more than fits here: <leader>mb puts the file beside its base"):format(h.base_count), "OtisDiffGone" } } }
      else
        virt = whole(buf, r, h, width)
      end
      -- Above the first line of what replaced them, or under the line they were after.
      local row, above = h.first - 1, true
      if h.count == 0 and h.first > 0 then
        row, above = h.first - 1, false
      elseif h.first == 0 then
        row, above = 0, true
      end
      if row < vim.api.nvim_buf_line_count(buf) then
        vim.api.nvim_buf_set_extmark(buf, old_ns, row, 0, { virt_lines = virt, virt_lines_above = above })
      end
    end
  end
end

colors()
-- A colorscheme's :hi clear takes them.
vim.api.nvim_create_autocmd("ColorScheme", { callback = colors })

function M.redraw(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if in_a_diff(buf) then
    vim.api.nvim_buf_clear_namespace(buf, lines_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, old_ns, 0, -1)
    return
  end
  local r = read(buf)
  draw_new(buf, r)
  local win = vim.fn.win_findbuf(buf)[1]
  r.at = win and hunk_at(r, vim.api.nvim_win_get_cursor(win)[1]) or nil
  draw_old(buf, r, r.at)
end

function M.attach(buf)
  if vim.b[buf].otis_diffmarks or vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then
    return
  end
  vim.b[buf].otis_diffmarks = true
  ask_moved()
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWritePost" }, {
    buffer = buf,
    callback = function()
      M.redraw(buf)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local r = kept[buf]
      if not r or in_a_diff(buf) then
        return
      end
      local at = hunk_at(r, vim.fn.line("."))
      if at ~= r.at then
        r.at = at
        draw_old(buf, r, at)
      end
    end,
  })
  M.redraw(buf)
end

return M
