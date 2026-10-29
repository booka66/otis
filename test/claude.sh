#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-claude-worktree, share/claude-run.sh: the pool of worktrees Claude's
# runs take one from, and a run whose process keeps dying. A live pid is this
# test's own; a dead one has already been waited for.
pool=$tmp/repo/.claude/worktrees
one=$tmp/repo/.git/gmr-fix/one two=$tmp/repo/.git/gmr-fix/two
mkdir -p "$one" "$two" && printf '%s\n' $$ > "$one/pid" && printf '%s\n' $$ > "$two/pid"
expect slots/first "$(git-claude-worktree take fix "$one" HEAD)" "$pool/claude-fix"
expect slots/next-run-next-slot "$(git-claude-worktree take fix "$two" HEAD)" "$pool/claude-fix-2"
# A run asking twice was killed and picked up: it takes back the slot it holds
# rather than a second one, even with an earlier slot free.
git-claude-worktree release "$pool/claude-fix"
expect slots/picked-up-keeps-its-own "$(git-claude-worktree take fix "$two" HEAD)" "$pool/claude-fix-2"
expect slots/freed-slot-reused "$(git-claude-worktree take fix "$one" HEAD)" "$pool/claude-fix"
# A slot whose run is over is taken over; four going at once is the ceiling.
printf 'done\n' > "$two/status"
three=$tmp/repo/.git/gmr-fix/three && mkdir -p "$three" && printf '%s\n' $$ > "$three/pid"
expect slots/over-is-taken-over "$(git-claude-worktree take fix "$three" HEAD)" "$pool/claude-fix-2"
for r in four five six; do mkdir -p "$tmp/repo/.git/gmr-fix/$r" && printf '%s\n' $$ > "$tmp/repo/.git/gmr-fix/$r/pid"; done
git-claude-worktree take fix "$tmp/repo/.git/gmr-fix/four" HEAD >/dev/null
git-claude-worktree take fix "$tmp/repo/.git/gmr-fix/five" HEAD >/dev/null
expect slots/full "$(git-claude-worktree take fix "$tmp/repo/.git/gmr-fix/six" HEAD 2>&1 >/dev/null)" \
  "four fix runs are going already; wait for one to finish"
# trim: a free slot no run took for a week goes, a held one stays however old,
# and one from before takes left a stamp starts its week now.
sl=$tmp/repo/.git/otis-claude-slots
git-claude-worktree release "$pool/claude-fix-3" && git-claude-worktree release "$pool/claude-fix-4"
touch -t 202001010000 "$sl/claude-fix-2.used" "$sl/claude-fix-3.used" && rm "$sl/claude-fix-4.used"
expect trim/says "$(git-claude-worktree trim)" "claude-fix-3, Claude's, which no run took for a week"
expect trim/left "$(command ls "$pool" | tr '\n' ' ')" "claude-fix claude-fix-2 claude-fix-4 "
expect trim/unregistered "$(git worktree list --porcelain | grep -c -e claude-fix-3 -e .gone-)" "0"
expect trim/stamped "$([ -e "$sl/claude-fix-4.used" ] && echo yes)" "yes"
expect trim/taken-again "$(git-claude-worktree take fix "$tmp/repo/.git/gmr-fix/six" HEAD)" "$pool/claude-fix-3"
rm -rf "$tmp/repo/.git/otis-claude-slots" "$pool"
git worktree prune

