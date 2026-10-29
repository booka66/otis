#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-mr-lines, git-mr-say: comment on an MR from a picker, without nvim.
# GitLab is a stub answering from fixtures and keeping what it was sent.
here=$PWD mr=$tmp/mr-lines
git init -q "$mr" && cd "$mr" && git config user.email t@t && git config user.name t
printf 'a\nb\nc\nd\ne\nf\ng\nh\n' > f.ts && git add f.ts && git commit -qm base
printf 'a\nB\nc\nd\ne\nf\ng\nh\nnew\n' > f.ts && git commit -qam change
b=$(git rev-parse HEAD~1) h=$(git rev-parse HEAD)
mkdir -p "$tmp/glabstub"
cat > "$tmp/glabstub/glab" <<STUB
#!/bin/sh
case "\$*" in
  *discussions\?per_page*) cat <<'J'
[{"id":"abc","resolvable":true,"resolved":false,"notes":[{"id":1,"body":"why capital?","author":{"username":"sam"},"created_at":"2026-09-01",
   "position":{"new_path":"f.ts","old_path":"f.ts","new_line":2,"head_sha":"$h","base_sha":"$b"}}]},
 {"id":"def","resolvable":true,"resolved":true,"notes":[{"id":2,"body":"was fine","author":{"username":"kim"},"created_at":"2026-09-01",
   "position":{"new_path":"f.ts","old_path":"f.ts","old_line":2,"head_sha":"$h","base_sha":"$b"}}]}]
J
    ;;
  *draft_notes\?per_page*) echo '[]' ;;
  "api projects/:fullpath/merge_requests/7") echo '{"diff_refs":{"base_sha":"$b","start_sha":"$b","head_sha":"$h"}}' ;;
  "api user") echo '{"username":"sam"}' ;;
  *"-X POST"*|*"-X PUT"*) { echo "\$*"; cat; echo; } >> "$tmp/glab.posted"; echo '{}' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$tmp/glabstub/glab"
PATH=$tmp/glabstub:$PATH
lst=$tmp/lines-state && mkdir -p "$lst"
GIT_FZF_STATE=$lst GMR_LINES_PATH=f.ts git-mr-lines --list 7 "$b..$h" >/dev/null
# Each thread under the line it is on, the removed line's under the removed line.
expect mr-lines/rows "$(cut -f8 "$lst/lines.rows" | tr '\n' ' ')" "h1 n1 o2 tdef n2 tabc n3 n4 n5 n6 n7 n8 n9 "
expect mr-lines/thread-row "$(sed -n 6p "$lst/lines.rows" | cut -f1 | strip | grep -c '┆ .*open  *sam  *why capital?$')" "1"
expect mr-lines/footer "$(strip < "$lst/footer")" "1 unresolved"
expect mr-lines/start "$(GIT_FZF_STATE=$lst FZF_TOTAL_COUNT=13 git-mr-lines --start 5)" "unbind(result)+pos(9)"
# ] from the top lands on the hunk's first line, the row under its rule;
# there is no hunk after it, and [ from below goes back to it.
expect mr-lines/next-hunk "$(GIT_FZF_STATE=$lst git-mr-lines --hunk 1 0)" "pos(2)"
expect mr-lines/no-next-hunk "$(GIT_FZF_STATE=$lst git-mr-lines --hunk 1 5)" ""
expect mr-lines/previous-hunk "$(GIT_FZF_STATE=$lst git-mr-lines --hunk -1 8)" "pos(2)"
expect mr-lines/start-waits-for-rows "$(GIT_FZF_STATE=$lst FZF_TOTAL_COUNT=0 git-mr-lines --start 5)" ""
expect mr-lines/c-on-a-line "$(GIT_FZF_STATE=$lst git-mr-lines --comment 7 r line '' n2)" \
  'execute(git-mr-say --new 7 r "$GMR_LINES_PATH" new 2 2)+clear-selection+reload(git-mr-lines --list 7 r)'
