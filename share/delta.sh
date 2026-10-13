# gk_delta [<delta options>]: a diff on stdin through delta, the way every
# otis preview shows one: . "$share/delta.sh", then ... | gk_delta. bin/git-delta
# is this for a caller that is not sh; a preview that runs on every cursor
# move sources it instead, since a shell started only to build delta's
# arguments cost a third of what delta itself does.
#
# In the theme's colors (otis-theme) and otis's own settings rather than your
# gitconfig's (--no-gitconfig), so previews match the rest of otis. A theme
# without diff grounds (the terminal's) keeps delta's own, for a light ground
# where it says light.
#
# One column, with each hunk headed by the line number and the function it is
# in, boxed, so a diff deep in a file says where you are. Side by side instead
# with otis.sideBySide always (or auto, which does it from 120 columns, where
# two columns are still readable). The setting comes from the environment
# under a picker (otis-config --env, loaded by git-fzf); the lookup is for a
# run from anywhere else.
gk_delta() {
  w=${FZF_PREVIEW_COLUMNS:-100}
  sides=
  if [ -n "$OTIS_C_ROOT" ]; then sb=${OTIS_C_sideBySide-}; else sb=$(otis-config sideBySide 2>/dev/null); fi
  case $sb in
    always) sides=--side-by-side ;;
    auto) [ "$w" -ge 120 ] && sides=--side-by-side ;;
  esac
  # A caller's own --file-style (git-preview-file omits the header) replaces
  # this one; delta refuses the same option twice.
  case " $* " in
    *" --file-style"*) ;;
    *) set -- --file-style "${OTIS_T_FILE:-6}" --file-decoration-style "${OTIS_T_RULE:-8} ul" "$@" ;;
  esac
  [ -n "$sides" ] && set -- --side-by-side "$@"
  [ -n "$OTIS_T_LIGHT" ] && set -- --light "$@"
  set -- --no-gitconfig --paging=never --width="$w" \
    --syntax-theme="${OTIS_T_DELTA_SYNTAX:-ansi}" \
    --hunk-header-style 'line-number syntax' \
    --hunk-header-decoration-style "${OTIS_T_RULE:-8} box" \
    --line-numbers "$@"
  # No grounds of the theme's: delta's own, which leave removed lines uncolored.
  [ -n "$OTIS_T_MINUS" ] || { delta "$@"; return; }
  # delta colors a hunk's code as one text, a block's removed lines and then
  # its added ones, as if both were there: "export function old({" removed
  # and "export function new({" added leave it two deep in a function's
  # parameters, and every keyword from there to the hunk's end is plain. So
  # two passes at once, each with one side's lines kept from the colorer (a
  # style with no "syntax" in it is), which then reads the other side as the
  # file has it: the removed lines are taken from the pass that colored them
  # and the rest from the other. Side by side a row is both, so each pass
  # draws the bar that starts its right half as a mark, and a row is cut
  # there. In the bar's place, since delta counts a mark beside it as a column.
  gk_in=$(cat)
  [ -n "$gk_in" ] || return 0
  [ -n "$sides" ] && set -- --line-numbers-right-format "$(printf '\037'){np:^4}│" "$@"
  printf '%s\n' "$gk_in" | delta --minus-style "normal $OTIS_T_MINUS" --minus-emph-style "normal $OTIS_T_MINUS_EMPH" \
    --plus-style "syntax $OTIS_T_PLUS" --plus-emph-style "syntax $OTIS_T_PLUS_EMPH" "$@" | {
    exec 3<&0
    printf '%s\n' "$gk_in" | delta --minus-style "syntax $OTIS_T_MINUS" --minus-emph-style "syntax $OTIS_T_MINUS_EMPH" \
      --plus-style "normal $OTIS_T_PLUS" --plus-emph-style "normal $OTIS_T_PLUS_EMPH" "$@" 3<&- |
      awk -v sides="$sides" '{
        old = $0
        if ((getline new < "/dev/fd/3") <= 0) new = old
        if (sides != "") {
          i = index(old, "\037"); j = index(new, "\037")
          print (i && j) ? substr(old, 1, i - 1) "│" substr(new, j + 1) : new
          next
        }
        if (old != new) {
          # A removed line has its number in the first column and none in the second.
          v = new; gsub(/\033\[[0-9;]*[mK]/, "", v)
          if (v ~ /^ *[0-9]+ *⋮ +│/) { print old; next }
        }
        print new
      }'
  }
}
