#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- otis-list, otis-do: the dashboard's rows, and what enter does with one.
# Origin is on neither GitLab nor GitHub for this, so nothing here asks either.
git remote set-url origin https://code.example.com/x/y.git
mkdir -p "$tmp/dash"
common=$(git rev-parse --path-format=absolute --git-common-dir)
rows=$(GIT_FZF_STATE=$tmp/dash otis-list)
expect otis-list/fields "$(printf '%s\n' "$rows" | awk -F'\t' '{ print NF }' | sort -u)" "26"
expect otis-list/here-last "$(printf '%s\n' "$rows" | tail -1 | cut -f6,11,14 | tr '\t' ' ')" "here here here"
expect otis-list/here-always "$(printf '%s\n' "$rows" | strip | grep -c '── here ')" "1"
expect otis-list/quiet "$(strip < "$tmp/dash/footer" | sed 's/ · .*//')" "nothing waiting on you"
expect otis-list/no-forge "$(strip < "$tmp/dash/footer" | sed 's/.* · //')" "origin is on neither GitLab nor GitHub, so this is your work here alone"
# The board the dashboard draws from those rows (otis-board): its counts,
# then a row a change. With nothing but the checkout it is where you are.
printf '%s\n' "$rows" > "$tmp/dash/rows"
expect otis-board/quiet "$(GIT_FZF_STATE=$tmp/dash otis-board | cut -f1-4 | tr '\t' ' ' | tr '\n' '|')" "# 0 0 0|here here here |"
# Fixes Claude left on a branch with no MR: a waiting row that needs no GitLab.
mkdir -p "$common/gmr-fix/b-feature" && printf 'patch\n' > "$common/gmr-fix/b-feature/01.patch"
rows=$(GIT_FZF_STATE=$tmp/dash otis-list)
expect otis-list/waiting "$(printf '%s\n' "$rows" | strip | awk -F'\t' '$11 == "w-fix-b-feature" { print $1 }' | tr -s ' ')" " ✎1 fold in 1 fix feature"
expect otis-list/waiting-first "$(printf '%s\n' "$rows" | strip | head -1 | cut -f1 | sed 's/ ─*$//')" "── waiting on you"
expect otis-list/waiting-count "$(strip < "$tmp/dash/footer" | sed 's/ · .*//')" "1 thing waiting on you"
# On the board that branch is a change that needs you: no verify light, and
# the fix beside its review light, where the cursor lands and f opens it.
git branch feature
printf '%s\n' "$rows" > "$tmp/dash/rows"
board=$(GIT_FZF_STATE=$tmp/dash otis-board | strip)
expect otis-board/counts "$(printf '%s\n' "$board" | head -1 | tr '\t' ' ')" "# 1 0 0"
expect otis-board/branch-fix "$(printf '%s\n' "$board" | awk -F'\t' '$2 == "c-b-feature" { print $1, $3, $4, "light " $8, "[" $28 "]", $44 $50, ($51 == "'"$common"'/gmr-fix/b-feature"), NF }')" "move change feature light 4 [] ·✎1 1 76"
# gb's and gw's rows, where the dashboard keeps them for the board. A branch
# never pushed has its commits beside its local light, and enter goes to it.
# A merged branch checked out nowhere and a worktree gw calls safe fold under
# clean up, where enter deletes (asking first); any other worktree under
# worktrees, where enter goes there and d removes it, one with nothing
# uncommitted told from one with work in it. The worktrees under gw's
# dedicated heading, kept for reuse, are not listed at all.
printf 'x\tfeature\tlocal\t\t\t\t2\t0\t\nx\told\tmerged\t\t7\t\t0\t3\t\n' > "$tmp/dash/branches.tsv"
printf 'x\t/w/gone\told\tmerged\tsafe\t7\t0\t3\nx\t/w/keep\t\tdetached\t\t\t\t\nb  3 uncommitted  1h\t/w/busy\tfeature\tlocal\t\t\t2\t0\n── dedicated\t\t\t\t\t\t\t\nx\t/w/claude-fix\t\tdetached\t\t\t\t\n' > "$tmp/dash/worktrees.tsv"
board=$(GIT_FZF_STATE=$tmp/dash otis-board | strip)
expect otis-board/local "$(printf '%s\n' "$board" | awk -F'\t' '$2 == "c-b-feature" { print $20 $26, $23, $24 }')" "○↑2 goto feature"
expect otis-board/groups "$(printf '%s\n' "$board" | awk -F'\t' '$3 == "group" && $1 != "runs" { printf "%s %s|", $1, $66 }')" "cleanup 2|places 2|"
expect otis-board/cleanup "$(printf '%s\n' "$board" | awk -F'\t' '$65 == "cleanup" { printf "%s %s %s|", $3, $23, $24 }')" "change delbranch old|place delwt /w/gone|"
expect otis-board/places "$(printf '%s\n' "$board" | awk -F'\t' '$65 == "places" { printf "%s %s %s %s: %s|", $4, $23, $24, $60, $61 }')" "keep cd /w/keep clean: detached|busy cd /w/busy dirty: feature  ·  3 uncommitted|"
expect otis-board/places-say "$(printf '%s\n' "$board" | awk -F'\t' '$2 == "g-places" { print $67 }')" "1 with nothing uncommitted  ·  1 with work in it"
rm -f "$tmp/dash/branches.tsv" "$tmp/dash/worktrees.tsv"
# A thread of Claude's (otis-thread) on a branch with no MR is that branch's
# change, Claude its review light: commits its turn brought back to read, or
# only words to answer, with its first line, until x; while a turn goes, it
# is moving.
git branch talk
th=$common/otis-thread/b-talk
mkdir -p "$th" && echo "make it talk" > "$th/title" && echo 100 > "$th/started" && echo 200 > "$th/ended" && echo done > "$th/status" && echo 1 > "$th/came"
printf '{"type":"otis","text":"It talks now.; 1 commit came back"}\n' > "$th/events.jsonl"
thread_board() { rows=$(GIT_FZF_STATE=$tmp/dash otis-list); printf '%s\n' "$rows" > "$tmp/dash/rows"
  GIT_FZF_STATE=$tmp/dash otis-board | strip | awk -F'\t' '$2 == "c-b-talk" { print $1, "light " $8, $44, $70, ($48 == "'"$th"'"), $49 }'; }