# A run started again that adds nothing to its progress got nowhere; the
# fourth such life gives up instead of being started forever. The stub keeps
# the alert off this machine's screen.
mkdir -p "$tmp/stub" && printf '#!/bin/sh\nexit 0\n' > "$tmp/stub/otis-notify" && chmod +x "$tmp/stub/otis-notify"
# a run <dir> ready to pick up, and killed <dir>: its process gone again.
a_run() { mkdir -p "$1" && printf 'true\n' > "$1/cmd" && printf '%s\n' "$tmp/repo" > "$1/cwd" && : > "$1/events.jsonl"; }
killed() { sh -c 'exit 0' & p=$!; wait "$p" 2>/dev/null; printf '%s\n' "$p" > "$1/pid"; }
picks_up() { ( PATH=$tmp/stub:$PATH; . "$share/claude-run.sh" && resume "$1" ); }
dies=$tmp/repo/.git/gmr-fix/dies && a_run "$dies"
for _ in 1 2 3 4; do killed "$dies"; picks_up "$dies"; done
expect resume/gives-up "$(cat "$dies/status" 2>/dev/null)" "failed"
expect resume/says-why "$(jq -r 'select(.type == "otis") | .text' "$dies/events.jsonl" | tail -1)" \
  "started again three times and got nowhere; giving up (c here tries once more)"
expect resume/tried-three-times "$(grep -c 'picking up where it left off' "$dies/events.jsonl")" "3"
# Progress clears the count, so a run the laptop keeps killing still picks up.
lives=$tmp/repo/.git/gmr-fix/lives && a_run "$lives"
for _ in 1 2 3 4 5; do
  killed "$lives"; picks_up "$lives"
  jq -nc '{type: "otis", text: "got somewhere"}' >> "$lives/events.jsonl"
done
expect resume/progress-clears-the-count "$(cat "$lives/status" 2>/dev/null)" ""
# The pid kept is the run's own, and nothing of the resume holds the caller's
# output open while the run goes: gb reads its rows through a pipe, and hung
# until the run ended.
slow=$tmp/repo/.git/gmr-fix/slow && a_run "$slow" && printf 'sleep\n5\n' > "$slow/cmd" && killed "$slow"
t=$(date +%s); picks_up "$slow" | cat
expect resume/leaves-the-pipe "$(( $(date +%s) - t < 3 ))" "1"
expect resume/pid-is-the-run "$(ps -o command= -p "$(cat "$slow/pid")" | grep -c 'sleep 5$')" "1"
kill "$(cat "$slow/pid")" 2>/dev/null

