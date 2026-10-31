# The diff reader: per file, which new lines came (add), which old
# lines went (del), where a deletion sits in new numbering (delat) and an
# insertion in old numbering (addat), and for each old line that went, the new
# line where the change now sits (at). Keyed by `which` too, for a program
# reading two diffs. Include it in an awk program and give it a -U0 or
# -U999999 diff to read.
  /^--- / { fo = substr($0, 5); sub(/^a\//, "", fo); next }
  /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); if (f == "/dev/null") f = fo; K = which SUBSEP f; next }
  /^@@/ { split($0, w, " "); split(w[2], a, ","); o = substr(a[1], 2) + 0; split(w[3], b, ","); nn = substr(b[1], 2) + 0; next }
  /^-/ { del[K, o] = 1; delat[K, nn] = 1; at[K, o] = nn; if ($0 ~ /^-[ \t]*$/) blank[K, "old", o] = 1; o++; next }
  /^\+/ { add[K, nn] = 1; addat[K, o] = 1; if ($0 ~ /^\+[ \t]*$/) blank[K, "new", nn] = 1; nn++; next }
  { next }
  # How many of the lines in [s, e] on this side changed (came, on the new
  # side; went, on the old), and whether anything in there did at all: a line
  # of it, or a change sitting between two of its lines.
  function lines(which, f, side, s, e,   l, c) {
    c = 0
    for (l = s; l <= e; l++) {
      if (side == "new") { if ((which, f, l) in add) c++ }
      else if ((which, f, l) in del) c++
    }
    return c
  }
  function touched(which, f, side, s, e,   l) {
    for (l = s; l <= e; l++) {
      if (side == "new") { if ((which, f, l) in add) return 1; if (l > s && ((which, f, l) in delat)) return 1 }
      else               { if ((which, f, l) in del) return 1; if (l < e && ((which, f, l) in addat)) return 1 }
    }
    return 0
  }
  # The same unchanged line on the other side of the diff.
  function shift(which, f, side, l,   x, n) {
    n = l
    for (x = 1; x <= l; x++) {
      if (side == "new") { if (x < l && ((which, f, x) in add)) n--; if ((which, f, x) in delat) n++ }
      else               { if (x < l && ((which, f, x) in del)) n--; if (x < l && ((which, f, x) in addat)) n++ }
    }
    return n
  }