expect otis-list/thread "$(GIT_FZF_STATE=$tmp/dash otis-list | strip | awk -F'\t' '$11 == "w-thread-b-talk" { print $1 }' | tr -s ' ')" \
  " ✻ review its diff talk It talks now.; 1 commit came back"
expect otis-board/thread-done "$(thread_board)" "move light 4 ✻ review its diff 1 read it"
echo 0 > "$th/came"
expect otis-board/thread-asked "$(thread_board)" "move light 4 ✻ answer Claude 1 answer it"
# With a fix of Claude's for the branch too, the light is the thread's, which
# wants you sooner, the fix said beside it, and f still folds it in.
mkdir -p "$common/gmr-fix/b-talk" && printf 'patch\n' > "$common/gmr-fix/b-talk/01.patch"
expect otis-board/thread-and-fix "$(thread_board)" "move light 4 ✻ answer Claude 1 answer it"
expect otis-board/thread-and-fix-says "$(GIT_FZF_STATE=$tmp/dash otis-board | strip | awk -F'\t' '$2 == "c-b-talk" { print $75, ($51 == "'"$common"'/gmr-fix/b-talk") }')" "answer Claude, fold in the fix 1"
rm -rf "$common/gmr-fix/b-talk"
cp "$th/ended" "$th/seen"
expect otis-board/thread-seen "$(thread_board)" ""
rm "$th/seen" "$th/status" "$th/ended" "$th/came"
sleep 30 & echo $! > "$th/pid"
expect otis-board/thread-going "$(thread_board)" "moving light 4 ◌ Claude working 1 open the run"
kill $! 2>/dev/null; wait $! 2>/dev/null
expect otis-do/thread "$(otis-do enter run run "$th" "" "" "" "" "" "" "" "")" "execute(otis-thread 'talk')+execute-silent(git-fzf-bg otis-list)"
# The symbol view's panel talks to the thread about its branch's change.
expect ask/thread-dir "$(OTIS_THREAD=talk git-symbols-ask --dir "main...talk" "" "" "" "" "")" "$th"
expect ask/not-a-thread "$(git-symbols-ask --dir "main...talk" "" "" "" "" "" | grep -c otis-thread)" "0"
rm -rf "$th"
git branch -D talk >/dev/null 2>&1
git branch -D feature >/dev/null 2>&1
# What gd listed is a group too: a deploy a row, enter its jobs and logs.
cp "$tmp/dash/deploys.json" "$tmp/dash/deploys.was"
printf '{"deploys": [{"id": 5, "status": "success", "kind": "deploy", "at": "2026-01-01T00:00:00Z", "pipeline": "77", "sha": "abcdef0123", "mrs": ["7"], "user": "ann", "duration": 60}]}\n' > "$tmp/dash/deploys.json"
expect otis-board/deploys "$(GIT_FZF_STATE=$tmp/dash otis-board | strip | awk -F'\t' '$65 == "deploys" { print $20, $60, $4, $23, $15 }')" "✓ abcdef01 !7  ·  by ann deployjobs 77"
mv "$tmp/dash/deploys.was" "$tmp/dash/deploys.json"
# An open MR of yours, approved and green, is yours to merge though GitLab
# has not worked out that it can (a list mostly says unchecked; merging
# asks): a row under its title, the cursor on its ship light. A verification
# of its branch at a commit it has moved on from is that row's verify light,
# dim, and never a second row under the branch's name: not beside the MR,
# and not when something is in the way and it is only in review. One of
# yours that is with its reviewers is never folded under waiting on others:
# it is a row with the rest of yours, and says how its review stands.
mkdir -p "$tmp/board"
printf 'w\t\t\t\t\tsep\t\t\t\t\tsep-waiting\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n' > "$tmp/board/rows"
printf 'v\t\t\t\t\trun\t\t\t\t\tw-verify-b-feat\t\t/v/b-feat\trun\t●\t\tverified: failed\tfeat\t\t\t\t\t\topen the run\t\t\n' >> "$tmp/board/rows"
printf '{"verify": {"b-feat": {"verifying": false, "status": "done", "verdict": "fail", "head": "old"}}}\n' > "$tmp/board/marks.json"
board_mr() { printf '{"data": {"currentUser": {"username": "me", "authoredMergeRequests": {"nodes": [{"iid": "7", "title": "Ship it", "sourceBranch": "feat", "targetBranch": "main", "webUrl": "u", "draft": false, "approved": true, "autoMergeEnabled": false, "detailedMergeStatus": "%s", "updatedAt": "2026-01-01T00:00:00Z", "diffRefs": {"headSha": "new"}, "headPipeline": {"status": "SUCCESS"}, "reviewers": {"nodes": [{"username": "ann", "mergeRequestInteraction": {"reviewState": "APPROVED"}}]}}]}}}}\n' "$1" > "$tmp/board/ci.json"; }
board_lights() { GIT_FZF_STATE=$tmp/board otis-board | strip | awk -F'\t' '$2 ~ /^c-/ { printf "%s %s %s light %s %s%s%s%s%s %s|", $1, $2, $4, $8, $20, $28, $36, $44, $52, $55 }'; }
board_mr UNCHECKED
expect otis-board/merge-unchecked "$(board_lights)" "move c-7 Ship it light 5 ·✗✓✓! merge|"
# What the row says: its move, the words of the light that wants you most,
# and how each of its five lights stands in words, "" for one with nothing
# to say. With nothing for you on it, the move is how it stands.
board_says() { GIT_FZF_STATE=$tmp/board otis-board | strip | awk -F'\t' '$2 ~ /^c-/ { printf "%s [%s|%s|%s|%s|%s]|", $70, $72, $73, $74, $75, $76 }'; }
expect otis-board/says-its-move "$(board_says)" "merge it [|older verify broke|pipeline passed|approved|ready to merge]|"
# A thread of Claude's on its branch is its review light, and wants you
# sooner than the merge: what Claude left you, the review beside it.
cp "$tmp/board/rows" "$tmp/board/rows.kept"
printf 't\t\t\t\tfeat\trun\t\t\t\t\tw-thread-b-feat\t\t/t/b-feat\trun\t✻\t\tanswer Claude\tfeat\t\t\tfeat\t\t\tanswer it\t\t\n' >> "$tmp/board/rows"
expect otis-board/thread-on-mr "$(board_lights)" "move c-7 Ship it light 4 ·✗✓✻! merge|"
expect otis-board/thread-on-mr-says "$(board_says)" "answer Claude [|older verify broke|pipeline passed|answer Claude, approved|ready to merge]|"
mv "$tmp/board/rows.kept" "$tmp/board/rows"
board_mr DISCUSSIONS_NOT_RESOLVED
expect otis-board/verify-of-folded "$(board_lights)" "sent c-7 Ship it light 4 ·✗✓✓· |"
expect otis-board/says-how-it-stands "$(board_says)" "approved [|older verify broke|pipeline passed|approved|]|"
# A run still going is a row of its own among what is moving, so all that
# is running is in one place, and its change's row is still the change's, to
# open beside it: MR 7's verification, while its row says merge it, then
# with nothing else on it, when its row says how its review stands.
cp "$tmp/board/rows" "$tmp/board/rows.kept"; cp "$tmp/board/marks.json" "$tmp/board/marks.kept"
printf 'g\t\t\t\t\tsep\t\t\t\t\tsep-going\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n' > "$tmp/board/rows"
printf 'r\t7\t\t\t\trun\t\t\t\t\tg-otis-verify-7\t\t/v/7\trun\t◎\t\tverifying\t1 of 3 claims in\t\t\t\t\t\topen the run\t\t\n' >> "$tmp/board/rows"
printf '{"verify": {"7": {"verifying": true, "status": "", "head": "new"}}}\n' > "$tmp/board/marks.json"
board_going() { GIT_FZF_STATE=$tmp/board otis-board | strip | awk -F'\t' 'NR > 1 && $3 != "group" && $65 == "" { printf "%s %s %s|", $1, $3, $70 }'; }
board_mr UNCHECKED
expect otis-board/going-run-shown "$(board_going)" "move change merge it|moving notice verifying|"
board_mr DISCUSSIONS_NOT_RESOLVED
expect otis-board/going-run-beside "$(board_going)" "sent change approved|moving notice verifying|"
mv "$tmp/board/rows.kept" "$tmp/board/rows"; mv "$tmp/board/marks.kept" "$tmp/board/marks.json"
# MRs built on one another are a stack: kept together, top first, in the
# lane of the one that wants you most, each with its piece of the rail and
# the lane it would be in alone. Here the bottom one is yours to merge, the
# one on it is with a reviewer and nobody was asked about the top one: all
# three are under your move, and count as the one that needs you. An MR
# built on nothing stays where it was.
stack_mr() { printf '{"iid": "%s", "title": "%s", "sourceBranch": "%s", "targetBranch": "%s", "webUrl": "u", "draft": false, "approved": %s, "autoMergeEnabled": false, "detailedMergeStatus": "UNCHECKED", "updatedAt": "2026-01-01T00:00:00Z", "diffRefs": {"headSha": "new"}, "headPipeline": {"status": "SUCCESS"}, "reviewers": {"nodes": [%s]}}' "$@"; }
printf '{"data": {"currentUser": {"username": "me", "authoredMergeRequests": {"nodes": [%s, %s, %s, %s]}}}}\n' \
  "$(stack_mr 9 Top feat3 feat2 false '')" "$(stack_mr 10 Other other main false '')" \
  "$(stack_mr 7 Bottom feat main true '{"username": "ann", "mergeRequestInteraction": {"reviewState": "APPROVED"}}')" \
  "$(stack_mr 8 Middle feat2 feat false '{"username": "ann", "mergeRequestInteraction": {"reviewState": "UNREVIEWED"}}')" > "$tmp/board/ci.json"
