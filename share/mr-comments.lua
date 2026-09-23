-- Loaded by git-commit-open when gmr's review picker opens a file: the MR's line
-- comments show under the lines they are on, and you can add, reply to and
-- resolve them without gitlab.nvim. Everything goes through glab api from the
-- review worktree, which is on the MR's head.
--
--   <leader>mc   comment on this line, or open its thread to read and reply
--                (picking one when several start there); in visual mode, a
--                new thread on the selected lines, even on one that has one
--   <leader>mr   resolve or unresolve the thread on this line
--   <leader>me   edit your comment: in a thread, the one under the cursor;
--                on a line, your latest in its thread
--   <leader>md   delete your comment, picked the same way, after a confirm
--   <leader>mo   the threads on no line: this file's outdated ones and
--                comments on the whole file first, then the MR's
--   <leader>ml   every thread in the MR, in the quickfix list
--   <leader>mu   refetch the threads, for comments made elsewhere
--   <leader>mt   new comments and replies as drafts, or sent at once
--   <leader>ms   submit your drafts: publish them all, and approve if you like
--   ]r  [r       the next or previous file in the MR, at its first change
--
-- Reviewing, new comments and replies are drafts, shown as ✎ until you submit
-- them, so the MR's people hear once, not once per comment; on your own MR
-- they are sent at once. The compose window's title says which. Edits,
-- deletes and resolving always happen at once.
--
-- Comments on the right (the MR's file) land on the new side of the diff; from
-- the left (gitsigns' base buffer, open by default) on the old side, which is
-- the only way to comment on a removed line. A thread shows on its line only
-- while the file is the one it was written on; one on lines a push has changed
-- since is outdated, and waits under <leader>mo (git-mr-threads says how that
-- is decided). Threads refresh after each change.
local iid = vim.env.GMR_IID
if not iid or iid == "" then
  return
end

local mr = "projects/:fullpath/merge_requests/" .. iid
local share = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local ns = vim.api.nvim_create_namespace("gmr_comments")
local root = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })[1]
local range = vim.env.GMR_RANGE
local base = vim.env.NVIM_DIFF_BASE
local reviewing = vim.env.GMR_KIND == "review"
local drafting = reviewing -- whether new comments and replies are drafts
local threads = {} -- every thread and draft, placed in the diff of range (git-mr-threads)
local me -- your GitLab username; only your own comments can be edited or deleted

local function notify(msg, level)
  vim.notify("!" .. iid .. ": " .. msg, level or vim.log.levels.INFO)
end

local glab_missing_said = false
local function have_glab()
  if vim.fn.executable("glab") == 1 then
    return true
  end
  if not glab_missing_said then
    glab_missing_said = true
    notify("comments need glab (otis-setup says how to get it)", vim.log.levels.WARN)
  end
end

-- glab api with an optional JSON body; on_done gets the decoded response.
local function glab(method, path, body, on_done)
  if not have_glab() then
    return
  end
  local cmd = { "glab", "api", "-X", method, path }
  if body then
    vim.list_extend(cmd, { "-H", "Content-Type: application/json", "--input", "-" })
  end
  vim.system(cmd, { cwd = root, text = true, stdin = body and vim.json.encode(body) }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      local err = vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
      -- The compose window is gone by now; what was written must not be.
      local text = body and (body.body or body.note)
      if text then
        vim.fn.setreg('"', text)
        err = err .. "\nyour text is in the \" register"
      end
      notify(method .. " failed: " .. err, vim.log.levels.ERROR)
      return
    end
    if on_done then
      on_done(res.stdout ~= "" and vim.json.decode(res.stdout, { luanil = { object = true } }) or nil)
    end
  end))
end

