# The new path of a `git diff --numstat -M` record, which writes a rename as
# "old => new" or, where the paths share ends, "dir/{old => new}.ts".
function numstat_path(p,   pre, mid, post) {
  if (index(p, " => ") == 0) return p
  if (match(p, /\{[^}]* => [^}]*\}/)) {
    pre = substr(p, 1, RSTART - 1)
    mid = substr(p, RSTART + 1, RLENGTH - 2)
    post = substr(p, RSTART + RLENGTH)
    sub(/^.* => /, "", mid)
    p = pre mid post
    gsub(/\/\//, "/", p)
    return p
  }
  sub(/^.* => /, "", p)
  return p
}