board=$(GIT_FZF_STATE=$tmp/board otis-board | strip)
expect otis-board/stack "$(printf '%s\n' "$board" | awk -F'\t' '$2 ~ /^c-/ { printf "%s %s %s %s|", $1, $2, $68, $69 }')" "move c-9 ┌ unsent|move c-8 ├ sent|move c-7 └ move|unsent c-10  unsent|"
expect otis-board/stack-counts "$(printf '%s\n' "$board" | head -1 | tr '\t' ' ')" "# 1 0 0"
# A stack is in review only when all of it is: with one of it that nobody
# was asked to review, it is not sent yet, unless one of it is being
# verified, which keeps all of it on the board beside the run.
printf '{"data": {"currentUser": {"username": "me", "authoredMergeRequests": {"nodes": [%s, %s]}}}}\n' \
  "$(stack_mr 8 Bottom feat2 main false '{"username": "ann", "mergeRequestInteraction": {"reviewState": "UNREVIEWED"}}')" \
  "$(stack_mr 9 Top feat3 feat2 false '')" > "$tmp/board/ci.json"
board_stack() { GIT_FZF_STATE=$tmp/board otis-board | strip | awk -F'\t' '$2 ~ /^c-/ { printf "%s %s %s %s|", $1, $2, $68, $69 }'; }
expect otis-board/stack-unsent "$(board_stack)" "unsent c-9 ┌ unsent|unsent c-8 └ sent|"
cp "$tmp/board/marks.json" "$tmp/board/marks.kept"
printf '{"verify": {"8": {"verifying": true, "status": "", "head": "new"}}}\n' > "$tmp/board/marks.json"
expect otis-board/stack-verifying "$(board_stack)" "sent c-9 ┌ unsent|sent c-8 └ sent|"
mv "$tmp/board/marks.kept" "$tmp/board/marks.json"
printf '{"data": {"currentUser": {"username": "me", "authoredMergeRequests": {"nodes": [%s, %s]}}}}\n' \
  "$(stack_mr 8 Bottom feat2 main false '{"username": "ann", "mergeRequestInteraction": {"reviewState": "UNREVIEWED"}}')" \
  "$(stack_mr 9 Top feat3 feat2 false '{"username": "ann", "mergeRequestInteraction": {"reviewState": "UNREVIEWED"}}')" > "$tmp/board/ci.json"