-- Which file and side a buffer is: the working file is the new side, and the
-- base revision the old, either gitsigns' buffer of it
-- (gitsigns://<gitdir>//<rev>:<path>) or the one ]r opens (gmr-base://<path>).
local function buf_target(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local rel = name:match("^gitsigns://.-//[^:]+:(.+)$") or name:match("^gmr%-base://(.+)$")
  if rel then
    return rel, "old"
  end
  if vim.bo[buf].buftype == "" and vim.startswith(name, root .. "/") then
    return name:sub(#root + 2), "new"
  end
end

local function mine(n)
  return n.draft or n.author.username == me
end

-- Comment bodies as markdown, the way the file picker's preview shows them:
-- share/markdown.awk renders them, and in its nvim mode gives each line as
-- runs of highlight group and text, the group's name saying what to define it
-- as (GmrMd_<fg>_<bg>_<b><i><u>). Rendered once per body and width, all a
-- buffer needs in one awk.
local markdown_awk -- the renderer's source, read on first use
local rendered = {} -- width .. "\0" .. body: a list of lines, each a list of virt_text chunks
local hl_made = {}

-- The terminal theme's colors (a<n>, the terminal's color n) as the groups
-- your colorscheme gives those hues, so they follow nvim's colors as they
-- follow the terminal's elsewhere.
local ansi_groups = { [0] = "Normal", "DiagnosticError", "DiagnosticOk", "DiagnosticWarn", "Function", "Special",
  "DiagnosticInfo", "Normal", "Comment" }
local function md_color(c, key)
  if c == "x" then return nil end
  local n = c:match("^a(%d+)$")
  if not n then return "#" .. c end
  n = tonumber(n)
  local group = ansi_groups[n] or ansi_groups[n - 8] or "Normal"
  return vim.api.nvim_get_hl(0, { name = group, link = false })[key]
end

local function md_hl(name)
  if not hl_made[name] then
    local fg, bg, attrs = name:match("^GmrMd_(%w+)_(%w+)_(%a*)$")
    vim.api.nvim_set_hl(0, name, { fg = md_color(fg, "fg"), bg = md_color(bg, "fg"),
      bold = attrs:find("b") ~= nil, italic = attrs:find("i") ~= nil, underline = attrs:find("u") ~= nil })
    hl_made[name] = true
  end
  return name
end

local function render_markdown(bodies, width)
  local todo, input = {}, {}
  for _, body in ipairs(bodies) do
    local key = width .. "\0" .. body
    if not rendered[key] and not todo[key] then
      todo[key] = #input + 1
      table.insert(input, ("%d\t%s"):format(#input + 1, (body:gsub("\t", " "):gsub("\r?\n", "\31"))))
    end
  end
  if #input == 0 then
    return
  end
  markdown_awk = markdown_awk or table.concat(vim.fn.readfile(share .. "/markdown.awk"), "\n")
  local res = vim.system({ "awk", "-F", "\t", "-v", "md_nvim=1", markdown_awk .. ('\n{ md($2, %d, $1 "\\t") }'):format(width) },
    { stdin = table.concat(input, "\n") .. "\n", env = { LC_ALL = "C" }, text = true }):wait()
  local out = {}
  for _, l in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
    local n, rest = l:match("^(%d+)\t(.*)$")
    if n then
      local chunks, runs = {}, vim.split(rest, "\30")
      for i = 1, #runs - 1, 2 do
        table.insert(chunks, { runs[i + 1], md_hl(runs[i]) })
      end
      out[tonumber(n)] = out[tonumber(n)] or {}
      table.insert(out[tonumber(n)], chunks)
    end
  end
  for key, n in pairs(todo) do
    rendered[key] = out[n] or {}
  end
end

local function markdown_lines(body, width)
  return rendered[width .. "\0" .. body] or {}
end

local function render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local path, side = buf_target(buf)
  if not path then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(buf)
  local win = vim.fn.bufwinid(buf)
  local width = win == -1 and 80 or math.max(30, vim.fn.getwininfo(win)[1].width - vim.fn.getwininfo(win)[1].textoff - 6)
  local bodies, whys = {}, {}
  for _, t in ipairs(threads) do
    if t.where.path == path and t.where.state == "line" then
      table.insert(bodies, t.notes[1].body)
      table.insert(whys, t.notes[1].why and t.notes[1].why:match("^(.-)\n## ") or t.notes[1].why)
    end
  end
  render_markdown(bodies, width)
  render_markdown(whys, width - 2)
  -- Threads on no line of this file are counted on its first line: on the MR's
  -- side, or the base's for a file the MR deletes.
  local others = 0
  local others_side = vim.fn.filereadable(root .. "/" .. path) == 1 and "new" or "old"
  for _, t in ipairs(threads) do
    local w, first = t.where, t.notes[1]
    if w.path == path and w.state ~= "line" and side == others_side then
      others = others + 1
    elseif w.path == path and w.state == "line" and w.side == side and w.line <= count then
      local hl = t.draft and "DiagnosticWarn" or t.resolved and "Comment" or "DiagnosticInfo"
      for l = w.from, w.line - 1 do
        vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { sign_text = "│", sign_hl_group = hl })
      end
      local drafts = #vim.tbl_filter(function(n)
        return n.draft
      end, t.notes)
      local replies = t.draft and 0 or #t.notes - 1 - drafts
      local head = ("  %s %s%s%s%s"):format(t.draft and "✎" or t.resolved and "✓" or "",
        t.draft and (t.claude and first.author.username .. "'s draft" or "your draft") or first.author.username,
        w.from < w.line and ("  lines " .. w.from .. "-" .. w.line) or "",
        replies > 0 and ("  +" .. replies .. " repl" .. (replies == 1 and "y" or "ies")) or "",
        not t.draft and drafts > 0 and ("  ✎ " .. drafts .. " draft repl" .. (drafts == 1 and "y" or "ies")) or "")
      local virt = { { { head, hl } } }
      -- The whole comment, as the preview shows it; a resolved one, its first line.
      local body = t.resolved and vim.tbl_filter(function(chunks)
        return vim.iter(chunks):any(function(c)
          return c[1]:match("%S")
        end)
      end, markdown_lines(first.body, width)) or markdown_lines(first.body, width)
      local shown = t.resolved and 1 or #body
      for i = 1, math.min(#body, shown) do
        local line = { { "    ", "Normal" } }
        for _, c in ipairs(body[i]) do
          table.insert(line, { c[1], t.resolved and "Comment" or c[2] })
        end
        table.insert(virt, line)
      end
      if #body > shown then
        table.insert(virt, { { "    …", "Comment" } })
      end
      -- Why Claude wrote it (git-mr-claude): for you, never part of the draft.
      -- Here the reasons and the concept's name; the lesson, too long to sit in
      -- the code, opens beside the draft with <leader>mc.
      if first.why and first.why ~= "" then
        local reasons, concept = first.why:match("^(.-)\n## ([^\n]*)")
        table.insert(virt, { { "    ┆ why · for you only, never posted", "Comment" } })
        for _, chunks in ipairs(markdown_lines(reasons or first.why, width - 2)) do
          table.insert(virt, vim.list_extend({ { "    ┆ ", "Comment" } }, chunks))
        end
        if concept then
          table.insert(virt, { { "    ┆ learn: ", "Comment" }, { concept, "DiagnosticWarn" }, { "  · <leader>mc for the lesson", "Comment" } })
        end
      end
      vim.api.nvim_buf_set_extmark(buf, ns, w.line - 1, 0,
        { virt_lines = virt, sign_text = t.draft and "✎" or "", sign_hl_group = hl })
    end
  end
  if others > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_text = { { ("   %d more thread%s on this file, outdated or on the whole file · <leader>mo"):format(others,
        others == 1 and "" or "s"), "Comment" } },
    })
  end
end

local function render_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    render(buf)
  end
end

local function refresh(on_done)
  if not have_glab() then
    return
  end
  vim.system({ "git-mr-threads", "--fetch", iid, range }, { cwd = root, text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      notify("could not load the threads: " .. vim.trim(res.stderr), vim.log.levels.ERROR)
      return
    end
    threads = vim.json.decode(res.stdout, { luanil = { object = true } })
    render_all()
    if on_done then
      on_done()
    end
  end))
end

-- What a thread is about, for titles and lists.
local function where_text(t)
  local w = t.where
  if w.state == "line" then
    return w.side == "old" and ("%s, removed line %d"):format(w.path, w.line) or ("%s:%d"):format(w.path, w.line)
  elseif w.state == "outdated" then
    return ("%s, outdated (was %sline %d)"):format(w.path, w.side == "old" and "removed " or "", w.line)
  end
  return w.state == "file" and w.path or "the MR"
end

local function label(t)
  local n = t.notes[1]
  return ("%s%s: %s"):format(t.draft and "✎ draft " or t.resolved and "✓ " or "",
    n.author.username, (n.body:gsub("\n", " ")):sub(1, 80))
end

-- Several threads can start on one line; with more than one, pick. on_pick
-- gets nil when there are none.
local function pick(list, on_pick)
  if #list <= 1 then
    return on_pick(list[1])
  end
  vim.ui.select(list, { prompt = "which thread?", format_item = label }, function(t)
    if t then
      on_pick(t)
    end
  end)
end

local function threads_at(buf, lnum)
  local path, side = buf_target(buf)
  return vim.tbl_filter(function(t)
    local w = t.where
    return w.state == "line" and w.path == path and w.side == side and w.line == lnum
  end, threads)
end

-- Where a comment goes in the MR's diff (git-mr-position, shared with the
-- pickers' comments and Claude's drafts).
local function position(refs, path, side, first, last)
  local out = vim.system({ "git-mr-position", refs.base_sha, refs.start_sha or "", refs.head_sha, path, side,
    tostring(first), tostring(last) }, { cwd = root, text = true }):wait()
  return vim.json.decode(out.stdout)
