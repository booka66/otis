# joblog.sh: a CI job's log, read for a preview: . "$share/joblog.sh" after
# pane.sh. git-ci-log's --tail (a job in gmr's c) and git-deploy-preview (a
# failed deploy in gd) draw the same three things from it: what broke, where
# the time went, and the end of it with the errors lit.

# joblog_clean <sections file>: GitLab's raw trace on stdin, cleaned on
# stdout: its per-line timestamps and stream tags, section markers and
# carriage-return redraws stripped, and partial lines it split joined back.
# The sections' start and end times, which the markers carry, go to the
# file first, as "start|end <tab> epoch <tab> name" lines.
joblog_clean() {
  perl -0e '
    open(my $s, ">", $ARGV[0]) or die;
    local $/; $_ = <STDIN>;
    while (/section_(start|end):(\d+):([A-Za-z0-9_.\-]+)/g) { print $s "$1\t$2\t$3\n" }
    close $s;
    s/\n[^\n]*?Z [0-9a-f]{2}[OE]\+//g; s/^\d{4}-\d\d-\d\dT[\d:.]+Z [0-9a-f]{2}[OE] ?//mg;
    s/section_(start|end):\d+:[^\r\n]*\r?//g; s/\e\[0K//g;
    s/[^\r\n]*\r(?=[^\r\n])//g; s/\r//g;
    print' "$1"
}

