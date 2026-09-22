# in_root: whether $PWD is in the checkout at $OTIS_C_ROOT, the one the
# environment's settings (otis-config --env) were worked out for. Under it
# is not enough: a worktree can sit inside the main checkout (Claude's, under
# .claude/worktrees), and there the main checkout's top, HEAD and settings are
# not its own. So no directory from $PWD up to the root, the root aside, may
# have a .git of its own. Builtins alone, for sh and zsh alike: every picker
# and list asks it.
in_root() {
  [ -n "$OTIS_C_ROOT" ] || return 1
  case $PWD in "$OTIS_C_ROOT") return 0 ;; "$OTIS_C_ROOT"/*) ;; *) return 1 ;; esac
  _d=$PWD
  while [ "$_d" != "$OTIS_C_ROOT" ]; do
    [ -e "$_d/.git" ] && return 1
    _d=${_d%/*}
  done
  return 0
}
