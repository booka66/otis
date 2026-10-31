-- diffmarks.lua: what a change did, drawn on the real file in the frame's nvim: new lines on the diff's green, the words
-- a line changed brighter, and what was taken out on red where it was.
--   attach(buf)  draw on a file's buffer, and keep it drawn as it is edited; a window in a diff shows all this itself
--   hunks(buf)   its changes in order: { first, last, base_first, base_last, count = new lines, base_count = old lines }
local M = {}
local ns = vim.api.nvim_create_namespace("otis_diffmarks")
local kept = {} -- buf -> { tick, hunks, base }: a file is diffed once per edit, not on every key
local drawn_in_diff = {} -- buf -> whether it was in a diff when last drawn

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

local function draw_new(buf, r, h)
  for i = h.first, h.first + h.count - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = "OtisDiffNew", priority = 5 })
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

-- old_lines(buf, r, h): what a hunk took out, each on the diff's red to the window's edge, the words it changed
-- brighter. The tabs as the buffer shows them, since a virtual line draws one as a single cell.
local function old_lines(buf, r, h)
  local tab = (" "):rep(vim.bo[buf].tabstop)
  local out = {}
  for n = 0, h.base_count - 1 do
    local was = r.base[h.base_first + n] or ""
    local chunks = {}
    local s, e
    if h.count == h.base_count then
      s, e = middle(was, vim.api.nvim_buf_get_lines(buf, h.first + n - 1, h.first + n, false)[1] or "")
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
    table.insert(chunks, { (" "):rep(vim.o.columns), "OtisDiffOld" })
    table.insert(out, chunks)
  end
  return out
end

local function draw_old(buf, r, h, height)
  -- A virtual line cannot scroll: more than the window would never be seen whole.
  local virt = h.base_count > height - 4 and { { { ("− %d lines, more than fits here: <leader>mb puts the file beside its base"):format(h.base_count), "OtisDiffTooLong" } } } or old_lines(buf, r, h)
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
  drawn_in_diff[buf] = in_a_diff(buf)
  if drawn_in_diff[buf] then
    return
  end
  local win = vim.fn.win_findbuf(buf)[1]
  local height = win and vim.api.nvim_win_get_height(win) or 40
  local r = read(buf)
  for _, h in ipairs(r.hunks) do
    draw_new(buf, r, h)
    if h.base_count > 0 then
      draw_old(buf, r, h, height)
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

-- A window going into or out of a diff (<leader>mb, your own), where virtual lines would push the two sides apart: no
-- autocommand says so for :diffthis or :diffoff, so its next redraw notices.
vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf)
    if vim.b[buf].otis_diffmarks and drawn_in_diff[buf] ~= in_a_diff(buf) then
      drawn_in_diff[buf] = in_a_diff(buf)
      vim.schedule(function()
        draw(buf)
      end)
    end
    return false
  end,
})

return M