expect mr-lines/c-on-marked-lines "$(GIT_FZF_STATE=$lst git-mr-lines --comment 7 r line '' n9 n2 tabc n3)" \
  'execute(git-mr-say --new 7 r "$GMR_LINES_PATH" new 2 9)+clear-selection+reload(git-mr-lines --list 7 r)'
GIT_FZF_STATE=$lst git-mr-lines --comment 7 r line '' o2 n2 >/dev/null
expect mr-lines/c-one-side "$(cat "$lst/note")" "one comment spans one side: removed lines, or the rest, not both"
expect mr-lines/c-on-a-thread "$(GIT_FZF_STATE=$lst git-mr-lines --comment 7 r thread abc tabc)" \
  "execute(git-mr-say --reply 7 r abc)+reload(git-mr-lines --list 7 r)"
# J marks lines as it moves, and c comments across them.
if picker_open "GMR_KIND=review git-mr-lines 7 $b..$h f.ts 2"; then
  picker_rows >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    at=$(picker_state | jq -r '.current.text' | cut -f8); [ "$at" = n2 ] && break; sleep 0.25
  done
  expect mr-lines/starts-at-the-line "$at" "n2"
  picker_key J; picker_key J; picker_key J
  expect mr-lines/J-marks "$(picker_state | jq -c '[.selected[].text | split("\t")[7]]')" '["n2","tabc","n3"]'
  picker_close
else
  expect mr-lines/picker-opens "no" "yes"
fi
# Where a comment goes (git-mr-position): a removed line, a kept one after
# the change, and a range across both kinds, anchored on its last line.
expect mr-position/removed "$(git-mr-position "$b" "" "$h" f.ts old 2 2 | jq -c '[.old_line, .new_line, .line_range.end.type, .line_range.end.new_line]')" '[2,null,"old",0]'
expect mr-position/kept "$(git-mr-position "$b" "" "$h" f.ts new 5 5 | jq -c '[.old_line, .new_line, .line_range.end.type, has("start_sha")]')" '[5,5,"",false]'
expect mr-position/range "$(git-mr-position "$b" "$b" "$h" f.ts new 2 4 | jq -c '[.line_range.start.type, .line_range.start.old_line, .new_line, .start_sha == "'"$b"'"]')" '["new",0,4,true]'
# A range from a removed line to the line added for it: each end on its own side.
expect mr-position/mixed "$(git-mr-position "$b" "" "$h" f.ts old,new 2 2 | jq -c '[.line_range.start.type, .line_range.start.old_line, .line_range.end.type, .line_range.end.new_line, .new_line]')" '["old",2,"new",2,2]'
# Typed at the prompt, enter: a draft on the added line, placed as nvim would.
rm -f "$tmp/glab.posted"
if picker_open "GMR_KIND=review git-mr-say --new 7 $b..$h f.ts new 2 2"; then
  picker_key "why capital"
  picker_key "$(printf '\r')"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$tmp/glab.posted" ] && break; sleep 0.25; done
  exec 7>&-; wait "$driver" 2>/dev/null
  expect mr-say/posts-a-draft "$(head -1 "$tmp/glab.posted" | grep -c 'merge_requests/7/draft_notes')" "1"
  expect mr-say/body "$(sed 1d "$tmp/glab.posted" | jq -c '[.note, .position.new_line, .position.old_line, .position.line_range.start.type, .position.head_sha == "'"$h"'"]')" \
    '["why capital",2,null,"new",true]'
else
  expect mr-say/prompt-opens "no" "yes"
fi
# The text given (otis-symbols' box, typed under the lines): nothing asked,
# the same draft posted, a reply in its thread; a failure is one line saying
# why, with no prompt to wait at.
rm -f "$tmp/glab.posted"
GMR_KIND=review git-mr-say --new 7 "$b..$h" f.ts new 2 2 'given words' </dev/null >/dev/null
expect mr-say/given-body "$(sed 1d "$tmp/glab.posted" | jq -c '[.note, .position.new_line]')" '["given words",2]'
rm -f "$tmp/glab.posted"
GIT_FZF_STATE=$lst GMR_KIND=review git-mr-say --reply 7 "$b..$h" abc 'me too' </dev/null >/dev/null
expect mr-say/given-reply "$(sed 1d "$tmp/glab.posted" | jq -c '[.note, .in_reply_to_discussion_id]')" '["me too","abc"]'
expect mr-say/given-fails "$(GMR_KIND=review git-mr-say --new 7 "$b..$b" f.ts new 2 2 'stale' </dev/null; echo "exit $?")" \
  "the MR has moved on since this review opened, so these line numbers are not its own; u catches up
