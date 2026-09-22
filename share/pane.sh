# pane.sh: how a preview speaks, for the sh ones: . "$share/pane.sh" after
# palette.sh. Every preview answers three things in order, and stops:
#
#   what wants you   pane_callout: a bar in the color of how urgent it is,
#                    what it is in bold, a line of why, and the key that acts.
#                    Only when something does.
#   what it is       pane_title in bold, then pane_meta: one faint line of
#                    where and when. Never a list of key: value.
#   how it stands    pane_section: a heading in capitals, its count in the
#                    color of what it says, then its lines, indented two.
#                    A proportion is a bar (pane_bar), never a number alone.
#
# The colors say one thing each: yours (it waits on you), bad (broken),
# good (done), attention (going, and ids and keys). The glyphs likewise:
# ✓ done  ◐ going  ○ waiting  ✗ broken  ! yours to do  ● a thing  · nothing.
# One thought a line, cut with … to the pane (pane_fit), never wrapped
# mid-word; what matters first, so a short pane loses the tail, not the point.
#
# The pane's width is $FZF_PREVIEW_COLUMNS (the picker sets it); PANE_W is it
# less a column, for a line's text.
# Its helpers keep to variables named _pn_*, so a script sourcing it keeps its own.
PANE_W=$(( ${FZF_PREVIEW_COLUMNS:-80} - 1 ))
[ "$PANE_W" -gt 20 ] || PANE_W=20

# pane_color <name>: the escape for good, bad, yours, attention, text,
# context, faint, elsewhere or main, in PANE_C (printf's escape form).
pane_color() {
  case $1 in
    good) PANE_C=$GK_GOOD ;; bad) PANE_C=$GK_BAD ;; yours) PANE_C=$GK_YOURS ;;
    attention) PANE_C=$GK_ATTENTION ;; context) PANE_C=$GK_CONTEXT ;; faint) PANE_C=$GK_FAINT ;;
    elsewhere) PANE_C=$GK_ELSEWHERE ;; main) PANE_C=$GK_MAIN ;; *) PANE_C=$GK_TEXT ;;
  esac
}

# PANE_AWK: ulen(s), the columns plain text takes, and ufit(s, w), it cut to
# w columns with an ellipsis, a character at a time: an awk that counts
# bytes (macOS's, or any under LC_ALL=C) split a character in two and cut
# the line short. For an awk run LC_ALL=C, so every awk counts the same.
PANE_AWK='
function ulen(s,   t) { t = s; return length(s) - gsub(/[\200-\277]/, "", t) }
function ufit(s, w,   i, n, L) {
  if (ulen(s) <= w) return s
  L = length(s); n = 0
  for (i = 1; i <= L; i++) if (substr(s, i, 1) !~ /[\200-\277]/ && ++n > w - 1) break
  return substr(s, 1, i - 1) "\342\200\246"
}'

# pane_fit <text> [width]: plain text cut to the width with an ellipsis.
pane_fit() {
  # No process for what fits already, nearly every line: its length in
  # bytes is at least its length in characters.
  if [ "${#1}" -le "${2:-$PANE_W}" ]; then printf '%s\n' "$1"; return; fi
  printf '%s' "$1" | LC_ALL=C awk -v w="${2:-$PANE_W}" "$PANE_AWK"'{ print ufit($0, w) }'
}

# pane_callout <color> <head> [<line>...]: what wants you. A line may hold
# colors already (printf %b); a line "keys:⏎ open it · r resolve" is keys,
# each first word lit.
pane_callout() {
  pane_color "$1"; _pn_c=$PANE_C; shift
  printf "${_pn_c}▌ \033[1m%s${GK_R}\n" "$(pane_fit "$1" $((PANE_W - 2)))"; shift
  for _pn_l in "$@"; do
    case $_pn_l in
      # The keys are the footer's to say, for the row and the screen it is
      # on: a preview is shown under more than one, so it names none.
      keys:*) ;;
      *)
        _pn_p=$(printf '%b' "$_pn_l" | sed 's/\[[0-9;:]*m//g')
        if [ "${#_pn_p}" -le $((PANE_W - 2)) ]; then printf "${_pn_c}▌ ${GK_R}%b\n" "$_pn_l"
        else
          # Too long for a line: wrapped, to three at most, in its own color.
          case $_pn_l in "\033["*m*) _pn_k=${_pn_l%%m*}m ;; *) _pn_k=$GK_TEXT ;; esac
          printf '%s' "$_pn_p" | tr '\n' ' ' | LC_ALL=C awk -v w=$((PANE_W - 2)) -v most=3 -v b="$(printf "${_pn_c}▌ ${GK_R}${_pn_k}")" -v r="$(printf "$GK_R")" "$PANE_AWK"'
            { n = split($0, ws, " "); line = ""; k = 0
              for (i = 1; i <= n; i++) {
                if (line != "" && ulen(line " " ws[i]) > w) {
                  if (++k == most) { print b ufit(line " …", w) r; exit }
                  print b line r; line = ws[i]
                } else line = line (line == "" ? "" : " ") ws[i] }
              if (line != "") print b ufit(line, w) r }'
        fi ;;
    esac
  done
  echo
}