end

-- A new comment's position comes from this buffer's line numbers, worked out
-- against the committed diff at the MR's head (git-mr-position). So the
-- buffer has to be that very file: no unsaved edits, nothing uncommitted (your
-- own checkout), and this checkout at the head GitLab has now, asked for again
-- right before sending, since a push or a commit can land while you type.
-- Returns the MR's diff_refs, or nil and why not. Without check_head, only the
-- local part.
local function comment_refs(buf, path, side, check_head)
  if side == "new" then
    if vim.bo[buf].modified then
      return nil, "this buffer has unsaved edits, so its line numbers are not the MR's; save or undo them to comment"
    end
    if vim.system({ "git", "diff", "--quiet", "HEAD", "--", path }, { cwd = root }):wait().code ~= 0 then
      return nil, path .. " has changes that are not committed, so its line numbers are not the MR's"
    end
  end
  if not check_head then
    return true
  end
  if not have_glab() then
    return nil, "comments need glab"
  end
  local res = vim.system({ "glab", "api", mr }, { cwd = root, text = true }):wait()
  if res.code ~= 0 then
    return nil, "could not ask GitLab for the MR's head: " .. vim.trim(res.stderr)
  end
  local refs = vim.json.decode(res.stdout, { luanil = { object = true } }).diff_refs
  local head = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "HEAD" })[1]
  if refs.head_sha ~= head then
    return nil, ("this checkout is not at the MR's head (%s), so its line numbers are not the MR's"):format(refs.head_sha:sub(1, 8))
  end
  if side == "old" and vim.fn.systemlist({ "git", "-C", root, "rev-parse", base })[1] ~= refs.base_sha then
    return nil, ("the left pane is not the MR's base (%s)"):format(refs.base_sha:sub(1, 8))
  end
  return refs
