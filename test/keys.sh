#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- otis-keys only names keys its picker declares: a key renamed in one and
# not the other labels a key that does nothing, or leaves one unlabelled.
# A picker whose keys the forge can trim (git-forge lacks) names them in
# keys='...' just above its git-fzf '<prompt> ' "$keys".
declared() {
  sed "s/'\"'\"'//g" "$share/otis.zsh" | awk -v p="git-fzf '$1 '" '
    /keys='"'"'/ { k = $0; sub(/.*keys='"'"'/, "", k); sub(/'"'"'.*/, "", k) }
    index($0, p " '"'"'") { v = substr($0, index($0, p " '"'"'") + length(p) + 2); sub(/'"'"'.*/, "", v); print v; next }
    index($0, p " \"$keys\"") { print k }' | tr ',' '\n' | sed 's/=.*//' | sort -u
}
undeclared() {
  picker=$1; shift
  declared "$picker" > "$tmp/declared"
  for row in "$@"; do eval "GIT_FZF_STATE=/nonexistent otis-keys $row" 2>/dev/null; done | cut -f1 | sort -u | comm -23 - "$tmp/declared" | tr '\n' ' '
}
expect keys/branch "$(undeclared branch 'branch b main here "" ""' 'branch b merged worktree "" 7' 'branch b open "" "" ""')" ""

