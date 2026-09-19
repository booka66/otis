-- Where a comment goes in an MR's diff, as GitLab's API wants it. Shared by
-- nvim's comments (share/mr-comments.lua) and Claude's drafts
-- (share/mr-claude-drafts.lua, run headless). root is any checkout of the repo:
-- only commits are read.
local M = {}

-- Where a line sits in the MR's diff, the way GitLab numbers it: old and new line
-- numbers plus a type, "new" for a line the MR added, "old" for one it removed,
-- "" for one it kept. An added line has no old number, so old is where the old
-- side stood when it came up (the next old line), and likewise for removed lines.
-- Walk the MR's hunks (zero context) up to the line, tracking how far the other
-- side has shifted; a line inside a hunk's own range is one the MR changed. In a
-- hunk, git lists the removed lines before the added ones.
function M.locate(root, refs, path, side, lnum)
  local lines = vim.fn.systemlist({ "git", "-C", root, "diff", "-U0", "--no-color", "--no-ext-diff",
    refs.base_sha, refs.head_sha, "--", path })
  local shift = 0 -- new minus old, from the hunks before lnum
  for _, l in ipairs(lines) do
    local ostart, oc, nstart, nc = l:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if ostart then
      ostart, nstart = tonumber(ostart), tonumber(nstart)
      oc, nc = oc == "" and 1 or tonumber(oc), nc == "" and 1 or tonumber(nc)
      local start = side == "new" and nstart or ostart
      local n = side == "new" and nc or oc
      if n > 0 and lnum >= start and lnum < start + n then
        -- A range of zero lines names the line before it.
        if side == "new" then
          return { type = "new", new = lnum, old = oc > 0 and ostart + oc or ostart + 1 }
        end
        return { type = "old", old = lnum, new = nc > 0 and nstart or nstart + 1 }
      end
      if (n > 0 and start + n - 1 < lnum) or (n == 0 and start < lnum) then
        shift = shift + nc - oc
      else
        break
      end
    end
  end
  if side == "new" then
    return { type = "", new = lnum, old = lnum - shift }
  end
  return { type = "", old = lnum, new = lnum + shift }
end

-- The position for a comment on lines first..last: GitLab anchors it on the last
-- line, and a range endpoint names its line by a code of the path's sha1 and
-- both numbers, with the side the line lacks zeroed.
function M.position(root, refs, path, side, first, last)
  -- shasum on macOS, sha1sum on most Linux.
  local tool = vim.fn.executable("shasum") == 1 and "shasum" or "sha1sum"
  local sha = vim.fn.system({ tool }, path):match("^%x+")
  local function endpoint(p)
    return {
      type = p.type, line_code = ("%s_%d_%d"):format(sha, p.old, p.new),
      old_line = p.type == "new" and 0 or p.old, new_line = p.type == "old" and 0 or p.new,
    }
  end
  local s, e = M.locate(root, refs, path, side, first), M.locate(root, refs, path, side, last)
  return {
    position_type = "text", base_sha = refs.base_sha, start_sha = refs.start_sha, head_sha = refs.head_sha,
    old_path = path, new_path = path,
    old_line = e.type ~= "new" and e.old or nil, new_line = e.type ~= "old" and e.new or nil,
    line_range = { start = endpoint(s), ["end"] = endpoint(e) },
  }
end

return M
