# Comment markdown for the terminal, in the theme's colors (otis-theme): md(text,
# width, lead) prints text, whose lines are separated by \037, wrapped to width
# columns with lead before every line. Pasted into a caller's awk program (awk
# "$(cat share/markdown.awk)"'...'), since awk takes one program, and run with
# LC_ALL=C, so widths count characters on macOS's awk as on gawk.
#
# Enough of GitLab's markdown for review comments: paragraphs, `code`,
# **bold**, *italic* and _italic_ at word edges (so snake_case stays), [links],
# # headings, > quotes, - and 1. lists, and ``` fences, which bat highlights by
# their language where it is installed. HTML comments and tags are dropped, as
# GitLab does not show them either. Anything else shows as written.
#
# With -v md_nvim=1, for nvim (share/mr-comments.lua), each line is lead and
# then its runs of text as highlight group and text, \036 between: the group is
# GmrMd_<fg>_<bg>_<b><i><u>, the colors hex, a<n> for the terminal's color n
# (the terminal theme's), or x for none, so the name says what to define it
# as. Nothing else changes, so bat's colors come through too.

function md_sgr(k, dflt) { return "\033[" (("OTIS_T_" k) in ENVIRON ? ENVIRON["OTIS_T_" k] : dflt) "m" }

# Color n of the 256, for nvim: the first 16 are the terminal's (a<n>), the
# rest are fixed, so hex.
function md_x256(n,    r, g, b) {
  n += 0
  if (n < 16) return "a" n
  if (n >= 232) { r = 8 + 10 * (n - 232); return sprintf("%02x%02x%02x", r, r, r) }
  n -= 16; r = int(n / 36); g = int(n / 6) % 6; b = n % 6
  return sprintf("%02x%02x%02x", r ? r * 40 + 55 : 0, g ? g * 40 + 55 : 0, b ? b * 40 + 55 : 0)
}

function md_reset() {
  md_code = 0; md_bold = 0; md_ital = 0; md_link = 0
}

# The escape codes for the inline state now.
function md_style(    s) {
  s = "\033[0m"
  if (md_code) return s md_codec
  if (md_bold) s = s "\033[1m"
  if (md_ital) s = s "\033[3m"
  return s (md_link ? md_linkc : md_fg)
}