# --- otis-thread: a turn of Claude's on the workspace. The workspace is
# here: an ssh that runs the command from a home of its own, GNU tail's
# --pid, and a claude that edits, commits and says so.
mkdir -p "$tmp/far-bin" "$tmp/far-home"
cat > "$tmp/far-bin/ssh" <<'SSH'
#!/bin/sh
while [ $# -gt 0 ]; do case $1 in -o|-p|-l) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
cd "$FAR_HOME" && HOME=$FAR_HOME exec sh -c "$*"
SSH
cat > "$tmp/far-bin/tail" <<'TAIL'
#!/usr/bin/perl
my ($from, $pid, $file);
for (@ARGV) { if (/^\+(\d+)$/) { $from = $1 } elsif (/^--pid=(\d+)$/) { $pid = $1 } elsif (!/^-/) { $file = $_ } }
exec "/usr/bin/tail", @ARGV unless defined $pid;
$| = 1; open(my $f, "<", $file) or exit 1; seek($f, $from - 1, 0);
while (1) { my $n = read($f, my $buf, 65536); if ($n) { print $buf; next } last unless kill 0, $pid; select undef, undef, undef, 0.05 }
my $buf; while (read($f, $buf, 65536)) { print $buf }
TAIL
cat > "$tmp/far-bin/claude" <<'CLAUDE'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/claude-args"
echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"On it. "}}}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"'"$PWD"'/talk.txt"}}]}}'
echo hello >> talk.txt && git add talk.txt && git commit -qm "Talk"
echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"It talks now."}}}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"It talks now."}'
CLAUDE
cp "$tmp/stub/otis-notify" "$tmp/far-bin/"
chmod +x "$tmp/far-bin/"*
git clone -q "$tmp/repo" "$tmp/far" && git -C "$tmp/far" config user.email t@t && git -C "$tmp/far" config user.name t
git config otis.remote far && git config otis.remotePath "$tmp/far"
git branch talk
th=$tmp/repo/.git/otis-thread/b-talk && mkdir -p "$th" && echo "make it talk" > "$th/title"
far() { PATH=$tmp/far-bin:$PATH FAR_HOME=$tmp/far-home "$@"; }
far otis-thread --send talk "make it talk" "talk.txt" >/dev/null 2>&1
expect thread/status "$(cat "$th/status") $(cat "$th/came")" "done 1"
expect thread/home "$(git log -1 --format=%s talk)" "Talk"
expect thread/said "$(jq -r 'select(.type == "otis") | .text' "$th/events.jsonl" | tail -1)" "It talks now.; 1 commit came back"
expect thread/chat "$(tr '\001' '^' < "$th/chat" | grep . | tr '\n' '|')" "^U make it talk|^O on talk.txt|On it. |^T editing talk.txt|It talks now.|^S 1 commit came back|"
expect thread/asked-where "$(grep -c "(I'm on talk.txt.)" "$tmp/far-home/claude-args")" "1"
expect thread/first-turn "$(grep -c -e --session-id "$tmp/far-home/claude-args")" "1"
# The next turn goes on with the same conversation, from the branch as it is
# here, with what came back last time.
far otis-thread --send talk "again" >/dev/null 2>&1
expect thread/resumes "$(grep -A1 -e --resume "$tmp/far-home/claude-args" | tail -1)" "$(cat "$th/session")"
expect thread/builds-on "$(git log --format=%s talk | head -2 | tr '\n' ' ')" "Talk Talk "
git config --unset otis.remote && git config --unset otis.remotePath
git branch -D talk >/dev/null 2>&1
rm -rf "$th" "$tmp/far" "$tmp/far-home"

# --- otis-agent-run: claude is claude, flags untouched; another agent's stream
# comes back as claude's, answer and session included
mkdir -p "$tmp/agents"
printf '#!/bin/sh\nfor a; do printf "[%%s]" "$a"; done\n' > "$tmp/agents/claude"
cat > "$tmp/agents/cursor-agent" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/cursor-args"
cat > "$HOME/cursor-prompt"
cat <<'J'
{"type":"system","subtype":"init","session_id":"cur-1","model":"Auto"}
{"type":"thinking","subtype":"delta","text":"Reading "}
{"type":"thinking","subtype":"delta","text":"the note."}
{"type":"thinking","subtype":"completed"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reading it."}]},"session_id":"cur-1"}
{"type":"tool_call","subtype":"started","call_id":"t1","tool_call":{"readToolCall":{"args":{"path":"note.txt"}}}}
{"type":"tool_call","subtype":"completed","call_id":"t1","tool_call":{"readToolCall":{"args":{"path":"note.txt"},"result":{"success":{"content":"pelican\n"}}}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"```json\n{\"word\": \"pelican\"}\n```"}]},"session_id":"cur-1"}
{"type":"result","subtype":"success","is_error":false,"result":"Reading it.```json...","session_id":"cur-1"}
J
EOF
chmod +x "$tmp/agents/claude" "$tmp/agents/cursor-agent"
agents() { PATH=$tmp/agents:$PATH "$@"; }
expect agent-run/claude-untouched "$(agents otis-agent-run -p --tools 'Read,Grep' --json-schema '{"a": 1}' --resume s)" '[-p][--tools][Read,Grep][--json-schema][{"a": 1}][--resume][s]'
expect agent-run/ready "$(agents otis-agent-run --ready; echo "rc=$?")" "rc=0"
git config otis.agent codex
expect agent-run/not-ready "$(PATH=$tmp/agents:/usr/bin:/bin:$root/bin otis-agent-run --ready)" "this needs Codex (codex)"
git config otis.agent cursor
expect agent-run/no-gated-shell "$(agents otis-agent-run -p --tools Read,Bash </dev/null | jq -r .is_error)" "true"
expect agent-run/unknown-flag "$(agents otis-agent-run -p --mcp-config x </dev/null | jq -r .result)" "otis-agent-run: --mcp-config is a claude flag that Cursor's agent has nothing for here"
out=$(printf 'look\n' | agents otis-agent-run -p --restricted --tools Read,Grep,Glob --add-dir /ctx --session-id mine \
  --output-format stream-json --verbose --json-schema '{"type":"object"}')
