# Row formatting shared by the pickers' list scripts, pasted into a caller's
# awk program the way share/markdown.awk is: awk "${OTIS_ROWFMT:-$(cat
# share/rowfmt.awk)}"'...'. git-fzf reads this file once and exports it as
# OTIS_ROWFMT, so nothing under a picker starts a cat for it; the fallback is
# for a script run from somewhere else.
# awk runs every BEGIN block in the order it reads them, so the palette below is
# set before the caller's own BEGIN.
#
# The palette is named for the job each color does, not for its hue, so the
# same color means the same thing in every picker. The hues are the theme's
# (otis-theme), as git-delta's are.
#
# The rule these helpers exist to keep: a row has a FIXED ZONE of state you act
# on, which is never cut, and a TAIL of context, which is cut from the right
# when the pane is narrow. Keeping the fixed zone genuinely fixed is why the
# widths here are counted rather than left to the content.

BEGIN {
  # The theme's hues (otis-theme), from the environment the picker set up;
  # without one, the terminal's own colors, which is the default theme.
  GK_ATTENTION = gk_sgr("ATTENTION", "33")   # look here: keys, ids, something waiting
  GK_GOOD      = gk_sgr("GOOD", "32")        # passed, approved, safe to remove
  GK_BAD       = gk_sgr("BAD", "31")         # failed, deleted, in the way
  GK_ELSEWHERE = gk_sgr("ELSEWHERE", "36")   # somewhere other than here: a worktree, a thread
  GK_YOURS     = gk_sgr("YOURS", "35")       # waiting on you: drafts, fixes, unresolved
  GK_TEXT      = gk_sgr("TEXT", "39")        # what the row is about
  GK_CONTEXT   = gk_sgr("CONTEXT", "90")     # true, but not why you are looking
  GK_FAINT     = gk_sgr("FAINT", "2")        # structure: rules, separators, empty slots
  GK_MAIN      = gk_sgr("MAIN", "34")        # main, and things that are not yours to move
  GK_R         = "\033[0m"
  # The time, once, for the ages the rows show: a date process cost as much
  # as the awk that used it.
  GK_NOW = gk_now()
}
function gk_sgr(k, dflt) { return "\033[" (("OTIS_T_" k) in ENVIRON ? ENVIRON["OTIS_T_" k] : dflt) "m" }
# Unix seconds without a process: srand() seeds with the time of day and
# returns the seed before it, so the second call answers with the first's.
function gk_now() { srand(); return srand() }

function gk_rep(s, n,   out) { out = ""; while (n-- > 0) out = out s; return out }
function gk_padl(s, n) { s = s ""; while (length(s) < n) s = " " s; return s }
function gk_padr(s, n) { s = s ""; while (length(s) < n) s = s " "; return s }

# A path shortened to `budget` columns: the name always survives, then as many
# parent directories as fit, with "…/" marking what was dropped. Only a name
# longer than the budget on its own is cut, and then from the front, since the
# extension is the part worth keeping.
function gk_fit(p, budget,   n, a, i, out, cand, slash) {
  # git status lists an untracked directory with a trailing slash; that slash
  # is part of the name, not a separator, so it rides along.
  slash = ""
  if (substr(p, length(p)) == "/") { slash = "/"; p = substr(p, 1, length(p) - 1); budget-- }
  if (length(p) <= budget) return p slash
  n = split(p, a, "/")
  out = a[n]
  if (length(out) + 2 > budget) return "\342\200\246" substr(out, length(out) - budget + 2) slash
  for (i = n - 1; i >= 1; i--) {
    cand = a[i] "/" out
    if (length(cand) + 2 > budget) break
    out = cand
  }
  return "\342\200\246/" out slash
}

# Everything up to and including the last "/", or "" for a bare name. An
# untracked directory's trailing slash belongs to its name, so it is not one.
function gk_dir(p,   i) {
  if (substr(p, length(p)) == "/") p = substr(p, 1, length(p) - 1)
  for (i = length(p); i >= 1; i--) if (substr(p, i, 1) == "/") return substr(p, 1, i)
  return ""
}

# A fitted path with its directory dimmed, so the eye lands on the name rather
# than on the twelve rows that all start "packages/billing/src/".
function gk_path(p, budget, namecol,   s, d) {
  s = gk_fit(p, budget)
  d = gk_dir(s)
  return GK_CONTEXT d GK_R namecol substr(s, length(d) + 1) GK_R
}

