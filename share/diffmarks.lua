-- diffmarks.lua: what a change did, drawn on the real file in the frame's nvim: new lines on the diff's green, the words
-- a line changed brighter, and what was taken out on red where it was, wrapped as the window wraps its own lines.
--   attach(buf)  draw on a file's buffer, and keep it drawn as it is edited and its window resized; a window in a diff
--                shows all this itself
--   hunks(buf)   its changes in order: { first, last, base_first, base_last, count = new lines, base_count = old lines }
local M = {}
local ns = vim.api.nvim_create_namespace("otis_diffmarks")
local kept = {} -- buf -> { tick, hunks, base }: a file is diffed once per edit, not on every key
local drawn_for = {} -- buf -> the view(buf) it was last drawn for

local function colors()
  local function bg(env, group)
    local own = vim.env[env]
    if own and own:match("^#") then
      return own
    end
    local had = vim.api.nvim_get_hl(0, { name = group, link = false }).bg
    return had and ("#%06x"):format(had) or nil
  end
  vim.api.nvim_set_hl(0, "OtisDiffNew", { bg = bg("OTIS_T_PLUS", "DiffAdd") })
  vim.api.nvim_set_hl(0, "OtisDiffNewWord", { bg = bg("OTIS_T_PLUS_WORD", "DiffText") })
  vim.api.nvim_set_hl(0, "OtisDiffNewCursor", { bg = bg("OTIS_T_PLUS_EMPH", "CursorLine") })
  vim.api.nvim_set_hl(0, "OtisDiffOld", { bg = bg("OTIS_T_MINUS", "DiffDelete") })
  vim.api.nvim_set_hl(0, "OtisDiffOldWord", { bg = bg("OTIS_T_MINUS_WORD", "DiffDelete") })
  vim.api.nvim_set_hl(0, "OtisDiffTooLong", { fg = vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg, italic = true })
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
  local hunks = {}
  for _, h in ipairs((vim.text and vim.text.diff or vim.diff)(before, now, { result_type = "indices" })) do
    table.insert(hunks, { first = h[3], count = h[4], base_first = h[1], base_count = h[2] })
  end
  kept[buf] = { tick = tick, hunks = hunks, base = vim.split(before, "\n", { plain = true }) }
  return kept[buf]
end

-- Lines only taken out are a run on the line they were under.
function M.hunks(buf)
  local out = {}
  for _, h in ipairs(read(buf).hunks) do
    local first = math.max(h.first, 1)
    table.insert(out, { first, math.max(h.first + h.count - 1, first), h.base_first, h.base_first + h.base_count - 1, count = h.count, base_count = h.base_count })
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

-- view(buf): what a drawing depends on in the window showing buf, or nil in a diff: how tall it is, and how it wraps a
-- line (width nil where it does not).
local function view(buf)
  if in_a_diff(buf) then
    return nil
  end
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return { height = 40, breakat = "" }
  end
  local wo = vim.wo[win]
  return {
    height = vim.api.nvim_win_get_height(win),
    width = wo.wrap and vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff or nil,
    breakat = wo.linebreak and vim.o.breakat or "",
    breakindent = wo.breakindent,
  }
end

