# cursor.sh: Cursor's cloud agents API, for what otis runs in Cursor's VMs:
# V's tester (git-verify-run). Sourced; CURSOR_API_KEY is the caller's to have.
api=https://api.cursor.com

# cursor <method> <path> [json]: Cursor's API. The response on stdout, and
# exit 1 with its error body there instead when it fails. The JSON content
# type goes only with a body: a POST with neither (cancel) is refused with one.
# A GET that failed on Cursor's side or the network's, not on the request (a
# 4xx), is tried again for five minutes; a POST is not, since it may have
# landed (send_run has its own).
cursor() {
  m=$1 p=$2 i=0
  shift 2
  [ $# -gt 0 ] && set -- -H 'Content-Type: application/json' --data "$1"
  until out=$(printf 'user = "%s:"\n' "$CURSOR_API_KEY" | curl -sS --fail-with-body -K - -X "$m" "$@" "$api$p" 2>&1); do
    case $out in *'returned error: 4'*) i=99 ;; esac
    [ "$m" = GET ] && [ $i -lt 20 ] || { printf '%s' "$out"; return 1; }
    sleep 15; i=$((i + 1))
  done
  printf '%s' "$out"
}

# send_run <text>: a new run of $agent's with this prompt, its id on
# stdout, or Cursor's error there and exit 1. Cursor takes one run at a time,
# and frees the agent some time after its last run ends: a run can read
# CANCELLED or FINISHED while a new one is still refused as agent_busy, for
# seconds after a finish and over three minutes after a cancel that caught it
# mid-command. So that is waited out, for ten minutes at most, and so is a
# failure on Cursor's side or the network's; any other 4xx is final.
send_run() {
  until=$(($(date +%s) + 600))
  until out=$(cursor POST "/v1/agents/$agent/runs" "$(jq -n --arg t "$1" '{prompt: {text: $t}}')"); do
    case $out in *'"agent_busy"'*) ;; *'returned error: 4'*) printf '%s' "$out"; return 1 ;; esac
    [ "$(date +%s)" -lt "$until" ] || { printf '%s' "$out"; return 1; }
    sleep 5
  done
  printf '%s' "$out" | jq -r .run.id
}
