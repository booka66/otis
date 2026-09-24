# Shared by the scripts that run Claude in the background (git-mr-claude,
# git-mr-fix, git-mr-fold, git-mr-watch, git-mr-watch-run, git-verify) and by
# git-claude-view, which shows a run: . "$share/claude-run.sh". A run keeps
# its state in a directory, $d, which git-claude-view describes; each script
# defines its own finish <state> <summary>, since what to reload and whom to
# alert differ.

# pin_agent: the run keeps to the coding agent it started with, resumed or
# not: start() leaves otis-config agent in $d/agent-cli, and a run from before
# there was a choice is Claude's. $who is what its lines call it.
pin_agent() {
  OTIS_AGENT=$(cat "$d/agent-cli" 2>/dev/null || echo claude)
  export OTIS_AGENT
  who=$(otis-agent-run --name)
}

# running <dir>: the run is going: its pid is alive and it has not said how it
# ended (a pid alone can be some other process by now).
running() { [ ! -s "$1/status" ] && [ -r "$1/pid" ] && kill -0 "$(cat "$1/pid")" 2>/dev/null; }
# say <text>: a line in $d's progress.
say() { jq -nc --arg t "$*" '{type: "otis", text: $t, at: (now | floor)}' >> "$d/events.jsonl"; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-300; }
# stopping: x in git-claude-view leaves $d/stopping; the run ends at its next look.
stopping() { [ -e "$d/stopping" ] && finish stopped "stopped"; }
# alert <title> <body> [state]: a desktop notification, through the terminal
# tab the run was started from, or from the system when that tab is gone or
# cannot send one (otis-notify). A failed state marks it ✗.
alert() {
  if [ "$3" = failed ]; then otis-notify --sound Basso "✗ $1" "$2"; else otis-notify "$1" "$2"; fi
}
# tell_picker <action>: an fzf action to the picker the run was started from,
# if it is still open.
tell_picker() { [ -n "$FZF_PORT" ] && curl -s -XPOST "127.0.0.1:$FZF_PORT" -H "x-api-key: $FZF_API_KEY" -d "$1" >/dev/null; }

# Surviving a closed laptop. Sleep only pauses a run, but the call it was in
# the middle of fails on waking; a shutdown kills it outright. So a run that
# can pick up again keeps each step's result in $d as it goes, skips steps
# that already have one, and retries a Claude turn that broke off. Its start
# leaves $d/cmd (the --run command) and $d/cwd, which is what resume runs.

# results: how many result events $d's progress holds; a turn's own result is
# one more than there were before it. With $awho set, only that agent's (its
# events' who): the tester's stream, or another turn running beside this one,
# writes results into the same progress.
results() { awk -v w="$awho" '/"type":"result"/ && (w == "" || index($0, "\"who\":\"" w "\"")) { n++ } END { print n + 0 }' "$d/events.jsonl" 2>/dev/null || echo 0; }

# attempt <command...>: one Claude turn that appends its events to
# $d/events.jsonl, tried again when it broke off rather than failed: no
# result at all (the process died, the connection dropped), or an API or
# network error. Three more tries, a minute apart. The turn's result event
# ends in $result, empty when it never got one; 1 when it gave up.
attempt() {
  tries=0
  while :; do
    before=$(results)
    "$@"
    stopping
    result=
    [ "$(results)" -gt "$before" ] && result=$(jq -c --arg w "$awho" 'select(.type == "result" and ($w == "" or .who == $w))' "$d/events.jsonl" | tail -1)
    if [ -n "$result" ] && ! printf '%s' "$result" |
      jq -e '.is_error and ((.result // "") | test("API Error|[Cc]onnection|network|ECONN|ETIMEDOUT|socket|overloaded|fetch failed"))' >/dev/null; then
      return 0
    fi
    tries=$((tries + 1))
    [ "$tries" -le 3 ] || return 1
    say "${who:-Claude}'s turn broke off$([ -n "$result" ] && printf ': %s' "$(oneline "$(printf '%s' "$result" | jq -r .result)")"); trying again in a minute ($tries of 3)"
    sleep "${OTIS_RETRY_WAIT:-60}" &
    wait $!
    stopping
  done
}

# orphaned <dir>: a run that can pick up again, was started, is not going, and
# never said how it ended: its process died under it.
# What a run writes (Claude's transcript, tool output) is for its owner. A
# script that also writes your files puts otis_umask back first.
otis_umask=$(umask)
umask 077

