# The preview pane's wrap, for the screens drawn by hand (otis-dash,
# otis-symbols): each line cut to the pane (w). A long line breaks at its last
# space that fits (mid-word only when there is none), and each piece after the
# first starts with the line's own lead, its indent and any bar it opens with
# (│ ┃ ▌), in the line's colors, so a thread or a callout stays one block. The
# colors in force at the break carry on into the next piece. Which lines are
# such pieces, and how wide their lead is, goes to cont, so text selected in
# the pane copies as the lines it was rather than as the pane broke them.
# Run LC_ALL=C.
function esc(s) { return s == "\033[0m" || s == "\033[m" }
function out(s, piece) { print s; on++; if (piece) print on, lw > cont }
{
  # What only a terminal's own screen may do, kept out of a pane: a carriage
  # return (a progress line, Bazel's, drawn over itself: its last drawing is
  # what it says) and every control but escape and tab. A cursor move or an
  # erase (Bazel's again, redrawing its progress) is dropped below, with any
  # escape but a color or a link: sent into the pane, they moved the cursor
  # and erased rows elsewhere on the screen, and the rows the frame did not
  # know to redraw kept what was left there.
  sub(/\r+$/, "")
  if (index($0, "\r")) $0 = substr($0, match($0, /\r[^\r]*$/) + 1)
  gsub(/[\001-\010\013-\032\034-\037\177]/, "")
  gsub(/\t/, "        ")
  # The line in units: an escape (no width) or a character (one).
  n = 0; i = 1; L = length($0)
  while (i <= L) {
    c = substr($0, i, 1)
    if (c == "\033" && match(substr($0, i), /^\033\[[0-9;:?]*[A-Za-z]/)) { if (substr($0, i + RLENGTH - 1, 1) == "m") { u[++n] = substr($0, i, RLENGTH); vis[n] = 0 }; i += RLENGTH; continue }
    # A link (OSC 8) or a title, dropped, its text kept: the pane has the
    # mouse, so a link in it is never clicked, and a terminal (or a
    # multiplexer) that does not know the ESC \\ ending an OSC took the rest
    # of the frame into it, the erases and the moves to the rows below with it.
    if (c == "\033" && match(substr($0, i), /^\033\][^\007\033]*(\007|\033\\)/)) { i += RLENGTH; continue }
    # Any other escape, and a lone one, goes with the character after it.
    if (c == "\033") { i += 2; continue }
    j = i + 1
    while (j <= L && substr($0, j, 1) ~ /[\200-\277]/) j++
    u[++n] = substr($0, i, j - i); vis[n] = 1; i = j
  }
  # The lead: spaces and bars before the text.
  lead = ""; lw = 0
  for (k = 1; k <= n; k++) {
    if (!vis[k]) { lead = lead u[k]; continue }
    if (u[k] == " " || u[k] == "\342\224\202" || u[k] == "\342\224\203" || u[k] == "\342\226\214") { lead = lead u[k]; lw++; continue }
    break
  }
  if (lw > w / 2) { lead = ""; lw = 0 }
  cur = ""; cw = 0; sgr = ""; sp = 0; pc = 0
  for (k = 1; k <= n; k++) {
    if (!vis[k]) { cur = cur u[k]; if (esc(u[k])) sgr = ""; else if (u[k] ~ /m$/) sgr = sgr u[k]; continue }
    if (cw >= w) {
      if (sp > 0 && spw > lw) {
        out(substr(cur, 1, sp) "\033[0m", pc); pc = 1
        cur = lead spsgr substr(cur, sp + 1); cw = lw + cw - spw
      } else {
        out(cur "\033[0m", pc); pc = 1
        cur = lead sgr; cw = lw
      }
      sp = 0
    }
    cur = cur u[k]; cw++
    if (u[k] == " " && cw > lw) { sp = length(cur); spw = cw; spsgr = sgr }
  }
  out(cur "\033[0m", pc); pc = 0
}
END { printf "" > cont }