end

-- A markdown float; :w hands its text (from below `marker`, when given) to
-- on_send, and closes it unless on_send returns false. `verb` says what :w
-- does. Returns the float's buffer and window, for callers adding their own keys.
local function compose(title, lines, marker, verb, on_send, hint)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "gmr://" .. iid .. "/" .. vim.uv.hrtime())
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  local width = math.min(100, vim.o.columns - 6)
  local height = math.min(math.max(#lines + 4, 8), vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, border = "rounded", title = " " .. title .. " ", title_pos = "center",
    footer = " :w " .. verb .. " · q closes" .. (hint and " · " .. hint or "") .. " ", footer_pos = "center",
  })
  vim.wo[win].wrap = true
  -- Markdown shows as it will read, markers hidden but on the cursor's line.
  vim.wo[win].conceallevel = 2
  pcall(vim.treesitter.start, buf, "markdown")
  -- A comment isn't a markdown file; linters attached by filetype only nag.
  vim.diagnostic.enable(false, { bufnr = buf })
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local from = 1
      for i, l in ipairs(all) do
        if l == marker then
          from = i + 1
        end
      end
      local text = vim.trim(table.concat(all, "\n", from))
      if text == "" then
        notify("nothing to send", vim.log.levels.WARN)
        return
      end
      if on_send(text) == false then
        return
      end
      vim.bo[buf].modified = false
      -- Later, so a :wq closes the float itself rather than a pane behind it.
      vim.schedule(function()
        pcall(vim.api.nvim_win_close, win, true)
      end)
    end,
  })
  if #lines == 1 and lines[1] == "" then
    vim.cmd("startinsert")
  end
  return buf, win
end

local function done(msg)
  return function()
    refresh(function()
      notify(msg)
    end)
  end
end

-- Your latest comment in a thread.
local function latest_mine(t)
  for i = #t.notes, 1, -1 do
    if mine(t.notes[i]) then
      return t.notes[i]
    end
  end
end

-- Why the agent wrote a draft, and its lesson, in a read-only float above its
-- compose window win: a buffer of its own, so :w there can never send it.
-- <C-w>w goes into it to scroll a long lesson. Closes with win.
local function show_why(win, why, who)
  local cfg = vim.api.nvim_win_get_config(win)
  local lines = vim.split(why, "\n")
  local rows = 0
  for _, l in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / cfg.width))
  end
  local height = math.min(rows, math.max(3, cfg.row - 2))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.keymap.set("n", "q", "<C-w>p", { buffer = buf })
  local fwin = vim.api.nvim_open_win(buf, false, {
    relative = "editor", anchor = "SW", row = cfg.row, col = cfg.col, width = cfg.width, height = height,
    border = "rounded", style = "minimal", zindex = 60,
    title = (" why %s wrote it · for you only, never posted "):format(who), title_pos = "center",
    footer = " <C-w>w scrolls it ", footer_pos = "center",
  })
  vim.wo[fwin].wrap = true
  vim.wo[fwin].conceallevel = 2
  pcall(vim.treesitter.start, buf, "markdown")
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, fwin, true)
    end,
  })
