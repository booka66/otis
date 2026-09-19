# Shared by git-mr-fix (Claude's fix runs and their picker) and git-mr-fold
# (taking the fixes into your branch): where a run's files live under $key,
# and the helpers both use. Sourced with $key and $share set.
# The state key is what everything is filed under; the label is what you are
# shown. An MR is its iid; a branch is b-<name>, slashes as %, which can never
# collide with an iid and which --marks skips, since only MRs have rows in gmr.
# A third kind, v-<verification key>, is a run on your checkout from a
# verification's retrospective (git-verify-run): what it recommended changing
# in the repo, as proposals. Its label names the verification.
label_of() { case $1 in v-*) printf 'the retrospective of %s' "$(label_of "${1#v-}")" ;; b-*) printf '%s' "${1#b-}" | tr '%' '/' ;; *) printf '!%s' "$1" ;; esac; }
. "$share/repo.sh"
common=$OTIS_GITDIR
case $key in
  v-*) kind=retro;  label=$(label_of "$key"); iid=; retro_of=$common/otis-verify/${key#v-} ;;
  b-*) kind=branch; label=$(printf '%s' "${key#b-}" | tr '%' '/'); iid= ;;
  *)   kind=mr;     label="!$key"; iid=$key ;;
esac
top=$common/gmr-fix
d=$top/$key

. "$share/claude-run.sh"
nn() { printf '%02d' "$1"; }

# waiting_in <run dir>: the proposals in it still waiting on you, one number a
# line. Four things take one out: folding it into your commits (F), applying it
# to your checkout (a), taking it onto a branch of its own (B), and discarding
# it (d). This is the one place that says so, since a way left out here is a
# row in gmr, gb and otis that nothing can ever clear.
waiting_in() {
  for p in "$1"/[0-9][0-9].patch; do
    [ -s "$p" ] || continue
    n=${p##*/}; n=${n%.patch}; n=${n#0}
    grep -qx "$n" "$1/folded" "$1/applied" "$1/branched" "$1/declined" 2>/dev/null || printf '%s\n' "$n"
  done
}
# The patch a proposal stands for: the hunks you kept, else all of it.
patch_of() { if [ -s "$d/$(nn "$1").kept.patch" ]; then echo "$d/$(nn "$1").kept.patch"; else echo "$d/$(nn "$1").patch"; fi; }

# target <patch> <base> [<rev>]: the commit to fold it into, or nothing for a
# new commit. Of the lines each hunk changes (for a pure insertion, the line it
# goes after), the commits of base..rev that last touched them; the newest.
# rev is HEAD, or for a fix made on top of others, a commit with those in it.
target() {
  mine=$(git rev-list "$2..${3:-HEAD}")
  awk '
    /^diff --git / { file = ""; next }
    /^--- a\// { file = substr($0, 7); next }
    /^--- \/dev\/null/ { file = ""; next }
    /^@@ / && file != "" {
      split($2, old, ","); start = substr(old[1], 2); count = old[2] == "" ? 1 : old[2]
      if (count == 0) { if (start == 0) next; count = 1 }
      print file "\t" start "\t" count
    }' "$1" | while IFS="$(printf '\t')" read -r file start count; do
    git blame --porcelain -L "$start,+$count" "${3:-HEAD}" -- "$file" 2>/dev/null | awk '/^[0-9a-f]+ [0-9]+ [0-9]+/ { print $1 }'
  done | sort -u | while read -r sha; do
    printf '%s\n' "$mine" | grep -qx "$sha" && printf '%s\n' "$sha"
  done | { shas=$(cat); [ -n "$shas" ] && git rev-list --no-walk=sorted $shas | head -1; }
}