-- wrap(text, v): the rows the window v describes shows text in, as { from, to, indent }: its bytes from and to, after
-- indent columns. As nvim wraps a line, which a virtual line never is: after the last run of 'breakat' on a row, or
-- where it fills, and with 'breakindent' the rows after the first as indented as the line, keeping 20 columns.
local function wrap(text, v)
  local width = v.width or math.huge
  local indent = v.breakindent and math.max(math.min(vim.api.nvim_strwidth(text:match("^%s*")), width - 20), 0) or 0
  local rows, from, used, cut, after_break = {}, 0, 0, nil, false
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i + vim.str_utf_end(text, i))
    local w, breaks = vim.api.nvim_strwidth(ch), v.breakat:find(ch, 1, true) ~= nil
    if after_break and not breaks then
      cut = i - 1
    end
    if used + w > width and i - 1 > from then
      local at = cut or i - 1
      table.insert(rows, { from, at, #rows > 0 and indent or 0 })
      from, cut = at, nil
      used = indent + vim.api.nvim_strwidth(text:sub(from + 1, i - 1))
    end
    used, after_break, i = used + w, breaks, i + #ch
  end
  table.insert(rows, { from, #text, #rows > 0 and indent or 0 })
  return rows
end

local function draw_new(buf, r, h)
  for i = h.first, h.first + h.count - 1 do
    -- A range to the window's edge, under the cursor's line and the words below: nvim paints a line_hl_group over them.
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_row = i, hl_group = "OtisDiffNew", hl_eol = true, priority = 3, strict = false })
  end
  if h.count == h.base_count then
    for n = 0, h.count - 1 do
      local now = vim.api.nvim_buf_get_lines(buf, h.first + n - 1, h.first + n, false)[1] or ""
      local s, _, e = middle(r.base[h.base_first + n] or "", now)
      if s and e > s then
        vim.api.nvim_buf_set_extmark(buf, ns, h.first + n - 1, s, { end_col = e, hl_group = "OtisDiffNewWord", priority = 5 })
      end
    end
  end
end

-- old_lines(buf, r, h, v): the rows of what a hunk took out, each on the diff's red to the window's edge, the words it
-- changed brighter. The tabs as the buffer shows them, since a virtual line draws one as a single cell.
local function old_lines(buf, r, h, v)
  local tab = (" "):rep(vim.bo[buf].tabstop)
  local out = {}
  for n = 0, h.base_count - 1 do
    local was = (r.base[h.base_first + n] or ""):gsub("\t", tab)
    local s, e
    if h.count == h.base_count then
      s, e = middle(was, ((vim.api.nvim_buf_get_lines(buf, h.first + n - 1, h.first + n, false)[1] or ""):gsub("\t", tab)))
    end
    for _, row in ipairs(wrap(was, v)) do
      local chunks = { { (" "):rep(row[3]), "OtisDiffOld" } }
      local function part(from, to, group)
        from, to = math.max(from, row[1]), math.min(to, row[2])
        if to > from then
          table.insert(chunks, { was:sub(from + 1, to), group })
        end
      end
      if s and e > s then
        part(0, s, "OtisDiffOld")
        part(s, e, "OtisDiffOldWord")
        part(e, #was, "OtisDiffOld")
      else
        part(0, #was, "OtisDiffOld")
      end
      table.insert(chunks, { (" "):rep(vim.o.columns), "OtisDiffOld" })
      table.insert(out, chunks)
    end
  end
  return out
end

local function draw_old(buf, r, h, v)
  -- A virtual line cannot scroll: more than the window would never be seen whole.
  local fits = v.height - 4
  local virt = h.base_count <= fits and old_lines(buf, r, h, v) or nil
  if not virt or #virt > fits then
    virt = { { { ("− %d lines, more than fits here: <leader>mb puts the file beside its base"):format(h.base_count), "OtisDiffTooLong" } } }
  end
  -- Above the first line of what replaced them, or under the line they were after.
  local row, above = math.max(h.first - 1, 0), h.count > 0 or h.first == 0
  if row < vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = virt, virt_lines_above = above })
  end
end

local function draw(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local v = view(buf)
  drawn_for[buf] = v
  if not v then
    return
  end
  local r = read(buf)
  for _, h in ipairs(r.hunks) do
    draw_new(buf, r, h)
    if h.base_count > 0 then
      draw_old(buf, r, h, v)
    end
  end
end

colors()
-- A colorscheme's :hi clear takes them.
vim.api.nvim_create_autocmd("ColorScheme", { callback = colors })

function M.attach(buf)
  if vim.b[buf].otis_diffmarks or vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then
    return
  end
  vim.b[buf].otis_diffmarks = true
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWritePost" }, {
    buffer = buf,
    callback = function()
      draw(buf)
    end,
  })
  draw(buf)
end

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, win, buf)
    if not vim.b[buf].otis_diffmarks then
      return false
    end
    -- A window going into or out of a diff (<leader>mb, your own), where virtual lines would push the two sides apart,
    -- or resized, where the old lines wrap again: no autocommand says so for :diffthis or :diffoff, so a redraw notices.
    local now = view(buf)
    if not vim.deep_equal(drawn_for[buf], now) then
      drawn_for[buf] = now
      vim.schedule(function()
        draw(buf)
      end)
    end
    -- 'cursorline' draws under everything, so on a new line its bar is the new lines' own, lit.
    if vim.wo[win].cursorline then
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, 0 }, { details = true })) do
        if m[4].hl_group == "OtisDiffNew" then
          vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_row = row + 1, hl_group = "OtisDiffNewCursor", hl_eol = true, priority = 4, ephemeral = true, strict = false })
        end
      end
    end
    return false
  end,
})

return M