end

local function edit_note(t, n)
  local _, win = compose(n.draft and "edit draft" or "edit comment", vim.split(n.body, "\n"), nil, "saves", function(text)
    if n.draft then
      glab("PUT", mr .. "/draft_notes/" .. n.id, { note = text }, done("draft edited"))
    else
      glab("PUT", mr .. "/discussions/" .. t.id .. "/notes/" .. n.id, { body = text }, done("edited"))
    end
  end)
  if n.why and n.why ~= "" then
    show_why(win, n.why, n.author.username)
  end
end

local function delete_note(t, n)
  local preview = (n.body:gsub("\n", " ")):sub(1, 60)
  if vim.fn.confirm(("Delete your %s \"%s\"?"):format(n.draft and "draft" or "comment", preview), "&Delete\n&Cancel", 2) ~= 1 then
    return
  end
  if n.draft then
    glab("DELETE", mr .. "/draft_notes/" .. n.id, nil, done("draft deleted"))
  else
    glab("DELETE", mr .. "/discussions/" .. t.id .. "/notes/" .. n.id, nil, done("deleted"))
  end
end

local function resolve(t)
  if t.draft or not t.resolvable then
    notify(t.draft and "a draft has nothing to resolve yet" or "a single comment cannot be resolved", vim.log.levels.WARN)
    return
  end
  glab("PUT", mr .. "/discussions/" .. t.id .. "?resolved=" .. tostring(not t.resolved), nil,
    done(t.resolved and "unresolved" or "resolved"))
end

-- A thread in a float, to read and reply, or edit and delete your comments. A
-- draft of a new thread has nothing to reply to, so it opens to edit.
local function open_thread(t)
  if t.draft then
    edit_note(t, t.notes[1])
    return
  end
  local marker = drafting and "── reply below, as a draft ──" or "── reply below, sent at once ──"
  local lines, owner = {}, {} -- owner[line] is the note that line belongs to
  for _, n in ipairs(t.notes) do
    table.insert(lines, n.draft and ("**%s** · ✎ draft"):format(n.author.username) or ("**%s** · %s"):format(n.author.username, n.created_at:sub(1, 10)))
    vim.list_extend(lines, vim.split(n.body, "\n"))
    for l = #owner + 1, #lines do
      owner[l] = n
    end
    table.insert(lines, "")
  end
  vim.list_extend(lines, { t.resolved and "(resolved)" or "", marker, "" })
  local fbuf, fwin = compose(where_text(t), lines, marker, drafting and "saves a draft" or "sends", function(text)
    if drafting then
      glab("POST", mr .. "/draft_notes", { note = text, in_reply_to_discussion_id = t.id },
        done("draft reply saved; <leader>ms submits your drafts"))
    else
      glab("POST", mr .. "/discussions/" .. t.id .. "/notes", { body = text }, done("replied"))
    end
  end, "<leader>me edits · <leader>md deletes" .. (t.resolvable and " · <leader>mr resolves" or ""))
  -- The comment under the cursor, or below the thread your latest one.
  local function own(action)
    return function()
      local n = owner[vim.fn.line(".")] or latest_mine(t)
      if not n or not mine(n) then
        notify(n and "that comment is not yours" or "none of these comments are yours", vim.log.levels.WARN)
        return
      end
      vim.api.nvim_win_close(fwin, true)
      action(t, n)
    end
  end
  vim.keymap.set("n", "<leader>me", own(edit_note), { buffer = fbuf, desc = "MR: edit this comment" })
  vim.keymap.set("n", "<leader>md", own(delete_note), { buffer = fbuf, desc = "MR: delete this comment" })
  vim.keymap.set("n", "<leader>mr", function()
    vim.api.nvim_win_close(fwin, true)
    resolve(t)
  end, { buffer = fbuf, desc = "MR: resolve or unresolve this thread" })
end

-- <leader>me and <leader>md on a line act on your latest comment in its thread.
local function on_own_note(action)
  pick(threads_at(vim.api.nvim_get_current_buf(), vim.fn.line(".")), function(t)
    local n = t and latest_mine(t)
    if not n then
      notify(t and "none of the comments on this line are yours" or "no thread on this line", vim.log.levels.WARN)
      return
    end
    action(t, n)
  end)
end