expect otis-board/stack-in-review "$(board_stack)" "sent c-9 ┌ sent|sent c-8 └ sent|"
# Its preview names the MR it is built on by number, as the board shows it.
echo '{}' > "$tmp/board/mrs.json"
expect otis-preview/stack "$(GIT_FZF_STATE=$tmp/board OTIS_BRIEF=1 otis-preview mine 9 c-9 '' pipeline | strip | head -1)" "!9  ·  on top of !8"
# A draft of yours that nothing wants you for, touched in the last three
# days, is being written: a row among your drafts, not unsent, and no move
# in the count. Left longer, it is unsent.
draft_mr() { stack_mr "$1" "$2" "$3" main false '' | sed "s/\"draft\": false/\"draft\": true/; s/2026-01-01T00:00:00Z/$4/"; }
printf '{"data": {"currentUser": {"username": "me", "authoredMergeRequests": {"nodes": [%s, %s]}}}}\n' \
  "$(draft_mr 11 Writing wip "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$(draft_mr 12 Left left 2026-01-01T00:00:00Z)" > "$tmp/board/ci.json"
board=$(GIT_FZF_STATE=$tmp/board otis-board | strip)
expect otis-board/draft-recent "$(printf '%s\n' "$board" | awk -F'\t' '$2 ~ /^c-/ { printf "%s %s %s|", $1, $2, $70 }')" "draft c-11 draft|unsent c-12 draft|"
expect otis-board/draft-recent-counts "$(printf '%s\n' "$board" | head -1 | tr '\t' ' ')" "# 0 0 0"
# A verification kept under a branch's name outlives the branch. With no MR
# open it is a change of its own that needs you, until the branch is
# finished: its MR merged after the run ended, or the branch is gone from
# here and from origin. What it said of code that shipped is not your move.
printf '{"data": {"currentUser": {"username": "me", "authoredMergeRequests": {"nodes": []}}}}\n' > "$tmp/board/ci.json"
board_branches() { GIT_FZF_STATE=$tmp/board otis-board | strip | awk -F'\t' '$2 ~ /^c-b-/ { printf "%s %s|", $1, $2 }'; }
git branch feat
expect otis-board/branch-verdict "$(board_branches)" "move c-b-feat|"
printf '{"mrs": [{"iid": "7", "title": "Ship it", "sourceBranch": "feat", "targetBranch": "main", "webUrl": "u", "state": "live", "mergedAt": "2026-01-02T00:00:00Z"}]}\n' > "$tmp/board/ci-merged.json"
expect otis-board/branch-merged "$(board_branches)" ""
rm -f "$tmp/board/ci-merged.json"; git branch -D feat >/dev/null 2>&1
expect otis-board/branch-gone "$(board_branches)" ""
# A verification that runs says what its tester is on and how its criteria
# stand (git-agent-list --data), for the dashboard's row and its glyphs;
# otis-agent draws it.
mkdir -p "$common/otis-verify/b-live/artifacts"
printf '{"criteria":[{"id":"c1","claim":"one","how":"x"},{"id":"c2","claim":"two","how":"y"},{"id":"c3","claim":"three","how":"z"}]}\n' > "$common/otis-verify/b-live/plan.json"
printf 'Verifying live\n' > "$common/otis-verify/b-live/title"; date +%s > "$common/otis-verify/b-live/started"; echo $$ > "$common/otis-verify/b-live/pid"
: > "$common/otis-verify/b-live/artifacts/c1.txt"
printf '%s\n' '{"type":"otis","text":"tester started: http://x"}' '{"type":"tool","name":"run_terminal_cmd","input":{"detail":"bazel test //a:b | tee artifacts/c1.txt"},"who":"tester"}' \
  '{"type":"tool","name":"run_terminal_cmd","input":{"detail":"bazel test //c:d | tee artifacts/c2.txt"},"who":"tester"}' > "$common/otis-verify/b-live/events.jsonl"