# Columns a string takes: bytes, less escape codes and UTF-8 continuation bytes.
function md_cols(s) {
  gsub(/\033\[[0-9;]*m/, "", s)
  gsub(/[\200-\277]/, "", s)
  return length(s)
}

# One paragraph, list item or heading, wrapped: first before its first line,
# rest before the others (the hanging indent of a list item).
function md_flow(text, width, lead, first, rest,    words, n, i, j, k, w, L, ch, next_ch, prev, vis, out, line, used, cols, after, empty, style) {
  # Links become \002 text \003; the address is left out.
  while (match(text, /\[[^]]*\]\([^)]*\)/)) {
    w = substr(text, RSTART, RLENGTH)
    sub(/\]\(.*$/, "", w)
    text = substr(text, 1, RSTART - 1) "\002" substr(w, 2) "\003" substr(text, RSTART + RLENGTH)
  }
  n = split(text, words, / +/)
  line = first md_style(); used = md_cols(first); empty = 1
  for (i = 1; i <= n; i++) {
    w = words[i]; L = length(w); vis = ""; out = ""
    if (w == "") continue
    # The style the word starts in, for a line it starts.
    style = md_style()
    for (j = 1; j <= L; j++) {
      ch = substr(w, j, 1); next_ch = substr(w, j + 1, 1); prev = j > 1 ? substr(w, j - 1, 1) : ""
      if (ch == "`") { md_code = !md_code; out = out md_style(); continue }
      if (!md_code && ch == "\002") { md_link = 1; out = out md_style(); continue }
      if (!md_code && ch == "\003") { md_link = 0; out = out md_style(); continue }
      if (!md_code && ch == "*" && next_ch == "*") { md_bold = !md_bold; j++; out = out md_style(); continue }
      # An opening one needs a closing one after it, or a lone _private would
      # turn the rest of the paragraph italic.
      after = substr(w, j + 1)
      for (k = i + 1; k <= n && !index(after, ch); k++) after = after " " words[k]
      if (!md_code && (ch == "*" || ch == "_") &&
        ((!md_ital && (prev == "" || prev ~ /[(\["]/) && next_ch != "" && index(after, ch)) ||
         (md_ital && (next_ch == "" || next_ch ~ /[.,;:!?)\]"]/)))) {
        md_ital = !md_ital; out = out md_style(); continue
      }
      vis = vis ch; out = out ch
    }
    cols = md_cols(vis)
    if (!empty && used + 1 + cols > width) {
      md_print(lead, line "\033[0m")
      line = rest style; used = md_cols(rest)
    } else if (!empty) {
      line = line " "; used++
    }
    line = line out; used += cols; empty = 0
  }
  md_print(lead, line "\033[0m")
}

# A fence's lines, highlighted by bat in its language, else plain.
function md_fence(code, lang, lead,    tmp, cmd, l, got, lines, n) {
  got = 0
  if (lang != "" && md_bat) {
    tmp = md_tmp ".fence"
    printf "%s", code > tmp
    close(tmp)
    cmd = "COLORTERM=truecolor bat --color=always --paging=never --style=plain --theme='" md_battheme "' --language='" lang "' < '" tmp "' 2>/dev/null"
    while ((cmd | getline l) > 0) { md_print(lead, "  " l "\033[0m"); got = 1 }
    close(cmd)
    system("rm -f '" tmp "'")
  }
  if (got) return
  n = split(code, lines, "\n")
  for (l = 1; l <= n; l++) if (l < n || lines[l] != "") md_print(lead, "  " md_mainc lines[l] "\033[0m")
}

function md_gap(gap, lead) {
  if (gap) md_print(lead, "")
}

# One finished line: as it is for the terminal, or as runs for nvim. Every SGR
# code the renderer and bat write (truecolor, bold, italic, underline, reset)
# is read back here, so the two modes cannot drift apart.
function md_print(lead, line,    out, text, codes, c, n, i, k, fg, bg, b, it, u, name) {
  if (!md_nvim) { print lead line; return }
  out = ""; fg = "x"; bg = "x"; b = 0; it = 0; u = 0
  while (line != "") {
    if (match(line, /\033\[[0-9;]*m/)) {
      text = substr(line, 1, RSTART - 1); codes = substr(line, RSTART + 2, RLENGTH - 3); line = substr(line, RSTART + RLENGTH)
    } else {
      text = line; codes = ""; line = ""
    }
    if (text != "") {
      name = "GmrMd_" fg "_" bg "_" (b ? "b" : "") (it ? "i" : "") (u ? "u" : "")
      out = out (out == "" ? "" : "\036") name "\036" text
    }
    n = split(codes == "" ? "0" : codes, c, ";")
    for (i = 1; i <= n; i++) {
      k = c[i] + 0
      if (k == 0) { fg = "x"; bg = "x"; b = 0; it = 0; u = 0 }
      else if (k == 1) b = 1
      else if (k == 3) it = 1
      else if (k == 4) u = 1
      else if (k == 2 && fg == "x") fg = "a8"
      else if (k == 22) b = 0
      else if (k == 23) it = 0
      else if (k == 24) u = 0
      else if (k == 39) fg = "x"
      else if (k == 49) bg = "x"
      else if (k >= 30 && k <= 37) fg = "a" (k - 30)
      else if (k >= 90 && k <= 97) fg = "a" (k - 82)
      else if ((k == 38 || k == 48) && c[i + 1] == "2") {
        if (k == 38) fg = sprintf("%02x%02x%02x", c[i + 2], c[i + 3], c[i + 4])
        else bg = sprintf("%02x%02x%02x", c[i + 2], c[i + 3], c[i + 4])
        i += 4
      } else if ((k == 38 || k == 48) && c[i + 1] == "5") {
        if (k == 38) fg = md_x256(c[i + 2]); else bg = md_x256(c[i + 2])
        i += 2
      }
    }
  }
  print lead out
}

# md_ent: HTML's entities as the characters they stand for.
function md_ent(s) {
  gsub(/&nbsp;/, " ", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s)
  gsub(/&quot;/, "\"", s); gsub(/&amp;/, "\\&", s)
  return s
}
# md_untag: a line with its HTML tags gone, but not from code spans, where
# Promise<void> is code.
function md_untag(l,    seg, n, i, out) {
  n = split(l, seg, "`")
  for (i = 1; i <= n; i++) {
    if (i % 2) gsub(/<\/?[A-Za-z][^>]*>/, "", seg[i])
    out = out (i > 1 ? "`" : "") seg[i]
  }
  return md_ent(out)
}

function md(text, width, lead,    lines, n, i, l, para, fence, code, lang, blank, gap, m, indent) {
  if (md_fg == "") {
    # The theme's hues from the environment (otis-theme), else the terminal's.
    md_fg = md_sgr("TEXT", "39")
    md_att = md_sgr("ATTENTION", "33")
    md_ctx = md_sgr("CONTEXT", "90")
    md_mainc = md_sgr("MAIN", "34")
    md_linkc = "\033[4m" md_sgr("ELSEWHERE", "36")
    md_codec = md_att (ENVIRON["OTIS_T_CODEBG"] != "" ? "\033[" ENVIRON["OTIS_T_CODEBG"] "m" : "")
    md_battheme = ENVIRON["OTIS_T_BAT"] != "" ? ENVIRON["OTIS_T_BAT"] : "ansi"
    md_bat = system("command -v bat >/dev/null 2>&1") == 0
    "echo $$" | getline md_pid
    md_tmp = (ENVIRON["TMPDIR"] != "" ? ENVIRON["TMPDIR"] : "/tmp") "/gmr-md." md_pid
  }
  while ((i = index(text, "<!--")) && (m = index(substr(text, i), "-->")))
    text = substr(text, 1, i - 1) substr(text, i + m + 2)
  n = split(text, lines, "\037")
  para = ""; fence = 0; blank = 1; gap = 0
  for (i = 1; i <= n + 1; i++) {
    l = i <= n ? lines[i] : ""
    sub(/\r$/, "", l)
    if (fence) {
      if (l ~ /^ *```/ || i > n) { md_gap(gap, lead); md_fence(code, lang, lead); fence = 0; blank = 0; gap = 0 }
      else code = code md_ent(l) "\n"
      continue
    }
    if (l !~ /^ *```/) l = md_untag(l)
    # Anything but a plain line ends the paragraph so far.
    if (para != "" && (i > n || l ~ /^ *$/ || l ~ /^ *```/ || l ~ /^#+ / || l ~ /^ *([-*+]|[0-9]+[.)]) / || l ~ /^>/)) {
      md_gap(gap, lead); md_reset(); md_flow(para, width, lead, "", ""); para = ""; blank = 0; gap = 0
    }
    if (i > n) break
    if (l ~ /^ *```/) {
      lang = l; sub(/^ *```+ */, "", lang); sub(/[^A-Za-z0-9_+#-].*$/, "", lang)
      code = ""; fence = 1
    } else if (l ~ /^ *$/) {
      if (!blank) gap = 1
      blank = 1
    } else if (l ~ /^#+ /) {
      sub(/^#+ +/, "", l)
      md_gap(gap, lead); gap = 0
      md_reset(); md_bold = 1
      m = md_fg; md_fg = md_att; md_flow(l, width, lead, "", ""); md_fg = m
      blank = 0
    } else if (match(l, /^ *([-*+]|[0-9]+[.)]) /)) {
      m = substr(l, 1, RLENGTH); l = substr(l, RLENGTH + 1)
      match(m, /^ */); indent = substr(m, 1, RLENGTH)
      sub(/^ +/, "", m); sub(/ $/, "", m)
      if (m ~ /^[-*+]$/) m = "•"
      md_gap(gap, lead); gap = 0
      md_reset()
      md_flow(l, width, lead, indent md_ctx m " ", indent sprintf("%" (md_cols(m) + 1) "s", ""))
      blank = 0
    } else if (l ~ /^>/) {
      sub(/^> ?/, "", l)
      md_gap(gap, lead); gap = 0
      md_reset(); md_ital = 1
      md_flow(l, width - 2, lead, md_ctx "│ ", md_ctx "│ ")
      blank = 0
    } else {
      para = para (para == "" ? "" : " ") l
    }
  }
}
