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
  if [ -n "$OTIS_T_MINUS" ]; then
    set -- --minus-style "syntax $OTIS_T_MINUS" --plus-style "syntax $OTIS_T_PLUS" \
      --minus-emph-style "syntax $OTIS_T_MINUS_EMPH" --plus-emph-style "syntax $OTIS_T_PLUS_EMPH" "$@"
  fi
  [ -n "$OTIS_T_LIGHT" ] && set -- --light "$@"
  delta --no-gitconfig --paging=never --width="$w" \
    --syntax-theme="${OTIS_T_DELTA_SYNTAX:-ansi}" \
    --hunk-header-style 'line-number syntax' \
    --hunk-header-decoration-style "${OTIS_T_RULE:-8} box" \
    --line-numbers "$@"
}