-- A new thread on lines first..last, or unless `new`, the thread on the line.
local function comment(first, last, new)
  local buf = vim.api.nvim_get_current_buf()
  local path, side = buf_target(buf)
  if not path then
    notify("not a file in the MR", vim.log.levels.WARN)
    return
  end
  local here = not new and threads_at(buf, last) or {}
  if #here > 0 then
    pick(here, open_thread)
    return
  end
  local ok, why = comment_refs(buf, path, side, false)
  if not ok then
    notify(why, vim.log.levels.WARN)
    return
  end
  local where = first == last and tostring(last) or (first .. "-" .. last)
  local title = ("%s · %s:%s"):format(drafting and "new draft" or "new comment, sent at once", path, where)
  compose(title, { "" }, nil, drafting and "saves a draft" or "sends", function(text)
    local refs, problem = comment_refs(buf, path, side, true)
    if not refs then
      notify(problem .. ". Your text is still in the window.", vim.log.levels.WARN)
      return false
    end
    local pos = position(refs, path, side, first, last)
    if drafting then
      glab("POST", mr .. "/draft_notes", { note = text, position = pos }, done("draft saved; <leader>ms submits your drafts"))
    else
      glab("POST", mr .. "/discussions", { body = text, position = pos }, done("commented"))
    end
  end)
end

local function toggle_resolved()
  pick(threads_at(vim.api.nvim_get_current_buf(), vim.fn.line(".")), function(t)
    if not t then
      notify("no thread on this line", vim.log.levels.WARN)
      return
    end
    resolve(t)
  end)
end

-- Threads on no line of the diff, this file's first.
local function others()
  local path = buf_target(vim.api.nvim_get_current_buf())
  local list = {}
  for _, here in ipairs({ true, false }) do
    for _, t in ipairs(threads) do
      if t.where.state ~= "line" and (t.where.path == path) == here then
        table.insert(list, t)
      end
    end
  end
  if #list == 0 then
    notify("every thread is on a line")
    return
  end
  vim.ui.select(list, {
    prompt = "threads on no line",
    format_item = function(t)
      return where_text(t) .. "  " .. label(t)
    end,
  }, function(t)
    if t then
      open_thread(t)
    end
  end)
end

local function list()
  local items = {}
  for _, t in ipairs(threads) do
    local w = t.where
    if w.path then
      table.insert(items, {
        filename = root .. "/" .. w.path,
        lnum = w.state == "line" and w.line or 1,
        text = (w.state == "outdated" and ("outdated, was line " .. w.line .. " · ") or w.state == "file" and "on the file · " or "")
          .. label(t),
      })
    end
  end
  vim.fn.setqflist({}, " ", { title = "!" .. iid .. " threads", items = items })
  vim.cmd("copen")
end

local function toggle_drafting()
  drafting = not drafting
  notify(drafting and "new comments and replies are drafts until <leader>ms submits them"
    or "new comments and replies are sent at once")
end

-- Publish every draft at once (git-mr-submit); reviewing, as a comment or with
-- an approval of the head you are reading.
local function submit()
  local n, claude, who = 0, 0, nil
  for _, t in ipairs(threads) do
    for _, note in ipairs(t.notes) do
      n = n + (note.draft and 1 or 0)
      claude = claude + (note.claude and 1 or 0)
      who = note.claude and note.author.username or who
    end
  end
  if n == 0 then
    notify("no drafts to submit")
    return
  end
  local question = ("Publish your %d draft%s%s?"):format(n, n == 1 and "" or "s",
    claude > 0 and (" (%d of them %s's)"):format(claude, who) or "")
  local answer
  if reviewing then
    answer = ({ "comment", "approve" })[vim.fn.confirm(question, "&Comment\n&Approve too\n&Cancel", 3)]
  else
    answer = vim.fn.confirm(question, "&Publish\n&Cancel", 2) == 1 and "comment" or nil
  end
  if not answer then
    return
  end
  vim.system({ "git-mr-submit", iid, range, vim.env.GMR_KIND, answer }, { cwd = root, text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      notify(vim.trim(res.stderr), vim.log.levels.ERROR)
    end
    refresh(function()
      if res.code == 0 then
        notify(answer == "approve" and "submitted and approved" or "submitted")
      end
    end)
  end))
end

