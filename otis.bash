# Sourced from ~/.bashrc (otis-setup says how). The commands are programs in
# bin/, which goes on PATH here; this file is what only the shell can do: the gs
# alias, and following a picker that moves you (git.zsh says how). The
# prompt hooks (background fetch, ahead/behind, alerts, the worktree sweep)
# are zsh's alone for now.
OTIS_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case ":$PATH:" in *":$OTIS_HOME/bin:"*) ;; *) PATH=$OTIS_HOME/bin:$PATH ;; esac

# An alias or a function named like an otis command would win over it.
for _otis_c in "$OTIS_HOME"/bin/*; do
  [ -L "$_otis_c" ] || continue
  _otis_c=${_otis_c##*/}
  unalias "$_otis_c" 2>/dev/null
  unset -f "$_otis_c" 2>/dev/null
done
unset _otis_c

alias gs='git status'

# The theme (otis-theme), once, here: it is a property of your terminal rather
# than of a repo, and every otis command inherits it instead of working it out
# again. otis-theme below puts a newly picked one into this shell, so it takes
# without opening a new one.
[ -n "$OTIS_T_NAME" ] || eval "$(otis-theme --env)"
otis-theme() {
  command otis-theme "$@" || return
  case $1 in -*) ;; *) eval "$(command otis-theme --env)" ;; esac
}

_otis_cd() {
  local f rc
  f=$(mktemp -t otis-cd.XXXXXX) || return
  OTIS_CD=$f command "$@"
  rc=$?
  [ -s "$f" ] && cd -- "$(cat "$f")"
  rm -f -- "$f"
  return $rc
}
gb()   { _otis_cd gb "$@"; }
gw()   { _otis_cd gw "$@"; }
gwn()  { _otis_cd gwn "$@"; }
gmr()  { _otis_cd gmr "$@"; }
gci()  { _otis_cd gci "$@"; }
otis() { _otis_cd otis "$@"; }
