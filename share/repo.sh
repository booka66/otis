# repo.sh: where this repo keeps what otis leaves in it, as $OTIS_GITDIR.
#
# Nearly every script here wants the git dir: the caches, the MR state, the
# records of Claude's runs and the worktree notes all live under it. Asked for
# with git rev-parse it costs a process, about 7ms whatever it is asked, and a
# picker asks for it once in its list and again in every preview and binding,
# which is time spent finding out something that cannot have changed.
#
# So git-fzf works it out once (otis-config --env) and exports it, and a
# script sources this instead of asking. The common dir, so every worktree
# shares it, as they share the repo it belongs to.
#
# The exported one is only believed while we are still inside the checkout it
# was worked out for, since it is inherited by everything a picker starts:
# somewhere else, as in one of otis-tour's made-up repos, it is worked out
# again here. A worktree outside the checkout (otis.worktrees somewhere else)
# lands there too, and is right, just not free.
OTIS_GITDIR=
if [ -n "$OTIS_C_GITDIR" ] && [ -n "$OTIS_C_ROOT" ]; then
  case $PWD in
    "$OTIS_C_ROOT" | "$OTIS_C_ROOT"/*) OTIS_GITDIR=$OTIS_C_GITDIR ;;
  esac
fi
[ -n "$OTIS_GITDIR" ] || OTIS_GITDIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[ -n "$OTIS_GITDIR" ]
