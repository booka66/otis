# Your branch and origin's copy of it (GitLab's): which of the two has moved,
# by where each has been here (its reflog): . "$share/origin-copy.sh".
# Either can be rewritten, by a rebase or an amend here or a push from another
# checkout or an agent, so neither being in the other's history says nothing
# about which is newer; a branch that was once at the other's commit and has
# moved off it is. Shared by git-mr-rebase and git-mr-mine.

# was_at <ref> <commit>: that ref has been at that commit, by its reflog here.
was_at() { git log -g --format=%H "$1" 2>/dev/null | grep -qx "$2"; }
# behind <branch> <yours> <GitLab's>: your branch has nothing of its own, so
# it follows GitLab's with nothing lost. Its commit is in GitLab's, or is one
# GitLab's branch was at before it was rewritten there (a push from another
# checkout, or from an agent, leaves yours on the old copy). Not when yours
# has commits past GitLab's, or has been at GitLab's commit and moved off it:
# then the difference is yours.
behind() {
  git merge-base --is-ancestor "$2" "$3" 2>/dev/null && return
  git merge-base --is-ancestor "$3" "$2" 2>/dev/null && return 1
  was_at "refs/remotes/origin/$1" "$2" && ! was_at "refs/heads/$1" "$3"
}