-- ]r and [r: the next or previous file in the MR, in the file picker's order
-- (tests hidden or shown, as there), at its first change, marked viewed, and
-- in the same two-pane diff against the base when that was showing. The base
-- pane is built here from git rather than through gitsigns, which attaches to
-- a new buffer asynchronously; for a file the MR adds it is empty, so the
-- layout holds and every line shows as added. A file the MR deletes is the
-- mirror image, and always two panes: its base version on the left, focused so
-- its removed lines can take comments, and an empty pane where it was.
local files -- the MR's files as { path, deleted }, listed on first use
local diffing = base ~= nil -- gmr opens nvim in the diff

local function is_base_pane(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name:match("^gitsigns://") or name:match("^gmr%-base://")
end

-- The file a window shows on the MR's side: a file in the worktree, or the
-- empty pane standing in for a deleted one (gmr-deleted://<path>).
local function shown_file(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local deleted = vim.api.nvim_buf_get_name(buf):match("^gmr%-deleted://(.+)$")
  if deleted then
    return deleted, true
  end
  local path, side = buf_target(buf)
  if path and side == "new" then
    return path, false
  end
end

local function base_lines(path)
  local res = vim.system({ "git", "show", base .. ":" .. path }, { cwd = root, text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  local lines = vim.split(res.stdout, "\n")
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function scratch(name, lines, filetype, label)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- nowrite, like gitsigns' pane, so <leader>gd closes these too.
  vim.bo[buf].buftype = "nowrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_name(buf, name)
  if label then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_text = { { label, "Comment" } }, virt_text_pos = "overlay" })
  end
  return buf
end

-- The base version of path in a read-only pane left of win, both in diff mode,
-- unfolded: the whole file shows, not just the changes, and stays that way
-- while you edit. Returns the pane's window.
local function open_base_pane(win, path)
  local lines = base_lines(path)
  local filetype = vim.filetype.match({ filename = path }) or ""
  local buf = scratch("gmr-base://" .. path, lines or {}, filetype, not lines and "added in this MR" or nil)
  vim.api.nvim_set_current_win(win)
  vim.cmd("aboveleft vertical sbuffer " .. buf)
  local pane = vim.api.nvim_get_current_win()
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(win)
  vim.cmd("diffthis")
  vim.wo[pane].foldenable = false
  vim.wo[win].foldenable = false
  return pane
end

-- A deleted file in win: the empty pane where it was, its base beside it, and
-- the cursor in the base, where its lines are.
local function show_deleted(win, path)
  local filetype = vim.filetype.match({ filename = path }) or ""
  local old = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, scratch("gmr-deleted://" .. path, {}, filetype, "deleted in this MR"))
  if vim.api.nvim_buf_is_valid(old) and vim.env.GMR_PLACEHOLDER and vim.api.nvim_buf_get_name(old) == vim.fn.resolve(vim.env.GMR_PLACEHOLDER) then
    vim.api.nvim_buf_delete(old, { force = true })
  end
  local pane = open_base_pane(win, path)
  vim.api.nvim_set_current_win(pane)
  return pane
end

local function goto_file(step)
  if not range or range == "" then
    return
  end
  if not files then
    files = {}
    for _, row in ipairs(vim.fn.systemlist({ "git-commit-open", "--files", "--deleted", range })) do
      local path, mark = row:match("^([^\t]+)\t?(.*)$")
      table.insert(files, { path = path, deleted = mark == "deleted" })
    end
  end
  -- From whichever side of the diff, work in the window showing the MR's side.
  local file_win, current, current_deleted
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local path, deleted = shown_file(w)
    if path and (not file_win or w == vim.api.nvim_get_current_win()) then
      file_win, current, current_deleted = w, path, deleted
    end
  end
  if not file_win then
    return
  end
  vim.api.nvim_set_current_win(file_win)
  local at = 0
  for i, f in ipairs(files) do
    if f.path == current then
      at = i
    end
  end
  local to = at + step
  if to < 1 or to > #files then
    notify(step > 0 and "that was the last file" or "that was the first file")
    return
  end
  -- Keep the diff if a base pane is up, drop it if you closed it. A deleted
  -- file always has one, so it says nothing about that.
  local open = false
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_base_pane(vim.api.nvim_win_get_buf(w)) then
      open = true
      vim.api.nvim_win_close(w, true)
    end
  end
  vim.cmd("diffoff!")
  if not current_deleted then
    diffing = open
  end
  local target = files[to]
  local path = target.path
  local line = tonumber(vim.trim(vim.fn.system({ "git-commit-open", "--line", range, path }))) or 1
  if target.deleted then
    local pane = show_deleted(file_win, path)
    pcall(vim.api.nvim_win_set_cursor, pane, { 1, 0 })
  else
    vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. path))
    local win = vim.api.nvim_get_current_win()
    if diffing and base then
      open_base_pane(win, path)
    end
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  end
  vim.cmd("normal! zz")
  vim.system({ "git-mr-viewed", "add", iid, range:match("%.%.(.+)$"), path }, { cwd = root })
  notify(("%d of %d  %s%s"):format(to, #files, path, target.deleted and "  (deleted)" or ""))
end

local function attach(buf)
  if not buf_target(buf) or vim.b[buf].gmr_attached then
    return
  end
  vim.b[buf].gmr_attached = true
  vim.keymap.set("n", "<leader>mc", function()
    local lnum = vim.fn.line(".")
    comment(lnum, lnum)
  end, { buffer = buf, desc = "MR: comment or reply on this line" })
  vim.keymap.set("x", "<leader>mc", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27")
    comment(math.min(a, b), math.max(a, b), true)
  end, { buffer = buf, desc = "MR: new thread on the selected lines" })
  vim.keymap.set("n", "<leader>mr", toggle_resolved, { buffer = buf, desc = "MR: resolve or unresolve thread" })
  vim.keymap.set("n", "<leader>me", function()
    on_own_note(edit_note)
  end, { buffer = buf, desc = "MR: edit your comment on this line" })
  vim.keymap.set("n", "<leader>md", function()
    on_own_note(delete_note)
  end, { buffer = buf, desc = "MR: delete your comment on this line" })
  vim.keymap.set("n", "<leader>mu", function()
    refresh(function()
      notify(#threads .. " threads")
    end)
  end, { buffer = buf, desc = "MR: refetch threads" })
  vim.keymap.set("n", "<leader>ml", list, { buffer = buf, desc = "MR: all threads in quickfix" })
  vim.keymap.set("n", "<leader>mo", others, { buffer = buf, desc = "MR: threads on no line" })
  vim.keymap.set("n", "<leader>mt", toggle_drafting, { buffer = buf, desc = "MR: drafts or sent at once" })
  vim.keymap.set("n", "<leader>ms", submit, { buffer = buf, desc = "MR: submit your drafts" })
  vim.keymap.set("n", "]r", function()
    goto_file(1)
  end, { buffer = buf, desc = "MR: next file" })
  vim.keymap.set("n", "[r", function()
    goto_file(-1)
  end, { buffer = buf, desc = "MR: previous file" })
  render(buf)
end

-- gmr opens nvim in the diff against the MR's base: the base pane is opened
-- here, the same one ]r opens, empty for a file the MR adds and beside an empty
-- pane for one it deletes. vim.g.diff_base_opened claims it, for an nvim config
-- that would open a diff of its own for NVIM_DIFF_BASE and checks that flag.
do
  local path, side = buf_target(vim.api.nvim_get_current_buf())
  if base and vim.env.GMR_DELETED then
    -- Opened on a deleted file (git-commit-open starts nvim on an empty placeholder for it).
    vim.g.diff_base_opened = true
    show_deleted(vim.api.nvim_get_current_win(), vim.env.GMR_DELETED)
  elseif base and path and side == "new" and not vim.g.diff_base_opened then
    vim.g.diff_base_opened = true
    local win = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    open_base_pane(win, path)
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    hl_made = {}
    render_all()
  end,
})
vim.api.nvim_create_autocmd({ "BufWinEnter" }, {
  group = vim.api.nvim_create_augroup("gmr_comments", { clear = true }),
  callback = function(ev)
    attach(ev.buf)
  end,
})
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  attach(buf)
end

glab("GET", "user", nil, function(u)
  me = u.username
end)

-- From the threads picker (git-mr-threads): one thread, in an nvim of its own.
local thread = vim.env.GMR_THREAD
if thread then
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "!" .. iid .. " thread", "",
    "q quits · <leader>mo threads on no line · <leader>mt drafts or sent at once · <leader>ms submits your drafts",
  })
  vim.keymap.set("n", "q", "<cmd>qa!<cr>", { buffer = buf })
  vim.keymap.set("n", "<leader>mo", others, { buffer = buf, desc = "MR: threads on no line" })
  vim.keymap.set("n", "<leader>mt", toggle_drafting, { buffer = buf, desc = "MR: drafts or sent at once" })
  vim.keymap.set("n", "<leader>ms", submit, { buffer = buf, desc = "MR: submit your drafts" })
  refresh(function()
    for _, t in ipairs(threads) do
      if t.id == thread then
        return open_thread(t)
      end
    end
    notify("that thread is gone", vim.log.levels.WARN)
  end)
  return
end

glab("GET", mr, nil, function(m)
  local head = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "HEAD" })[1]
  if m.diff_refs.head_sha ~= head then
    -- The review worktree fell behind a push, or your own branch has commits the
    -- MR does not (or lacks some): line numbers would not match GitLab's. Said
    -- now, and checked again before each new comment.
    notify(("this checkout is not at the MR's head (%s), so new comments are off until it is; replies, resolve, edit and delete still work")
      :format(m.diff_refs.head_sha:sub(1, 8)), vim.log.levels.WARN)
  end
end)
refresh()
