-- nvim -l mr-claude-drafts.lua <root> <diff_refs.json> <findings.json> [symbols.tsv callers.tsv kinds.tsv order]
-- Claude's review comments (git-mr-claude) as draft note bodies, one JSON
-- object a line, in the order the symbol view reads the symbols they sit on:
-- { where, symbol, note, position, fallback, why }, why being Claude's
-- reasons and its lesson, for the reviewer alone. Posting them is
-- git-mr-claude's, never this script's. A comment goes on its lines when they
-- are lines of a file in the MR on that side; anything else, and any comment
-- GitLab refuses a position for (fallback), goes on the MR itself, naming the
-- place it meant.
--
-- The reviewer reads the change by symbol (git-symbols), so with seam's table
-- a comment is placed on its symbol too: the one whose lines hold it, else
-- the one Claude named. One about code the MR does not touch (a caller
-- elsewhere it breaks) goes on the signature of the symbol it names, so it
-- sits on that symbol's row beside its callers rather than on the MR. And
-- its why opens with where that symbol sits in the tree: what happened to
-- it, the way down to it from an entry point, and its callers elsewhere
-- (git-callers), so the reviewer can find what Claude means in the view.
local root, refs_file, findings_file, table_file, callers_file, kinds_file, order_file =
  arg[1], arg[2], arg[3], arg[4], arg[5], arg[6], arg[7]
local share = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local diff_position = dofile(share .. "/mr-position.lua")

local function read_json(file)
  return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"), { luanil = { object = true } })
end
local function rows(file)
  local out = {}
  if file and file ~= "" and vim.fn.filereadable(file) == 1 then
    for _, line in ipairs(vim.fn.readfile(file)) do
      table.insert(out, vim.split(line, "\t", { plain = true }))
    end
  end
  return out
end
local refs, findings = read_json(refs_file), read_json(findings_file)

local in_mr = {}
for _, path in ipairs(vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only", "--no-renames",
  refs.base_sha, refs.head_sha })) do
  in_mr[path] = true
end

local lengths = {}
local function length(sha, path)
  local key = sha .. ":" .. path
  if not lengths[key] then
    local lines = vim.fn.systemlist({ "git", "-C", root, "show", key })
    lengths[key] = vim.v.shell_error == 0 and #lines or 0
  end
  return lengths[key]
end

-- The symbols, from seam's table (its README names the columns), by id.
local symbols, by_id = {}, {}
for _, r in ipairs(rows(table_file)) do
  if r[2] ~= "file" and r[8] ~= "" then
    local name = r[4] ~= "" and (r[4] .. "." .. r[3]) or r[3]
    local s = { id = r[1] .. "#" .. name, name = name, path = r[1], class = r[4], exported = r[5] == "1",
      change = r[6], side = r[7], start = tonumber(r[8]), stop = tonumber(r[9]), open = tonumber(r[10]),
      root = r[19] == "1" and r[4] == "", uses = r[18] ~= "" and vim.split(r[18], "|", { plain = true }) or {} }
    table.insert(symbols, s)
    by_id[s.id] = s
  end
end
-- What a row opens to in the tree: the changed symbols it uses, and a
-- class its members.
local function under(s)
  local ids = vim.list_extend({}, s.uses)
  for _, m in ipairs(symbols) do
    if m.class ~= "" and m.path == s.path and m.class == s.name then
      table.insert(ids, m.id)
    end
  end
  return ids
end
-- The entry points as the tree lists them (git-symbols): those in the
-- gloss's reading order (order, an id a line) first, then the rest of the
-- source, then tests, generated code and config, each in their own section
-- below (git-test-files kinds).
local kinds = {}
for _, r in ipairs(rows(kinds_file)) do
  kinds[r[1]] = r[2] or ""
end
local roots, listed = {}, {}
for _, r in ipairs(rows(order_file)) do
  local s = by_id[r[1]]
  if s and s.root and not listed[s.id] then
    listed[s.id] = true
    table.insert(roots, s)
  end
end
for _, s in ipairs(symbols) do
  if s.root and (kinds[s.path] or "") == "" and not listed[s.id] then
    table.insert(roots, s)
  end