exit 1"
# e in the box: your comment as it says now (--was), then saved as given.
expect mr-say/was "$(GIT_FZF_STATE=$lst git-mr-say --was 7 "$b..$h" abc </dev/null)" "why capital?"
rm -f "$tmp/glab.posted"
GIT_FZF_STATE=$lst GMR_KIND=review git-mr-say --edit 7 "$b..$h" abc 'why capital, really?' </dev/null >/dev/null
expect mr-say/given-edit "$(head -1 "$tmp/glab.posted" | grep -c 'X PUT projects/:fullpath/merge_requests/7/discussions/abc/notes/1')|$(sed 1d "$tmp/glab.posted" | jq -r .body)" "1|why capital, really?"
# e, without nvim: your comment in the thread, at the prompt with what it
# says, and saved in place.
rm -f "$tmp/glab.posted"
if picker_open "GIT_FZF_STATE=$lst git-mr-say --edit 7 $b..$h abc"; then
  picker_key " really"
  picker_key "$(printf '\r')"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$tmp/glab.posted" ] && break; sleep 0.25; done
  exec 7>&-; wait "$driver" 2>/dev/null
  expect mr-say/edits-yours "$(head -1 "$tmp/glab.posted" | grep -c -- '-X PUT projects/:fullpath/merge_requests/7/discussions/abc/notes/1')" "1"
  expect mr-say/edit-body "$(sed 1d "$tmp/glab.posted" | jq -r .body)" "why capital? really"
else
  expect mr-say/edit-prompt-opens "no" "yes"
fi
PATH=${PATH#"$tmp/glabstub:"}
cd "$here"

# --- git-ci-merge --check: m merges what can merge, sets auto-merge on what
# only has to wait, and says why for the rest. GitLab is a stub, one MR per
# iid.
mkdir -p "$tmp/mgstub" "$tmp/mgstate"
cat > "$tmp/mgstub/glab" <<'STUB'
#!/bin/sh
mr() { printf '{"detailed_merge_status":"%s","merge_when_pipeline_succeeds":%s,"head_pipeline":%s}\n' "$@"; }
case $2 in
  */1\?*) mr mergeable false '{"id":1}' ;;
  */2\?*) mr not_approved false '{"id":1}' ;;
  */3\?*) mr not_approved true '{"id":1}' ;;
  */4\?*) mr ci_must_pass false '{"id":1}' ;;
  */5\?*) mr ci_must_pass false null ;;
  */6\?*) mr discussions_not_resolved false '{"id":1}' ;;
  */7\?*) mr draft_status false '{"id":1}' ;;
  */8\?*) mr conflict false '{"id":1}' ;;
  */9\?*) mr conflict false '{"id":1}' | jq -c '. + {has_conflicts: false}' ;;
  */9) mr mergeable false '{"id":1}' ;;
