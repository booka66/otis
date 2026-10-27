# A picker's rows (otis-pick), each in as many lines as the list's width (w)
# takes, never cut. A row that fits is as it is. One too wide breaks where
# screen.zsh's wrapc breaks colored text, for a whole list in one process,
# since wrapc in zsh took a millisecond a row: after the last space, / or
# comma that fits, a word longer than a line after its last _ or - or before
# a capital starting a word in a name (replyModel|Test), else where the line
# ends. The lines after the first go under the row's text: where the last gap
# of two spaces in its first w - 20 columns ends (a log's subject, after its
# sha and age; a file's path, after its counts), else two in. Each line
# opens with the colors in force where it starts.
#
# A line out for each row in, its lines a \036 apart. Run LC_ALL=C.
function emit(upto,   q, s) {
  s = first ? "" : sprintf("%" ind "s", "")
  for (q = 1; q <= upto; q++) s = s lu[q]
  res = res (first ? "" : "\036") s "\033[0m"
  first = 0
}
{
  # The row in units: an escape (no width) or a character (one).
  n = 0; L = length($0); i = 1
  while (i <= L) {
    c = substr($0, i, 1)
    if (c == "\033" && (match(substr($0, i), /^\033\[[0-9;:?]*[A-Za-z]/) || match(substr($0, i), /^\033\][^\007\033]*(\007|\033\\)/))) {
      u[++n] = substr($0, i, RLENGTH); vis[n] = 0; i += RLENGTH; continue
    }
    j = i + 1
    while (j <= L && substr($0, j, 1) ~ /[\200-\277]/) j++
    u[++n] = substr($0, i, j - i); vis[n] = (c != "\033"); i = j
  }
  width = 0
  for (k = 1; k <= n; k++) width += vis[k]
  if (width <= w) { print; next }
  # Its text column.
  ind = -1; col = 0; sp = 0; lead = -1
  for (k = 1; k <= n; k++) {
    if (!vis[k]) continue
    if (u[k] == " ") sp++
    else {
      if (lead < 0) lead = col
      else if (sp >= 2 && col <= w - 20) ind = col
      sp = 0
    }
    col++
  }
  if (ind < 0) ind = (lead > 0 ? lead : 0) + 2
  # Its lines, as wrapc makes them: lu the units of the line being made, bk
  # the last break after a space, / or comma (bkw its width there, bst the
  # colors then), bk2 the last within a word.
  m = 0; cw = 0; lim = w; st = ""; bk = 0; bk2 = 0; pv = ""; first = 1; res = ""
  for (k = 1; k <= n; k++) {
    t = u[k]
    if (!vis[k]) {
      lu[++m] = t
      if (t ~ /^\033\[0?m$/) st = ""; else if (t ~ /^\033\[.*m$/) st = st t
      continue
    }
    if (cw && t ~ /^[A-Z]$/ && pv ~ /^[a-z0-9]$/) { bk2 = m; bkw2 = cw; bst2 = st }
    if (cw + 1 > lim) {
      # A space past the end: the line is full as it is.
      if (t == " ") { emit(m); m = 0; lu[++m] = st; cw = 0; bk = 0; bk2 = 0; lim = w - ind; continue }
      if (!bk && bk2) { bk = bk2; bkw = bkw2; bst = bst2 }
      if (bk) {
        emit(bk)
        mm = 0; tmp[++mm] = bst
        for (q = bk + 1; q <= m; q++) tmp[++mm] = lu[q]
        for (q = 1; q <= mm; q++) lu[q] = tmp[q]
        m = mm; cw -= bkw
        if (bk2 > bk) { bk2 -= bk - 1; bkw2 -= bkw } else bk2 = 0
        bk = 0
      } else {
        emit(m); m = 0; lu[++m] = st; cw = 0; bk2 = 0
        if (t == " ") continue
      }
      lim = w - ind
    }
    lu[++m] = t; cw++; pv = t
    if (t == " " || t == "/" || t == ",") { bk = m; bkw = cw; bst = st }
    if (t == "_" || t == "-") { bk2 = m; bkw2 = cw; bst2 = st }
  }
  emit(m)
  print res
}