# The digits a count needs, for sizing a column to the widest one in the list.
function gk_digits(n) { n = n + 0; if (n <= 0) return 0; return length(n "") }

# How big a change is, in wa+wd+3 columns: "+42  -8", blank where there is
# nothing to say (an untracked file, a binary one). The widths are the widest
# counts in the list, measured before anything is printed, so the column is
# never ragged and never wider than it has to be: guessing three digits was
# enough until a file lost 123 lines and pushed every column after it along.
function gk_stat(add, del, wa, wd,   a, d) {
  if (wa + 0 < 1) wa = 1
  if (wd + 0 < 1) wd = 1
  a = (add != "" && add + 0 > 0) ? GK_GOOD "+" gk_padl(add, wa) GK_R : gk_rep(" ", wa + 1)
  d = (del != "" && del + 0 > 0) ? GK_BAD "-" gk_padl(del, wd) GK_R : gk_rep(" ", wd + 1)
  return a " " d
}

# Three blocks: how much of a change adds and how much it removes. Three, not
# five, because a long list of five-block bars stacks into a solid wall of
# color that drowns out the names beside it. A side with any lines at all
# keeps a block, so a 300-line addition with one deletion still shows it.
function gk_bar(add, del,   t, g, b) {
  add = add + 0; del = del + 0
  t = add + del
  if (t == 0) return GK_FAINT "..." GK_R
  g = (add > 0) ? int(3 * add / t + 0.5) : 0
  b = (del > 0) ? int(3 * del / t + 0.5) : 0
  if (add > 0 && g < 1) g = 1
  if (del > 0 && b < 1) b = 1
  while (g + b > 3) { if (g >= b) g--; else b-- }
  return GK_GOOD gk_rep("\342\226\210", g) GK_BAD gk_rep("\342\226\210", b) \
         GK_FAINT gk_rep("\342\226\210", 3 - g - b) GK_R
}

# The new path of a `git diff --numstat -M` record, which writes a rename as
# "old => new" or, where the paths share ends, "dir/{old => new}.ts".
function gk_numstat_path(p,   pre, mid, post) {
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

# The columns a picker's list pane gets. fzf reports 0 to a start:reload,
# before it has drawn, and COLUMNS is not exported, so fall back to the
# terminal.
#
# Mirrors git-fzf's preview-window rule. fzf's "<66(...)" alternative triggers
# on the width of the PREVIEW WINDOW, not the terminal (fzf(1): "used only when
# the size of the preview window is below a certain threshold"), and the
# preview takes 55%. So the preview sits beside the list from 120 columns up,
# and only under that does it stack underneath and leave the list the whole
# width. Written as fzf's own arithmetic so the two stay the same rule.
function gk_list_width(cols) {
  if (cols + 0 <= 0) cols = 100
  return (int(cols * 55 / 100) < 66) ? cols - 6 : int(cols * 45 / 100) - 4
}

# A signature in w columns. awk counts bytes here (the callers run LC_ALL=C,
# so every awk does the same), and a cut may land inside a multibyte
# character: the partial one goes too.
function gk_cut(s, w) {
  if (length(s) <= w) return s
  s = substr(s, 1, w - 1); sub(/[\300-\367][\200-\277]*$/, "", s)
  return s "\342\200\246"
}
# A signature that does not fit gives up what says least first: the
# parameter list, then the generics, so "function cleanupOldData(…):
# Promise<void>" survives where a cut from the right left the name and
# nothing after it. The first balanced pair is the one after the name.
function gk_elide(s, lp, rp,   i, d, c) {
  d = 0
  for (i = index(s, lp); i > 0 && i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == lp) d++
    else if (c == rp && --d == 0) return substr(s, 1, index(s, lp)) "\342\200\246" substr(s, i)
  }
  return s
}
# Every parenthesised group after the first, elided: a class extending
# Effect.Service<X>()("X", { dependencies … }) says nothing past the ().
function gk_elide_rest(s,   i, d, c, from, groups) {
  d = 0; from = 0; groups = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "(") { if (d == 0) from = i; d++ }
    else if (c == ")" && d > 0 && --d == 0) {
      if (from > 0 && groups++) { s = substr(s, 1, from) "\342\200\246" substr(s, i); i = from + 2 }
    }
  }
  return s
}
function gk_sig(s, w) {
  if (length(s) <= w) return s
  s = gk_elide(s, "(", ")"); if (length(s) <= w) return s
  s = gk_elide(s, "<", ">"); if (length(s) <= w) return s
  return gk_cut(s, w)
}