expect agent-list/doing "$(git-agent-list --data | awk -F'\t' '$1 == "running" { print $7 "|" $8 }')" "c2 · $ bazel test //c:d | tee artifacts/c2.txt|●◌○"
# What it cost at Cursor is its own turns in the tester's VM, not all the VM
# has run, since a VM goes from one verification to the next: the turn run-1
# names, and one a check-in cut short, which only its stream's file still names.
printf 'run-11111111-1111-1111-1111-111111111111\n' > "$common/otis-verify/b-live/run-1"
: > "$common/otis-verify/b-live/stream-run-22222222-2222-2222-2222-222222222222.id"
printf '%s\n' '{"cost":{"rawCostCents":999,"chargedCents":0},"runs":[{"id":"run-11111111-1111-1111-1111-111111111111","cost":{"rawCostCents":150,"chargedCents":0}},{"id":"run-22222222-2222-2222-2222-222222222222","cost":{"rawCostCents":75,"chargedCents":0}},{"id":"run-33333333-3333-3333-3333-333333333333","cost":{"rawCostCents":774,"chargedCents":0}}]}' > "$common/otis-verify/b-live/usage.json"
expect costs/own-turns "$( (. "$share/claude-run.sh"; costs "$common/otis-verify/b-live") )" " · Cursor \$2.25"
agent=$(TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; setopt extendedglob; zpty -b a "stty rows 30 cols 150; otis-agent $1"; out=
  for _ in {1..200}; do while zpty -rt a buf; do out+=$buf; done; s=${out//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/}
    [[ $s == *CRITERIA* && $s == (*bazel test //c:d)(#c3)* && $s == *"Cursor \$2.25"* ]] && break; sleep 0.1; done
  zpty -wn a q; sleep 0.3; zpty -d a 2>/dev/null; print -r -- $out' - "$common/otis-verify/b-live" | screen)
# A frame is cursor moves, not lines: the matches are counted, not the lines.
expect agent/criteria "$(printf '%s\n' "$agent" | grep -o '● c1 \|◌ c2 \|○ c3 ' | sort -u | wc -l | tr -d ' ')" "3"
expect agent/now "$(printf '%s\n' "$agent" | grep -o 'bazel test //c:d' | wc -l | tr -d ' ')" "3"
expect agent/cost "$(printf '%s\n' "$agent" | grep -q 'Cursor \$2\.25' && echo shown)" "shown"
rm -rf "$common/otis-verify/b-live"
# A browser step answers with content blocks, not a string: it is a step and
# what it returned like any other, and the stream goes on after it (the
# blocks used to end jq, and with it everything the tester did next).
expect cursor-events/browser-step "$(printf '%s\n' \
  '{"event":"tool_call","data":{"callId":"t1","name":"mcp","status":"running","args":{"toolName":"browser_navigate","args":{"url":"http://localhost:3000/a"}}}}' \
  '{"event":"tool_call","data":{"callId":"t1","name":"mcp","status":"completed","args":{"toolName":"browser_navigate","args":{"url":"http://localhost:3000/a"}},"result":{"success":{"content":[{"text":{"text":"### Result\nok"}},{"image":{"data":"AAAA"}}]}}}}' \
  '{"event":"assistant","data":{"text":"It loaded."}}' \
  '{"event":"result","data":{}}' |
  jq -R -n -c -f "$share/cursor-events.jq" | jq -r '[.type, (.input.detail // .text // "" | gsub("\n"; "/"))] | join("=")' | tr '\n' '|')" \
  "tool=browser navigate http://localhost:3000/a|output=browser navigate: ### Result/ok|text=It loaded.|result=|"
# A verdict is two answers (tally): whether the change does what it says, by
# the plan's own criteria, and what it did around that, by the breaker's
# checks. What it broke fails it; what it only changed beyond its description
# is a question, with how it was before; and neither counts against what it
# says. The screens say sentences, not ids.
v=$common/otis-verify/b-two; mkdir -p "$v"
printf 'done\n' > "$v/status"; printf 'Verifying two\n' > "$v/title"
printf '%s\n' '{"criteria":[{"id":"c1","plain":"A reply shows in the thread.","claim":"x"},{"id":"b1","kind":"attack","plain":"An order counts once.","claim":"y"},{"id":"b2","kind":"attack","plain":"The drawer still shows only its own texts.","claim":"z"},{"id":"b3","kind":"attack","plain":"Old rows still load.","claim":"w"}]}' > "$v/plan.json"
printf '%s\n' '{"verdict":"fail","summary":"s","concerns":[],"criteria":[{"id":"c1","result":"verified","saw":"It shows.","was":""},{"id":"b1","result":"failed","saw":"An order recorded twice counts twice.","was":""},{"id":"b2","result":"changed","saw":"The drawer now also shows agent texts.","was":"only its own texts"},{"id":"b3","result":"unverified","saw":"No old rows here.","was":""}]}' > "$v/verdict.json"
expect verify/two-answers "$(FZF_PREVIEW_COLUMNS=80 git-verify --preview "" two | strip | grep . | sed 's/  *$//')" "VERIFICATION  failed  ·  does what it says, 1 of 1
BROKE  1
  ✗  An order recorded twice counts twice.
ALSO CHANGED  1, not in the description
  ?  The drawer now also shows agent texts.
     Before: only its own texts
  the full report · 1 check around it not run"
expect verify/two-answers-panel "$(FZF_PREVIEW_COLUMNS=80 git-agent-preview "$v" | strip | sed -n 2p)" "▌ does what it says, 1 of 1; broke 1; also changed 1"
# With nothing broken, a change the description does not mention leaves a pass a pass.
jq -c '.verdict = "pass" | .criteria |= map(select(.id != "b1"))' "$v/verdict.json" > "$v/verdict.json.new" && mv "$v/verdict.json.new" "$v/verdict.json"
expect verify/changed-passes "$(FZF_PREVIEW_COLUMNS=80 git-verify --preview "" two | strip | grep . | sed -n '1,2p')" "VERIFICATION  passed  ·  does what it says, 1 of 1
ALSO CHANGED  1, not in the description"
rm -rf "$v"
# Leaving what enter opened comes back to the dashboard's own rows.
expect otis-do/run "$(otis-do enter run run "$common/gmr-fix/b-feature" "" "" "" "" "" "" "" "")" "execute(git-mr-fix 'b-feature' '')+execute-silent(git-fzf-bg otis-list)"
# A verification opens through git-verify, so r there starts it again.
expect agent-list/open-verify "$(git-agent-list --open "$common/otis-verify/b-a%b" back)" "execute(git-verify --branch 'a/b')+back"
expect otis-do/gone "$(GIT_FZF_STATE=$tmp/dash otis-do enter run run "$common/gmr-fix/nope" "" "" "" "" "" "" "" "" >/dev/null; strip < "$tmp/dash/note")" "that run is not here any more"
# y on a run copies its folder and what is in it, for Claude; the clipboard
# here is a file, so the tests never touch yours.
mkdir -p "$tmp/clip" "$common/otis-verify/b-y/artifacts"
printf '#!/bin/sh\ncat > "%s/clip/got"\n' "$tmp" > "$tmp/clip/pbcopy" && chmod +x "$tmp/clip/pbcopy"
printf 'Verifying y\n' > "$common/otis-verify/b-y/title" && printf '{"verdict":"pass"}\n' > "$common/otis-verify/b-y/verdict.json"
touch "$common/otis-verify/b-y/artifacts/a.log"
GIT_FZF_STATE=$tmp/dash PATH=$tmp/clip:$PATH otis-do copy run run "$common/otis-verify/b-y" "" "" "" "" "" "" "" "" >/dev/null
expect otis-do/copy-run "$(sed -n 1p "$tmp/clip/got"):$(grep -c 'verdict.json\|artifacts/ .*1 files' "$tmp/clip/got")" "An otis verification, \"Verifying y\", verdict: pass.:2"
# y in the run's own screen copies the same.
rm -f "$tmp/clip/got"; GIT_FZF_STATE=$tmp/dash PATH=$tmp/clip:$PATH git-claude-view --copy "$common/otis-verify/b-y" >/dev/null
expect otis-agent/copy-run "$(sed -n 1p "$tmp/clip/got")" "An otis verification, \"Verifying y\", verdict: pass."
# y on a branch with no MR yet has no link to copy: its name.
rm -f "$tmp/clip/got"; GIT_FZF_STATE=$tmp/dash PATH=$tmp/clip:$PATH otis-do copy run goto a/b "" "" "" a/b "" "" "" "" >/dev/null
expect otis-do/copy-branch "$(cat "$tmp/clip/got"):$(strip < "$tmp/dash/note")" "a/b:copied a/b"
expect otis-do/sep "$(GIT_FZF_STATE=$tmp/dash otis-do enter sep "" "" "" "" "" "" "" "" "" "" >/dev/null; strip < "$tmp/dash/note")" "that row is a section heading"
expect otis-do/mr "$(otis-do enter review mr "" 42 main u b h ba 9 st)" "execute(git-mr-review {2} {3} {4} {5} {7} {8} {12})"
# The three ways of being done with a fix, none of which leaves it waiting:
# folded into your commits, applied to your checkout, or on a branch of its own.
printf 'patch\n' > "$common/gmr-fix/b-feature/02.patch"
printf 'patch\n' > "$common/gmr-fix/b-feature/03.patch"
printf 'patch\n' > "$common/gmr-fix/b-feature/04.patch"
expect mr-fix/marks-all-waiting "$(git-mr-fix --marks | jq -r '.["b-feature"].fixes')" "4"
printf '2\n' > "$common/gmr-fix/b-feature/folded"
printf '3\n' > "$common/gmr-fix/b-feature/applied"
printf '4\n' > "$common/gmr-fix/b-feature/branched"
expect mr-fix/marks-branched-done "$(git-mr-fix --marks | jq -r '.["b-feature"].fixes')" "1"
expect otis-list/fixes-left "$(GIT_FZF_STATE=$tmp/dash otis-list | strip | awk -F'\t' '$11 == "w-fix-b-feature" { print $1 }' | tr -s ' ')" " ✎1 fold in 1 fix feature"
rm -f "$common/gmr-fix/b-feature"/0[234].patch "$common/gmr-fix/b-feature/folded" \
  "$common/gmr-fix/b-feature/applied" "$common/gmr-fix/b-feature/branched"
# d discards one you do not want, which is the fourth way of being done with a
# proposal and the only one that takes nothing. It asks first, and takes it back
# without asking, since nothing was destroyed either way.
printf 'patch\n' > "$common/gmr-fix/b-feature/02.patch"
printf '2\n' > "$common/gmr-fix/b-feature/accepted"
printf '2\n' > "$common/gmr-fix/b-feature/declined"
expect mr-fix/marks-discarded "$(git-mr-fix --marks | jq -r '.["b-feature"].fixes')" "1"
expect otis-list/discarded "$(GIT_FZF_STATE=$tmp/dash otis-list | strip | awk -F'\t' '$11 == "w-fix-b-feature" { print $1 }' | tr -s ' ')" " ✎1 fold in 1 fix feature"
# d on a discarded one takes it back with no question asked, and it counts again.
git-mr-fix --discard b-feature 2 </dev/null
expect mr-fix/undiscard "$(cat "$common/gmr-fix/b-feature/declined")" ""
expect mr-fix/undiscard-counts "$(git-mr-fix --marks | jq -r '.["b-feature"].fixes')" "2"
# space on a discarded one is you changing your mind: the discard goes and it is accepted.
printf '2\n' > "$common/gmr-fix/b-feature/declined"
: > "$common/gmr-fix/b-feature/accepted"
git-mr-fix --toggle b-feature 2 >/dev/null
expect mr-fix/space-undiscards "$(cat "$common/gmr-fix/b-feature/declined")" ""
expect mr-fix/space-accepts "$(cat "$common/gmr-fix/b-feature/accepted")" "2"
# One already dealt with is refused rather than discarded.
printf '2\n' > "$common/gmr-fix/b-feature/folded"
expect mr-fix/discard-refused "$(git-mr-fix --discard b-feature 2 </dev/null | head -1)" "that one is folded into your commits already. press enter"
rm -f "$common/gmr-fix/b-feature"/02.patch "$common/gmr-fix/b-feature/folded" \
  "$common/gmr-fix/b-feature/accepted" "$common/gmr-fix/b-feature/declined"
# D discards what otis is telling you, and nothing else: a merge request's own
# state is the merge request's to change.
expect otis-do/dismiss-refused "$(GIT_FZF_STATE=$tmp/dash otis-do dismiss mine mr "" 42 "" "" "" "" "" "" "" >/dev/null; strip < "$tmp/dash/note")" "otis discards what it is telling you, the agents' fixes and their runs' verdicts; that row is the merge request's own state"
expect otis-do/dismiss-gone "$(GIT_FZF_STATE=$tmp/dash otis-do dismiss run run "$common/gmr-fix/nope" "" "" "" "" "" "" "" "" >/dev/null; strip < "$tmp/dash/note")" "that run is not here any more"
# Discarding a whole run asks first, and git-confirm reads the terminal, so
# with none there is nothing discarded: the confirm is not a formality.
printf 'patch\n' > "$common/gmr-fix/b-feature/02.patch"
git-mr-fix --discard-rest b-feature </dev/null >/dev/null 2>&1
expect mr-fix/discard-rest-asks "$(cat "$common/gmr-fix/b-feature/declined" 2>/dev/null)" ""
expect mr-fix/discard-rest-waiting "$(git-mr-fix --marks | jq -r '.["b-feature"].fixes')" "2"
rm -f "$common/gmr-fix/b-feature"/02.patch
# A verdict you have said you have seen, and what you saw when you did.
mkdir -p "$common/otis-verify/99" && printf 'abc123\n' > "$common/otis-verify/99/seen"
GIT_FZF_STATE=$tmp/dash otis-list >/dev/null
expect otis-list/seen-scan "$(cat "$tmp/dash/seen.tsv")" "otis-verify/99	abc123"
rm -rf "$common/otis-verify"
# A run that failed waits on you until you have seen it, and comes back when
# it fails again; a branch's verdict shows as an MR's does.
v=$common/otis-verify/b-feature
mkdir -p "$v" && printf '100\n' > "$v/started" && printf '200\n' > "$v/ended" && printf 'failed\n' > "$v/status"
failed_row() { GIT_FZF_STATE=$tmp/dash otis-list | strip | awk -F'\t' '$11 == "w-failed-otis-verify-b-feature" { print $1 }' | awk '{ print $2, $3, $4 }'; }
expect otis-list/failed-run "$(failed_row)" "verify never finished"
printf '#!/bin/sh\n' > "$tmp/yes" && mkdir -p "$tmp/yesbin" && mv "$tmp/yes" "$tmp/yesbin/git-confirm" && chmod +x "$tmp/yesbin/git-confirm"
expect otis-do/dismiss-asks "$(otis-do dismiss run run "$v" "" "" "" "" "" "" "" "")" 'execute(otis-do confirm {6} {14} {13} {2} {3} {4} {5} {7} {8} {9} {12})+execute-silent(git-fzf-bg otis-list)'
PATH=$tmp/yesbin:$PATH otis-do confirm run run "$v" "" "" "" "" "" "" "" ""
expect otis-do/dismiss-failed "$(cat "$v/seen")" "200"
expect otis-list/failed-seen "$(failed_row)" ""
printf '300\n' > "$v/ended"
expect otis-list/failed-again "$(failed_row)" "verify never finished"
printf 'done\n' > "$v/status" && printf 'abc\n' > "$v/head" && printf '{"verdict":"fail"}\n' > "$v/verdict.json"
expect otis-list/branch-verdict "$(GIT_FZF_STATE=$tmp/dash otis-list | strip | awk -F'\t' '$11 == "w-verify-b-feature" { print $1 }' | tr -s ' ')" " ● verified: failed feature"
rm -rf "$common/otis-verify" "$tmp/yesbin"

# Your merged MRs on their way to production, from a seeded cache so nothing
# asks GitLab: each state lands in the section that fits it, and a live one
# says nothing at all.
git remote set-url origin git@gitlab.example.com:g/r.git
cache=$common/git-alias-cache
mkdir -p "$cache" && echo '{}' > "$cache/mrs-review.json" && echo '{}' > "$cache/ci-mine.json"
echo '{"deploys": []}' > "$cache/deploys.json"
jq -n '{mrs: [
  {iid:"101",title:"Deploying one",sourceBranch:"a",targetBranch:"main",mergedAt:"2026-01-01T00:00:00Z",webUrl:"u",state:"deploying",deploy:{pipeline:"900",url:"d"}},
  {iid:"102",title:"Queued one",sourceBranch:"b",targetBranch:"main",mergedAt:"2026-01-01T00:01:00Z",webUrl:"u",state:"queued",deploy:{pipeline:"901",url:"d"}},
  {iid:"103",title:"Waiting one",sourceBranch:"c",targetBranch:"main",mergedAt:"2026-01-01T00:02:00Z",webUrl:"u",state:"waiting"},
  {iid:"104",title:"Stacked one",sourceBranch:"d",targetBranch:"e",mergedAt:"2026-01-01T00:03:00Z",webUrl:"u",state:"branch"},
  {iid:"105",title:"Rolled back one",sourceBranch:"f",targetBranch:"main",mergedAt:"2026-01-01T00:04:00Z",webUrl:"u",state:"rolledback",deploy:{pipeline:"902",url:"d"}},
  {iid:"106",title:"Live one",sourceBranch:"g",targetBranch:"main",mergedAt:"2026-01-01T00:05:00Z",webUrl:"u",state:"live",deploy:{pipeline:"903",url:"d"}}]}' > "$cache/ci-merged.json"
rows=$(GIT_FZF_STATE=$tmp/dash otis-list)
expect otis-list/shipping "$(printf '%s\n' "$rows" | strip | awk -F'\t' '$11 ~ /^g-merged-/ { print $11 "=" $1 }' | sed 's/  */ /g; s/ merged .*//' | tr '\n' ' ')" "g-merged-104= · !104 merged, not on main g-merged-103= · !103 merged, not out yet g-merged-102= ○ !102 queued to deploy g-merged-101= ◐ !101 deploying "
expect otis-list/rolled-back "$(printf '%s\n' "$rows" | strip | awk -F'\t' '$11 == "w-mr-105" { print $1 }' | tr -s ' ')" " ▼ !105 rolled back Rolled back one"
expect otis-list/rolled-back-key "$(printf '%s\n' "$rows" | awk -F'\t' '$11 == "w-mr-105" { print $14 }')" "rollback"
expect otis-do/rolled-back-dismiss "$(otis-do dismiss merged rollback '' 105 main u f '' '' '' '' | grep -c 'otis-do confirm')" "1"
printf 'rollback/105\trolledback\n' >> "$common/otis-dismissed"
expect otis-list/rolled-back-dismissed "$(GIT_FZF_STATE=$tmp/dash otis-list | grep -c 'w-mr-105')" "0"
rm -f "$common/otis-dismissed"
expect otis-list/live-is-quiet "$(printf '%s\n' "$rows" | grep -c '106')" "0"
# The deploy of its own only shows while it is carrying none of yours.
jq -n '{deploys:[{id:7,status:"running",kind:"deploy",sha:"abc",at:"2026-01-01T00:06:00Z",duration:0,pipeline:"900",url:"u",mrs:["101"]}]}' > "$cache/deploys.json"
expect otis-list/deploy-stands-down "$(GIT_FZF_STATE=$tmp/dash otis-list | awk -F'\t' '$11 ~ /^g-deploy-/' | wc -l | tr -d ' ')" "0"
jq '.mrs |= map(if .state == "deploying" or .state == "queued" then .state = "live" else . end)' "$cache/ci-merged.json" > "$cache/m.tmp" && mv "$cache/m.tmp" "$cache/ci-merged.json"
expect otis-list/deploy-alone "$(GIT_FZF_STATE=$tmp/dash otis-list | awk -F'\t' '$11 ~ /^g-deploy-/' | wc -l | tr -d ' ')" "1"
rm -rf "$cache"
git remote set-url origin https://code.example.com/x/y.git
rm -rf "$common/gmr-fix"
# The trash: a worktree otis took out of the way rather than deleting, which
# keeps what git would have dropped with it, and the row that says so.
# The kept file has to be ignored, or git refuses to remove the worktree at
# all, which is the point: the trash is for what git would have dropped.
printf '*.o\n' >> "$common/info/exclude"
git worktree add -q "$tmp/repo/.claude/worktrees/spare" -b spare
printf 'build\n' > "$tmp/repo/.claude/worktrees/spare/local.o"
git-worktree-trash "$tmp/repo/.claude/worktrees/spare"
expect trash/gone "$(git worktree list | grep -c spare)" "0"
expect trash/noted "$(git-worktree-trash --list | awk -F'\t' '{ print $4 }')" "spare"
expect trash/keeps-ignored "$(cat "$trash"/spare-*/local.o 2>/dev/null)" "build"
expect trash/not-a-checkout "$(ls -a "$trash"/spare-*/.git 2>/dev/null | wc -l | tr -d ' ')" "0"
rows=$(GIT_FZF_STATE=$tmp/dash otis-list)
expect otis-list/trash "$(printf '%s\n' "$rows" | strip | awk -F'\t' '$11 == "trash" { print $1 }' | tr -s ' ' | sed -E 's/[0-9]+[smhd] ago/just now/')" " $(printf '\357\207\270') 1 in the trash a worktree you removed, just now"
expect otis-list/trash-under-here "$(printf '%s\n' "$rows" | awk -F'\t' '{ print $11 }' | tail -2 | tr '\n' ' ')" "here trash "
expect otis-do/trash "$(otis-do enter trash trash "$trash" "" "" "" "" "" "" "" "")" "execute-silent(otis-open '$trash')"
# Emptying the trash forgets it, so the count is what the trash actually holds.
rm -rf "$trash"/spare-*
expect trash/pruned "$(git-worktree-trash --list | wc -l | tr -d ' ')" "0"
expect otis-list/trash-gone "$(GIT_FZF_STATE=$tmp/dash otis-list | awk -F'\t' '$11 == "trash"' | wc -l | tr -d ' ')" "0"
git branch -D spare >/dev/null 2>&1
sed -i.bak '/^\*\.o$/d' "$common/info/exclude" && rm -f "$common/info/exclude.bak"