esac
STUB
chmod +x "$tmp/mgstub/glab"
mcheck() { PATH=$tmp/mgstub:$PATH GIT_FZF_STATE=$tmp/mgstate git-ci-merge --check "$1"; }
expect ci-merge/mergeable-merges "$(mcheck 1)" "execute(git-ci-merge 1)"
expect ci-merge/unapproved-sets-auto "$(mcheck 2)" "execute(git-ci-merge --auto 2 not_approved)"
expect ci-merge/already-set "$(mcheck 3; cat "$tmp/mgstate/note")" "ignore
!3 is already set to merge itself: it still needs approval"
expect ci-merge/failed-pipeline-sets-auto "$(mcheck 4)" "execute(git-ci-merge --auto 4 ci_must_pass)"
expect ci-merge/no-pipeline-starts-one "$(mcheck 5)" "execute(git-ci-merge --run 5)"
expect ci-merge/threads-set-auto "$(mcheck 6)" "execute(git-ci-merge --auto 6 discussions_not_resolved)"
expect ci-merge/draft-refused "$(mcheck 7; cat "$tmp/mgstate/note")" "ignore
!7 can't merge yet: it is a draft; R marks it ready"
expect ci-merge/conflict-refused "$(mcheck 8; cat "$tmp/mgstate/note")" "ignore
!8 can't merge yet: it has conflicts; gup to rebase"
# A conflict GitLab found before a push it has not looked at since
# (has_conflicts false) is not one yet: m waits for the recheck it asked for.
expect ci-merge/stale-conflict-rechecked "$(mcheck 9)" "execute(git-ci-merge 9)"

# --- git-mr-mine: o on one of yours opens it where your branch is checked
# out, which follows GitLab's when that loses nothing. GitLab's list can trail
# a push by minutes, so the head it says is fetched, never taken over the
# branch. A rebase is asked only when each side has commits of its own; the
# stub answers no.
here=$PWD mm=$tmp/mm
mkdir -p "$mm/stub" && git init -q --bare "$mm/origin.git"
git init -q "$mm/work" && cd "$mm/work" && git config user.email t@t && git config user.name t
printf 'a\n' > f && git add f && git commit -qm base && git branch -qM main
git checkout -qb feat && printf 'b\n' > g && git add g && git commit -qm change
git remote add origin "$mm/origin.git" && git push -q origin main feat
git clone -q "$mm/origin.git" "$mm/gitlab" 2>/dev/null && git -C "$mm/gitlab" config user.email g@g && git -C "$mm/gitlab" config user.name g
printf '#!/bin/sh\necho "$1" >> "$MM/asked"; exit 1\n' > "$mm/stub/git-confirm"
printf '#!/bin/sh\necho "$2" >> "$MM/said"\n' > "$mm/stub/otis-popup"
printf '#!/bin/sh\n' > "$mm/stub/git-mr-files"
chmod +x "$mm/stub/"*
# mm_open <the head GitLab's list says>: o on !5, then where feat is, and how many questions and popups.
mm_open() {
  : > "$mm/asked"; : > "$mm/said"
  PATH=$mm/stub:$PATH MM=$mm git-mr-mine 5 main url feat "$1" "$(git rev-parse main)" >/dev/null 2>&1
  printf '%s %s %s\n' "$(git rev-parse feat)" "$(grep -c . "$mm/asked")" "$(grep -c . "$mm/said")"
}
# mm_gitlab: feat rewritten on GitLab from another checkout.
mm_gitlab() { (cd "$mm/gitlab" && git fetch -q origin && git checkout -q -B feat origin/feat && echo "$1" >> g && git commit -qa --amend -m "$1" && git push -q --force origin feat) >/dev/null 2>&1; }
mm_was=$(git rev-parse feat)
echo again >> g && git commit -qa --amend -m again && git push -q --force origin feat
mm_now=$(git rev-parse feat)
expect mr-mine/list-trailing-a-push-is-not-taken "$(mm_open "$mm_was"; git rev-parse origin/feat)" "$mm_now 0 0
$mm_now"
mm_gitlab elsewhere
expect mr-mine/old-copy-follows "$(mm_open "$(git --git-dir="$mm/origin.git" rev-parse feat)")" "$(git --git-dir="$mm/origin.git" rev-parse feat) 0 0"
echo mine >> g && git commit -qa --amend -m mine && mm_now=$(git rev-parse feat)
expect mr-mine/rewritten-here-is-kept "$(mm_open "$(git rev-parse origin/feat)"; grep -c 'not pushed yet' "$mm/said")" "$mm_now 0 1
1"
mm_gitlab again
expect mr-mine/both-moved-asks "$(mm_open "$(git --git-dir="$mm/origin.git" rev-parse feat)")" "$mm_now 1 1"
cd "$here"