expect agent-run/answer "$(printf '%s\n' "$out" | jq -c 'select(.type == "result") | [.session_id, .structured_output]')" '["mine",{"word":"pelican"}]'
expect agent-run/read-only "$(sed -n 1p "$tmp/cursor-args")" "-p --trust --output-format stream-json --mode ask --add-dir /ctx"
expect agent-run/schema-asked "$(grep -c 'matching this JSON Schema' "$tmp/cursor-prompt")" "1"
expect agent-run/events "$(printf '%s\n' "$out" | git-claude-view --events | jq -r '[.type, .name // .text // ""] | join(":")' | tr '\n' '|')" \
  'init:|thinking:Reading the note.|text:Reading it.|tool:Read|output:pelican||text:```json|{"word": "pelican"}|```|result:|'
printf 'fix\n' | agents otis-agent-run -p --tools Read,Edit --resume mine --output-format json >/dev/null
expect agent-run/resumes-theirs "$(sed -n 2p "$tmp/cursor-args")" "-p --trust --output-format stream-json --sandbox enabled --resume cur-1"
expect agent-run/no-session "$(printf 'x\n' | agents otis-agent-run -p --resume nobody | jq -r .result)" "no Cursor's agent session kept for nobody to resume"
expect agent-run/codex "$(printf '%s\n' '{"type":"thread.started","thread_id":"t"}' \
  '{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"rg x"}}' \
  '{"type":"item.completed","item":{"id":"i1","type":"command_execution","aggregated_output":"","exit_code":1}}' \
  '{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"{\"n\":1}"}}' \
  '{"type":"turn.completed"}' | OTIS_AGENT_SCHEMA=x otis-agent-run --translate codex | jq -c '[.type, .is_error, .structured_output]' | tr '\n' ' ')" \
  '["system",null,null] ["assistant",null,null] ["user",null,null] ["assistant",null,null] ["result",false,{"n":1}] '
expect agent-run/codex-cut-off "$(printf '%s\n' '{"type":"thread.started","thread_id":"t"}' '{"type":"error","message":"stream disconnected"}' |
  otis-agent-run --translate codex | jq -c '[.is_error, .result]' | tail -1)" '[true,"stream disconnected"]'
git config --unset otis.agent
# A run is by the agent it started with, and one from before there was a
# choice is Claude's.
mkdir -p "$tmp/run-old" "$tmp/run-codex" && printf 'codex\n' > "$tmp/run-codex/agent-cli"
git config otis.agent cursor
expect agent-run/name-now "$(otis-agent-run --name)" "Cursor"
expect agent-run/name-of-run "$(otis-agent-run --name "$tmp/run-codex")" "Codex"
expect agent-run/name-of-old-run "$(otis-agent-run --name "$tmp/run-old")" "Claude"
expect agent-run/pinned "$( (d=$tmp/run-codex; . "$share/claude-run.sh"; pin_agent; printf '%s %s' "$OTIS_AGENT" "$who") )" "codex Codex"
git config --unset otis.agent
# A setting of a few values is picked, not typed.
if picker_open "otis-config --prompt local agent"; then
  expect config/choices "$(picker_rows)" "3"
  picker_key j; picker_key "$(printf '\r')"
  exec 7>&-; wait "$driver" 2>/dev/null
  expect config/picked "$(git config otis.agent)" "codex"
else
  expect config/choices-picker-opens "no" "yes"
fi
git config --unset otis.agent