# pane_wrap <text> [color] [lines]: a sentence that matters, indented two,
# broken between words over at most that many lines (2), the last cut
# with … when there is more: never one line cut at the pane's edge.
pane_wrap() {
  pane_color "${2:-text}"
  printf '%s' "$1" | tr '\n' ' ' | LC_ALL=C awk -v w=$((PANE_W - 2)) -v most="${3:-2}" -v t="$(printf "$PANE_C")" -v r="$(printf "$GK_R")" "$PANE_AWK"'
    { n = split($0, ws, " "); line = ""; k = 0
      for (i = 1; i <= n; i++) {
        if (line != "" && ulen(line " " ws[i]) > w) {
          if (++k == most) { for (j = i; j <= n; j++) line = line " " ws[j]; print "  " t ufit(line, w) r; exit }
          print "  " t line r; line = ws[i]
        } else line = line (line == "" ? "" : " ") ws[i] }
      if (line != "") print "  " t ufit(line, w) r }'
}

pane_title() { printf "${GK_TEXT}\033[1m%s${GK_R}\n" "$(pane_fit "$1")"; }
# pane_meta <part>...: the parts, faint, a " · " between.
pane_meta() {
  _pn_out= _pn_sep=
  for _pn_p in "$@"; do [ -n "$_pn_p" ] && { _pn_out="$_pn_out$_pn_sep$_pn_p"; _pn_sep="  ·  "; }; done
  printf "${GK_CONTEXT}%s${GK_R}\n" "$(pane_fit "$_pn_out")"
}

# pane_section <NAME> [<count> <color>] [<aside>]: a heading, a blank line
# before it and after.
pane_section() {
  _pn_p=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  printf "\n${GK_CONTEXT}%s${GK_R}" "$_pn_p"
  # What fits after it: the count, cut if it must be, and the aside only
  # when there is room for the whole of it.
  _pn_n=$((PANE_W - ${#_pn_p} - 2))
  if [ -n "$2" ] && [ "$_pn_n" -gt 4 ]; then
    pane_color "${3:-text}"; printf "  ${PANE_C}%s${GK_R}" "$(pane_fit "$2" "$_pn_n")"
    _pn_n=$((_pn_n - ${#2} - 2))
  fi
  [ -n "$4" ] && [ "${#4}" -le "$_pn_n" ] && printf "  ${GK_FAINT}%s${GK_R}" "$4"
  printf '\n\n'
}

# pane_bar <n> <of> <width> <color> [rest]: n of of as a bar that many
# columns wide, printed without a newline; rest is what fills the remainder
# (─ faint by default, " " for none).
pane_bar() {
  _pn_n=$1 _pn_of=$2 _pn_w=$3; pane_color "$4"
  _pn_k=0; [ "$_pn_of" -gt 0 ] && _pn_k=$(( (_pn_n * _pn_w + _pn_of / 2) / _pn_of ))
  [ "$_pn_n" -gt 0 ] && [ "$_pn_k" -eq 0 ] && _pn_k=1
  [ "$_pn_k" -gt "$_pn_w" ] && _pn_k=$_pn_w
  _pn_fill=${5:-─}
  # Built in the shell: two awks a bar were most of what a preview cost.
  _pn_on= _pn_off= _pn_i=0
  while [ "$_pn_i" -lt "$_pn_k" ]; do _pn_on="${_pn_on}━"; _pn_i=$((_pn_i + 1)); done
  while [ "$_pn_i" -lt "$_pn_w" ]; do _pn_off="${_pn_off}${_pn_fill}"; _pn_i=$((_pn_i + 1)); done
  printf "${PANE_C}%s${GK_FAINT}%s${GK_R}" "$_pn_on" "$_pn_off"
}

# pane_keys: nothing. The footer says what the keys do, for the row and the
# screen it is on; a preview, shown under more than one, names none.
pane_keys() { :; }

# pane_hang <lead> <lead's columns> <color> <lines> <text> [tail]: the text
# after a lead (a glyph and an id, colors and all), wrapped under itself to
# at most that many lines, the tail (a state, colored) after the first.
pane_hang() {
  pane_color "$3"
  printf '%s' "$5" | tr '\n\t' '  ' | LC_ALL=C awk -v w=$((PANE_W - $2 - ${#6} - 1)) -v most="$4" -v ind="$2" \
    -v lead="$(printf '%b' "$1")" -v t="$(printf "$PANE_C")" -v r="$(printf "$GK_R")" -v tail="$(printf '%b' "$6")" "$PANE_AWK"'
    function emit(s) { if (k == 0) printf "%s%s%s%s", lead, t, s, r; else printf "%" ind "s%s%s%s", "", t, s, r
      if (k == 0 && tail != "") printf "%" (w - ulen(s) + 1) "s%s%s", "", tail, r
      printf "\n"; k++ }
    { n = split($0, ws, " "); line = ""; k = 0
      for (i = 1; i <= n; i++) {
        if (line != "" && ulen(line " " ws[i]) > w) {
          if (k + 1 == most) { emit(ufit(line " …", w)); exit }
          emit(line); line = ws[i]
        } else line = line (line == "" ? "" : " ") ws[i] }
      if (line != "") emit(ufit(line, w)) }'
}
