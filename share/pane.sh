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

# pane_fit <text> [width]: plain text cut to the width with an ellipsis.
pane_fit() {
  printf '%s' "$1" | awk -v w="${2:-$PANE_W}" '{ if (length($0) > w) $0 = substr($0, 1, w - 1) "…"; print }'
}

# pane_callout <color> <head> [<line>...]: what wants you. A line may hold
# colors already (printf %b); a line "keys:⏎ open it · r resolve" is keys,
# each first word lit.
pane_callout() {
  pane_color "$1"; _pn_c=$PANE_C; shift
  printf "${_pn_c}▌ \033[1m%s${GK_R}\n" "$(pane_fit "$1" $((PANE_W - 2)))"; shift
  for _pn_l in "$@"; do
    case $_pn_l in
      keys:*)
        printf "${_pn_c}▌ ${GK_R}"
        printf '%s' "${_pn_l#keys:}" | awk -v a="$(printf "$GK_ATTENTION")" -v x="$(printf "$GK_CONTEXT")" -v r="$(printf "$GK_R")" '
          { n = split($0, ks, " · "); out = ""
            for (i = 1; i <= n; i++) { k = ks[i]; sp = index(k, " ")
              out = out (i > 1 ? "    " : "") a (sp ? substr(k, 1, sp - 1) : k) r x (sp ? substr(k, sp) : "") r }
            print out }' ;;
      *) printf "${_pn_c}▌ ${GK_R}%b\n" "$_pn_l" ;;
    esac
  done
  echo
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
  printf "\n${GK_CONTEXT}%s${GK_R}" "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [ -n "$2" ]; then pane_color "${3:-text}"; printf "  ${PANE_C}%s${GK_R}" "$2"; fi
  [ -n "$4" ] && printf "  ${GK_FAINT}%s${GK_R}" "$4"
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
  printf "${PANE_C}%s${GK_FAINT}%s${GK_R}" "$(awk -v k="$_pn_k" 'BEGIN { while (k-- > 0) printf "━" }')" \
    "$(awk -v k=$((_pn_w - _pn_k)) -v f="$_pn_fill" 'BEGIN { while (k-- > 0) printf "%s", f }')"
}

# pane_keys <key label>...: the keys that act, last and faint.
pane_keys() {
  _pn_out= _pn_sep=
  for _pn_k in "$@"; do _pn_out="$_pn_out$_pn_sep$_pn_k"; _pn_sep="  ·  "; done
  printf "\n${GK_FAINT}  %s${GK_R}\n" "$(pane_fit "$_pn_out" $((PANE_W - 2)))"
}