end
for _, s in ipairs(symbols) do
  if s.root and (kinds[s.path] or "") ~= "" then
    table.insert(roots, s)
  end
end
-- The order the tree reads them, opened all the way (L): each entry point,
-- then what it opens to, depth first. The way down to a symbol is where the
-- reviewer first meets it reading top down.
local n = 0
local via = {}
local function walk(s, path)
  if s.order then
    return
  end
  n = n + 1
  s.order = n
  via[s.id] = vim.list_extend(vim.list_extend({}, path), { s.name })
  for _, id in ipairs(under(s)) do
    if by_id[id] then
      walk(by_id[id], via[s.id])
    end
  end
end
for _, s in ipairs(roots) do
  walk(s, {})
end
for _, s in ipairs(symbols) do
  walk(s, {})
end
-- Callers elsewhere, and how many of them the change breaks.
local callers = {}
for _, r in ipairs(rows(callers_file)) do
  if r[1] ~= "-" then
    local c = callers[r[1]] or { n = 0, broken = {} }
    c.n = c.n + 1
    if tonumber(r[9]) > 0 then
      table.insert(c.broken, (r[4]:match("#(.*)$") or r[4]))
    end
    callers[r[1]] = c
  end
end

-- The innermost symbol holding a line on a side.
local function holding(path, side, line)
  local best
  for _, s in ipairs(symbols) do
    if s.path == path and s.side == side and s.start <= line and line <= s.stop
      and (not best or s.stop - s.start < best.stop - best.start) then
      best = s
    end
  end
  return best
end

local changes = { added = "new", removed = "removed", signature = "~ signature changed", body = "body only" }
-- The why's first line: the symbol as the tree has it.
local function locator(s, meant)
  local parts = { ("**`%s`**"):format(s.name), changes[s.change] or s.change }
  if s.root then
    table.insert(parts, "an entry point")
  elseif via[s.id] and #via[s.id] > 1 then
    table.insert(parts, "reached from " .. table.concat(vim.tbl_map(function(n)
      return "`" .. n .. "`"
    end, via[s.id]), " › "))
  end
  local c = callers[s.id]
  if c then
    table.insert(parts, ("%d caller%s elsewhere%s"):format(c.n, c.n == 1 and "" or "s",
      #c.broken > 0 and (", ✗ " .. table.concat(c.broken, ", ")) or ""))
  end
  if meant then
    table.insert(parts, "about " .. meant)
  end
  return table.concat(parts, " · ")
end

local out = {}
for i, f in ipairs(findings) do
  local path, side, first, last = f.path, f.side, f.first_line, f.last_line
  local function where_of()
    local w = first == last and ("%s:%d"):format(path, first) or ("%s:%d-%d"):format(path, first, last)
    return side == "old" and (w .. " (removed)") or w
  end
  local sha = side == "old" and refs.base_sha or refs.head_sha
  local on_lines = in_mr[path] and first >= 1 and first <= last and last <= length(sha, path)
  local s = on_lines and holding(path, side, first) or nil
  local meant
  if not s and by_id[f.symbol] then
    s = by_id[f.symbol]
    if not on_lines then
      -- Not a place in the MR: on the named symbol's signature instead.
      meant = where_of()
      path, side, first = s.path, s.side, s.open or s.start
      last, on_lines = first, true
    end
  end
  local where = where_of()
  local fallback = ("`%s`\n\n%s"):format(where, f.body)
  local why = f.concept and ("%s\n\n## %s\n\n%s"):format(f.why, f.concept, f.lesson) or f.why
  if s then
    why = locator(s, meant) .. "\n\n" .. why
  end
  local o = { where = where, symbol = s and s.name or nil, fallback = fallback, why = why,
    order = s and s.order or math.huge, at = i }
  if on_lines then
    o.note = f.body
    o.position = diff_position.position(root, refs, path, side, first, last)
  else
    o.note = fallback
  end
  table.insert(out, o)
end
-- In the tree's order, so the drafts read top to bottom as the view does.
table.sort(out, function(a, b)
  if a.order ~= b.order then
    return a.order < b.order
  end
  return a.at < b.at
end)
for _, o in ipairs(out) do
  o.order, o.at = nil, nil
  io.write(vim.json.encode(o), "\n")
end