# costs <dir>: what the run has cost so far, as " · Claude $1.20 · Cursor $0.68"
# (empty parts left out): Claude from its turns' results in the progress,
# Cursor from usage.json, which a verification keeps from Cursor's usage API.
costs() {
  c=$(jq -r 'select(.type == "result") | .total_cost_usd // empty' "$1/events.jsonl" 2>/dev/null | awk '{ s += $1 } END { if (s > 0) printf " · Claude $%.2f", s }')
  u=$(jq -r '.cost.chargedCents // empty' "$1/usage.json" 2>/dev/null | awk '{ if ($1 > 0) printf " · Cursor $%.2f", $1 / 100 }')
  printf '%s%s' "$c" "$u"
}

orphaned() { [ -s "$1/cmd" ] && [ ! -s "$1/status" ] && [ -r "$1/pid" ] && ! kill -0 "$(cat "$1/pid")" 2>/dev/null; }

# note_signal: a run that is killed leaves the signal and the time in $d/log.
# A killed process says nothing at all: its log and Claude's transcript simply
# stop, and whether it was the terminal going away, a picker taking its
# children with it or something else is lost. This is not a status, so the run
# is still an orphan for resume to pick up; a SIGKILL still says nothing.
note_signal() {
  trap 'printf "killed by SIGHUP at %s\n" "$(date +%T)" >> "$d/log"; exit 129' HUP
  trap 'printf "killed by SIGINT at %s\n" "$(date +%T)" >> "$d/log"; exit 130' INT
  trap 'printf "killed by SIGTERM at %s\n" "$(date +%T)" >> "$d/log"; exit 143' TERM
}

# resume <dir>: start an orphaned run again, where it was started, to pick up
# from its last finished step. mkdir is the lock, so two pickers drawing at
# once start it once; a lock older than a minute was left by one that died.
#
# A run whose process dies every time would be started again forever, so a
# life that added nothing to the progress is counted as one that got nowhere,
# and after three of those in a row the run is failed instead. Any progress at
# all clears the count, so a run the laptop keeps killing over days still
# picks up; it is only a run that cannot get through its first breath that
# gives up. dir/lives holds that count and how long the progress was when the
# last life began. c in git-claude-view clears it: a resume you asked for is
# never turned down.
resume() {
  [ -n "$(find "$1/resuming" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$1/resuming" 2>/dev/null
  mkdir "$1/resuming" 2>/dev/null || return 0
  if orphaned "$1"; then
    dir=$1
    lives=$(cat "$dir/lives" 2>/dev/null)
    if [ "${lives##* }" = "$(wc -c < "$dir/events.jsonl" 2>/dev/null | tr -d ' ')" ]
      then dead=$((${lives%% *} + 1)); else dead=1; fi
    if [ "$dead" -gt 3 ]; then
      jq -nc --arg t "started again three times and got nowhere; giving up (c here tries once more)" \
        '{type: "otis", text: $t}' >> "$dir/events.jsonl"
      echo failed > "$dir/status"
      date +%s > "$dir/ended"
      alert "$(cat "$dir/title" 2>/dev/null || echo "a run of otis's")" \
        "its process kept dying; giving up" failed
      rmdir "$dir/resuming"
      return 0
    fi
    where=$(cat "$dir/cwd" 2>/dev/null)
    [ -d "$where" ] || where=$(git-worktree-path main)
    jq -nc --arg t "picking up where it left off" '{type: "otis", text: $t}' >> "$dir/events.jsonl"
    printf '%s %s\n' "$dead" "$(wc -c < "$dir/events.jsonl" | tr -d ' ')" > "$dir/lives"
    # cmd holds the argv one a line (a branch name can hold shell syntax).
    # exec: the subshell becomes the run, so $! is the run's pid, and no
    # shell is left holding the picker's output open until the run ends.
    (cd "$where" && IFS='
' && set -f && set -- $(cat "$dir/cmd") && exec otis-detach "$@" </dev/null >> "$dir/log" 2>&1 & echo $! > "$dir/pid")
  fi
  rmdir "$1/resuming"
}

# resume_all: every orphaned run of this repo, started again. gmr and gb call
# it as they draw, so a run the laptop killed goes on the next time you look.
resume_all() {
  . "$share/repo.sh" || return 0
  c=$OTIS_GITDIR
  for r in "$c"/gmr-claude/*/ "$c"/gmr-fix/*/ "$c"/otis-verify/*/; do
    [ -d "$r" ] && orphaned "${r%/}" && resume "${r%/}"
  done
  return 0
}