# joblog_broke <log>: what broke, as best the log says: a count, then up to
# four "title <tab> detail <tab> where" lines. Jest's and Vitest's failed
# tests first, then Bazel's failed targets, TypeScript's errors, and last
# any line saying error, nearest the end. Nothing found: 0.
joblog_broke() {
  LC_ALL=C awk '
    function plain(s) { gsub(/\033\[[0-9;?]*[A-Za-z]/, "", s); gsub(/\t/, " ", s); return s }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function add(kind, i, t) { t = trim(t); if (t == "" || seen[kind, t]++) return; nk[kind]++; at[kind, nk[kind]] = i; tt[kind, nk[kind]] = t }
    { L[++n] = plain($0) }
    END {
      for (i = 1; i <= n; i++) {
        s = L[i]
        if (s ~ /^[ \t]*\342\227\217 / && s !~ /\342\227\217 (Console|Test suite failed to run)/) { t = s; sub(/^[ \t]*\342\227\217 /, "", t); add(1, i, t) }
        else if (s ~ /^[ \t]*FAIL[ \t]+[^ ]+ > /) { t = s; sub(/^[ \t]*FAIL[ \t]+[^ ]+ > /, "", t); add(2, i, t) }
        else if (s ~ /^[ \t]*(\342\234\225|\303\227) /) { t = s; sub(/^[ \t]*(\342\234\225|\303\227) /, "", t); sub(/ \([0-9.]+ ?m?s\)$/, "", t); add(3, i, t) }
        else if (s ~ /^\/\/[^ ]+ +(FAILED|TIMEOUT|NO STATUS)/) { t = s; sub(/ +(FAILED|TIMEOUT|NO STATUS).*/, "", t); add(4, i, t) }
        else if (s ~ /error TS[0-9]+:/) { t = s; sub(/.*error TS[0-9]+: */, "", t); add(5, i, t) }
        else if (s ~ /(^|[^A-Za-z])(ERROR|Error|error)(:| )/ && s !~ /Job failed|0 errors|--no-error/) { add(6, i, s) }
      }
      for (k = 1; k <= 6; k++) if (nk[k]) break
      if (k > 6) { print 0; exit }
      print nk[k]
      from = 1; if (k == 6 && nk[k] > 3) from = nk[k] - 2
      for (j = from; j <= nk[k] && j < from + 4; j++) {
        i = at[k, j]; detail = ""; where = ""; ex = ""; rc = ""
        if (k == 4) { detail = L[i]; sub(/^[^ ]+ +/, "", detail) }
        if (k == 5 && match(L[i], /[A-Za-z0-9_.\/-]+\.[a-z]+[(:][0-9]+/)) { where = substr(L[i], RSTART, RLENGTH); sub(/\(/, ":", where) }
        for (m = i + 1; m <= n && m <= i + 20 && k <= 3; m++) {
          s = L[m]
          if (s ~ /^[ \t]*\342\227\217 / || s ~ /^[ \t]*(\342\234\225|\303\227) /) break
          if (ex == "" && s ~ /Expected:/) { ex = s; sub(/.*Expected:/, "", ex); ex = trim(ex) }
          else if (rc == "" && s ~ /Received:/) { rc = s; sub(/.*Received:/, "", rc); rc = trim(rc) }
          else if (detail == "" && s ~ /(Error|error|expected|Timeout|timed out|Exceeded)/) detail = trim(s)
          if (where == "" && s !~ /node_modules/ && match(s, /[A-Za-z0-9_.\/-]+\.(ts|tsx|js|jsx|mjs|cjs|py|go|rb|rs|java|kt|sh):[0-9]+/)) where = substr(s, RSTART, RLENGTH)
        }
        if (ex != "" && rc != "") detail = "expected " ex ", received " rc
        print tt[k, j] "\t" detail "\t" where
      }
    }'
}

# joblog_show_broke <broke output> <color of the ✗>: its lines as a pane
# section's, each thing that broke with what it said and where, indented.
joblog_show_broke() {
  sep=
  printf '%s\n' "$1" | sed 1d | while IFS='	' read -r t d w; do
    [ -n "$t" ] || continue
    printf '%s' "$sep"; sep='
'
    printf "  ${GK_BAD}✗ ${GK_TEXT}%s${GK_R}\n" "$(pane_fit "$t" $((PANE_W - 4)))"
    [ -n "$d" ] && printf "      ${GK_CONTEXT}%s${GK_R}\n" "$(pane_fit "$d" $((PANE_W - 6)))"
    [ -n "$w" ] && printf "      ${GK_ELSEWHERE}%s${GK_R}\n" "$(pane_fit "$w" $((PANE_W - 6)))"
  done
}

# joblog_said <broke output>: what broke, in a line, for a callout.
joblog_said() {
  printf '%s\n' "$1" | awk -F'\t' '
    NR == 1 { n = $1 + 0; next }
    { f = $3; sub(/:[0-9]+$/, "", f); sub(/.*\//, "", f); files[f]++; nf += (f != ""); if (first == "") first = $1 }
    END {
      if (!n) { print "The end of its log is below."; exit }
      one = 1; for (x in files) cnt++; if (cnt != 1 || nf < NR - 1) one = 0
      for (x in files) file = x
      if (n == 1) print "It broke on: " first
      else if (one) print n " things broke, all in " file "."
      else print n " things broke; the first: " first
    }'
}

# joblog_times <sections file> <outcome color>: where the time went, a bar
# a step on one timeline, the script's own in the color of how it ended.
# Nothing when the log had fewer than two steps.
joblog_times() {
  [ -s "$1" ] || return 0
  pane_color "$2"
  LC_ALL=C awk -F'\t' -v w="$PANE_W" -v S="$(printf "$GK_CONTEXT")" -v B="$(printf "$GK_MAIN")" -v O="$(printf "$PANE_C")" \
      -v F="$(printf "$GK_FAINT")" -v R="$(printf "$GK_R")" '
    function nice(n) {
      if (n ~ /^prepare_(executor|script)$/) return "prepare"
      if (n == "get_sources") return "sources"
      if (n == "restore_cache") return "cache in"
      if (n == "download_artifacts") return "artifacts in"
      if (n ~ /^(step|build)_script$/) return "script"
      if (n == "after_script") return "after"
      if (n == "archive_cache" || n == "archive_cache_on_failure") return "cache out"
      if (n ~ /^upload_artifacts/) return "artifacts out"
      gsub(/_/, " ", n); return n
    }
    function took(s) { return s < 60 ? s "s" : int(s / 60) "m " (s % 60 < 10 ? "0" : "") s % 60 "s" }
    $1 == "start" && !($3 in a) { a[$3] = $2; ord[++n] = $3 }
    $1 == "end" { z[$3] = $2 }
    END {
      k = 0
      for (i = 1; i <= n; i++) { x = ord[i]; if (!(x in z) || x ~ /^cleanup/) continue; d = z[x] - a[x]; if (d < 1) continue
        k++; nm[k] = nice(x); st[k] = a[x]; du[k] = d; raw[k] = x
        if (!lo || a[x] < lo) lo = a[x]; if (z[x] > hi) hi = z[x] }
      if (k < 2 || hi <= lo) exit
      # The longest six, in the order they ran.
      if (k > 6) { for (i = 1; i <= k; i++) { r = 0; for (j = 1; j <= k; j++) if (du[j] > du[i] || (du[j] == du[i] && j < i)) r++; keep[i] = r < 6 } }
      else for (i = 1; i <= k; i++) keep[i] = 1
      bw = w - 2 - 14 - 9; if (bw < 10) bw = 10
      for (i = 1; i <= k; i++) {
        if (!keep[i]) continue
        off = int((st[i] - lo) * bw / (hi - lo)); len = int(du[i] * bw / (hi - lo) + 0.5); if (len < 1) len = 1
        if (off + len > bw) off = bw - len
        c = raw[i] ~ /^(step|build)_script$/ ? O : B
        bar = ""; for (j = 0; j < off; j++) bar = bar " "; bar = bar c; for (j = 0; j < len; j++) bar = bar "\342\224\201"
        pad = ""; for (j = off + len; j < bw; j++) pad = pad " "
        printf "  %s%-13.13s%s %s%s%s%s%8s%s\n", S, nm[i], R, bar, R, pad, S, took(du[i]), R
      }
    }' "$1"
}

# joblog_tail <log> <rows>: its last rows (blank ones aside), numbered
# faint, a line that errors lit, each cut to the pane.
joblog_tail() {
  LC_ALL=C awk -v rows="$2" -v w="$PANE_W" -v X="$(printf "$GK_BAD")" -v C="$(printf "$GK_CONTEXT")" \
      -v F="$(printf "$GK_FAINT")" -v R="$(printf "$GK_R")" '
    function plain(s) { gsub(/\033\[[0-9;?]*[A-Za-z]/, "", s); gsub(/\t/, "    ", s); gsub(/[\001-\037\177]/, "", s); return s }
    # Columns, not bytes: a character is its first byte and the ones after.
    function ulen(s,   t) { t = s; return length(s) - gsub(/[\200-\277]/, "", t) }
    function ucut(s, w,   out, i, c, n) {
      n = 0; out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c !~ /[\200-\277]/ && ++n > w) break; out = out c }
      return out
    }
    { s = plain($0); if (s ~ /^[ \t]*$/) next; k++; num[k] = NR; txt[k] = s }
    END {
      from = k - rows + 1; if (from < 1) from = 1
      nw = length(num[k] "")
      for (i = from; i <= k; i++) {
        s = txt[i]; lo = tolower(s)
        bad = lo ~ /(error|fail|panic|exception|fatal|\342\234\225|\303\227)/ && lo !~ /(0 failed|0 errors|no errors)/
        room = w - 2 - nw - 3
        if (ulen(s) > room) s = ucut(s, room - 1) "\342\200\246"
        printf "  %s%*d \342\224\202 %s%s%s\n", F, nw, num[i], (bad ? X : C), s, R
      }
    }' "$1"
}
