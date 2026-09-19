# Shared by the MR pickers that change GitLab as you press a key
# (git-mr-labels, git-mr-reviewers): . "$share/mr-sync.sh". The picker draws
# the change at once from its own state and the PUT goes in the background,
# so tab never waits on GitLab.
#
# Each change sends the whole set it leaves (every label, every reviewer),
# numbered in the order the keys came. The PUTs run one at a time, and one
# whose change is no longer the latest does nothing, since the latest one's
# is on its way: a quick run of tabs is one or two PUTs, and lands as the
# last of them whatever order the processes wake in. The lock and the
# numbers live outside the picker's state, which goes when it closes while
# a PUT is still out.

# mr_gen <key>: the next change's number.
mr_gen() {
  g=$(( $(cat "${TMPDIR:-/tmp}/otis-mr-sync.$1.gen" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$g" > "${TMPDIR:-/tmp}/otis-mr-sync.$1.gen"
  echo "$g"
}

# mr_post <actions>: to the open picker, if it still is.
mr_post() {
  [ -n "$FZF_PORT" ] && curl -s -XPOST "127.0.0.1:$FZF_PORT" -H "x-api-key: $FZF_API_KEY" -d "$1" >/dev/null
}

# mr_sync <key> <number> <on failure> <put command...>: the PUT, in the
# background. <on failure> is a function of the caller's, given GitLab's
# answer, while the picker is still open: it puts back what GitLab has.
mr_sync() {
  key=${TMPDIR:-/tmp}/otis-mr-sync.$1 gen=$2 fail=$3
  shift 3
  (
    # A lock a killed PUT left behind is taken after 30 seconds.
    n=0
    until mkdir "$key.lock" 2>/dev/null; do
      n=$((n + 1)); [ "$n" -eq 300 ] && rmdir "$key.lock" 2>/dev/null
      sleep 0.1
    done
    failed=
    if [ "$gen" -eq "$(cat "$key.gen" 2>/dev/null || echo 0)" ]; then
      out=$("$@" 2>&1) || failed=1
    fi
    rmdir "$key.lock"
    [ -n "$failed" ] && [ -d "$GIT_FZF_STATE" ] && "$fail" "$out"
  ) </dev/null >/dev/null 2>&1 &
}
