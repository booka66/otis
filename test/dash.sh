#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- the dashboard (otis-dash) in a pty, and what a screen's caches do
# behind it. feature is a commit past main.
git switch -q -c feature && printf 'f\n' > f.ts && git add f.ts && git commit -qm "Feature" && git switch -q main
# The dashboard (otis-dash), in a pty: origin is a path here, so it draws
# from the checkout alone, the here row and nothing needing you, with the
# repo's other branches folded in a group under it; gb hands gb to the otis
# function to run, and that is all the dashboard prints, the keys' help (?)
# having been open or not: anything else with it and otis would not know
# what it was handed, and would just close.
# upto <text>...: read the pty until each text is in what it drew since the last upto.
dash=$(TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; setopt extendedglob; zpty -b d "stty rows 40 cols 100; otis-dash > $1"; out= all=
  upto() { for _ in {1..200}; do while zpty -rt d buf; do out+=$buf; done; s=${out//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/} m=1; for p; do [[ $s == *"$p"* ]] || m=; done; [[ -n $m ]] && break; sleep 0.1; done; all+=$out; out=; }
  upto "nothing to commit" "nothing needs you" "V verify  c commits  y link  F files  ? keys"
  all+=$'"'"'\n@@j\n'"'"'; zpty -wn d j; sleep 0.3; while zpty -rt d buf; do out+=$buf; done
  zpty -wn d "?"; upto "? or q back to the board"; zpty -wn d "?"; upto "? keys"
  zpty -wn d g; zpty -wn d b; for _ in {1..20}; do while zpty -rt d buf; do out+=$buf; done; zpty -t d || break; sleep 0.1; done
  zpty -d d 2>/dev/null; print -r -- $all$out' - "$tmp/dash.handed" | screen)
expect otis/quiet "$(printf '%s\n' "$dash" | grep -q 'nothing needs you' && echo said)" "said"
expect otis/here "$(printf '%s\n' "$dash" | grep -o 'main *nothing to commit or push' | head -1 | tr -s ' ')" "main nothing to commit or push"
# Nothing uncommitted and nothing past the base: enter has nothing to do on
# the row it opens on, so the footer has no enter, only the keys that act on
# a branch with no MR (no w, with no MR to open) and the one that lists the
# rest.
expect otis/enter-says "$(printf '%s\n' "$dash" | sed '/^@@j$/,$d' | grep -c '⏎'):$(printf '%s\n' "$dash" | sed '/^@@j$/,$d' | grep -c 'V verify  c commits  y link  F files  ? keys')" "0:1"
# ? is every key there is, from the one table, on one screen in two
# columns, and the footer says how to leave it.
expect otis/help "$(printf '%s\n' "$dash" | grep -c 'MOVING *ON A CHANGE'):$(printf '%s\n' "$dash" | grep -c 'down and up *V *verify it in Cursor Cloud'):$(printf '%s\n' "$dash" | grep -c 'ON A MERGE REQUEST'):$(printf '%s\n' "$dash" | grep -c '? or q back to the board')" "1:1:1:1"
expect otis/b-hands-over "$(cat "$tmp/dash.handed")" "gb"
# A change's row says its move, then its title: a board of MR 7, which is
# ready to merge, handed over by stand-ins for otis-list and otis-board (and
# one for otis-preview, which would ask a forge).
bnode() { printf '{"iid": "%s", "title": "%s", "sourceBranch": "%s", "targetBranch": "main", "webUrl": "u", "draft": false, "approved": true, "autoMergeEnabled": false, "detailedMergeStatus": "MERGEABLE", "updatedAt": "2026-01-01T00:00:00Z", "diffRefs": {"headSha": "new"}, "headPipeline": {"status": "SUCCESS"}, "reviewers": {"nodes": [{"username": "ann", "mergeRequestInteraction": {"reviewState": "APPROVED"}}]}}' "$1" "$2" "$3"; }
mkdir -p "$tmp/board7"
printf '{"data": {"currentUser": {"username": "me", "authoredMergeRequests": {"nodes": [%s]}}}}\n' "$(bnode 7 'Ship it' feat)" > "$tmp/board7/ci.json"
printf 'w\t\t\t\t\tsep\t\t\t\t\tsep-waiting\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n' > "$tmp/board7/rows"
GIT_FZF_STATE=$tmp/board7 otis-board > "$tmp/board7.tsv"
mkdir -p "$tmp/dashstub"
printf '#!/bin/sh\necho row\n' > "$tmp/dashstub/otis-list"
printf '#!/bin/sh\ncat "%s"\n' "$tmp/board7.tsv" > "$tmp/dashstub/otis-board"
printf '#!/bin/sh\n' > "$tmp/dashstub/otis-preview"
chmod +x "$tmp/dashstub"/*
dash=$(PATH=$tmp/dashstub:$PATH TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; zpty -b d "stty rows 40 cols 100; otis-dash"; out=
  for _ in {1..200}; do while zpty -rt d buf; do out+=$buf; done; [[ $out == *"Ship it"* ]] && break; sleep 0.1; done
  sleep 0.3; while zpty -rt d buf; do out+=$buf; done
  zpty -wn d q; sleep 0.3; zpty -d d 2>/dev/null; print -r -- $out' | screen)
expect otis/row-says-its-move "$(printf '%s\n' "$dash" | grep -o 'merge it *Ship it' | head -1 | tr -s ' ')" "merge it Ship it"
# And its MR's number, at the row's right edge.
expect otis/mr-number "$(printf '%s\n' "$dash" | grep -q 'merge it *Ship it  [^!]*!7 ' && echo on-its-row)" "on-its-row"
# From 160 columns what the row says in full is beside the board, a line
# between the two; narrower, as above, it is under it.
wide=$(PATH=$tmp/dashstub:$PATH TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; zpty -b d "stty rows 40 cols 170; otis-dash"; out=
  for _ in {1..200}; do while zpty -rt d buf; do out+=$buf; done; [[ $out == *"Ship it"* ]] && break; sleep 0.1; done
  sleep 0.3; while zpty -rt d buf; do out+=$buf; done
  zpty -wn d q; sleep 0.3; zpty -d d 2>/dev/null; print -r -- $out' | screen)
expect otis/pane-beside "$(printf '%s\n' "$wide" | grep -q '!7 *│' && echo beside):$(printf '%s\n' "$dash" | grep -q '!7 *│' || echo under)" "beside:under"
# A login the forge no longer takes is said under the headline, with the key
# that mends it: u logs in (git-forge login) and then refetches. A u pressed
# while a refresh is on its way is not dropped: its refetch goes when that
# one lands. And a stale mark whose error is gone (a preview's, never asked
# for again) is taken down rather than hold the line up. otis-list's stand-in
# marks as git-cached-json does, is slow the first time, and logs how it was
# asked and the marks it found.
dl=$tmp/dashlogin; mkdir -p "$dl/stubs" "$dl/cache"
cp "$tmp/dashstub/otis-board" "$tmp/dashstub/otis-preview" "$dl/stubs/"
printf '   ERROR  \n          \n  Oauth2: "invalid_grant" "The provided authorization grant is invalid, expired,          \n  revoked.".\n' > "$dl/cache/mrs.json.err"
cat > "$dl/stubs/otis-list" <<EOF
#!/bin/sh
c=$dl/cache
[ -e "\$c/first" ] || { : > "\$c/first"; printf '%s\n' "\$c/old.json" > "\$GIT_FZF_STATE/stale.old.json"; sleep 2; }
if [ -s "\$c/mrs.json.err" ]; then printf '%s\n' "\$c/mrs.json" > "\$GIT_FZF_STATE/stale.mrs.json"; else rm -f "\$GIT_FZF_STATE/stale.mrs.json"; fi
printf '%s|%s\n' "\$1" "\$(ls "\$GIT_FZF_STATE" | grep '^stale\.' | tr '\n' ' ')" >> "\$c/log"
: > "\$GIT_FZF_STATE/footer"
echo row
EOF
cat > "$dl/stubs/git-forge" <<EOF
#!/bin/sh
[ "\$1" = login ] && { mv "$dl/cache/mrs.json.err" "$dl/cache/logged-in"; exit 0; }
exec "$root/bin/git-forge" "\$@"
EOF
chmod +x "$dl/stubs"/*
dash=$(PATH=$dl/stubs:$PATH TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; zpty -b d "stty rows 40 cols 100; otis-dash"; out= c=$1
  lines() { [[ -e $c/log ]] && REPLY=${#${(f)"$(<$c/log)"}} || REPLY=0; }
  for _ in {1..200}; do while zpty -rt d buf; do out+=$buf; done; [[ $out == *otis* ]] && break; sleep 0.1; done
  zpty -wn d u
  for _ in {1..200}; do while zpty -rt d buf; do out+=$buf; done; lines; [[ $out == *"login expired"* ]] && (( REPLY >= 2 )) && break; sleep 0.1; done
  zpty -wn d u
  for _ in {1..200}; do while zpty -rt d buf; do out+=$buf; done; lines; [[ -e $c/logged-in ]] && (( REPLY >= 3 )) && break; sleep 0.1; done
  sleep 0.3; while zpty -rt d buf; do out+=$buf; done
  zpty -wn d q; sleep 0.3; zpty -d d 2>/dev/null; print -r -- $out' - "$dl/cache" | screen)
expect otis/login-says "$(printf '%s\n' "$dash" | grep -o 'GitLab login expired  ·  u logs in again' | head -1)" "GitLab login expired  ·  u logs in again"
# The second time it was asked is the first u's refetch, the login still gone.
expect otis/u-not-dropped "$(sed -n '2p' "$dl/cache/log" | grep -c -e '^--refresh|stale\.mrs\.json')" "1"
expect otis/u-logs-in "$([ -e "$dl/cache/logged-in" ] && echo ran):$(sed -n '3p' "$dl/cache/log")" "ran:--refresh|"
expect otis/gone-error-mark-swept "$(sed -n '1p;2p' "$dl/cache/log" | cut -d'|' -f2 | tr '\n' '/')" "stale.mrs.json stale.old.json /stale.mrs.json /"
# A key's command never holds the board. m here is stand-ins that each take
# a while: its check (a second), its question, then the merge (a second).
# While the check is out the keys go on working: j moves off the row, and the
# question, ready, waits on its row (? answer) rather than come up over
# another; back on the row it is asked in a box; answered, the row says
# merging while the board is yours again, and the footer says when it has
# merged. One that fails says why under the top line, until esc.
do=$tmp/dashout; mkdir -p "$do/stubs" "$do/state"
printf '{"data": {"currentUser": {"username": "me", "authoredMergeRequests": {"nodes": [%s, %s]}}}}\n' "$(bnode 7 'Ship it' feat)" "$(bnode 8 'Fix it' fix)" > "$do/state/ci.json"
printf 'w\t\t\t\t\tsep\t\t\t\t\tsep-waiting\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n' > "$do/state/rows"
GIT_FZF_STATE=$do/state otis-board > "$do/board.tsv"
cp "$tmp/dashstub/otis-list" "$tmp/dashstub/otis-preview" "$do/stubs/"
printf '#!/bin/sh\ncat "%s"\n' "$do/board.tsv" > "$do/stubs/otis-board"
cat > "$do/stubs/git-ci-merge" <<EOF
#!/bin/sh
if [ "\$1" = --check ]; then sleep 1; echo "execute(git-ci-merge \$2)"; exit 0; fi
git-confirm "merge !\$1?" || { echo "\$1 no" >> "$do/log"; exit 0; }
echo "\$1 yes" >> "$do/log"
sleep 1
[ "\$1" = 8 ] && { otis-popup say "merge failed
405 Method Not Allowed"; exit 1; }
printf 'merged !%s\n' "\$1" > "\$GIT_FZF_STATE/note"
EOF
chmod +x "$do/stubs"/*
dash=$(PATH=$do/stubs:$PATH TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; setopt extendedglob; zpty -b d "stty rows 40 cols 100; otis-dash"; out= all=
  upto() { for _ in {1..200}; do while zpty -rt d buf; do out+=$buf; done; [[ ${out//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/} == *"$1"* ]] && { print -n "ok "; all+=$out; out=; return; }; sleep 0.1; done; print -n "x "; all+=$out; out=; }
  upto "Fix it"; sleep 0.3
  zpty -wn d m; sleep 0.2; zpty -wn d j; upto "? answer"
  [[ ${all//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/} == *"merge !7?"* ]] && print -n "asked-elsewhere "
  zpty -wn d k; upto "merge !7?"; sleep 0.5
  zpty -wn d y; zpty -wn d j; upto "merging"; upto "merged !7"
  zpty -wn d m; upto "merge !8?"; sleep 0.5; zpty -wn d y; upto "esc clears that"
  zpty -wn d $'"'"'\e'"'"'; sleep 0.4; while zpty -rt d buf; do out+=$buf; done
  [[ ${out//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/} == *"Fix it"* ]] && zpty -t d && print -n "still-up "
  zpty -wn d q; sleep 0.3; zpty -d d 2>/dev/null; print; print -r -- $all' | screen)
# Each step seen in turn: the rows (these, not the last screen's, which it
# opens on), the question waiting on its row while the cursor is on another,
# the box once back, merging, merged, the second question, and how to clear
# what its failure said; and esc cleared that, not the board.
expect otis/behind-steps "$(printf '%s\n' "$dash" | head -1)" "ok ok ok ok ok ok ok still-up "
expect otis/behind-answered "$(tr '\n' ' ' < "$do/log")" "7 yes 8 yes "
expect otis/behind-failure-said "$(printf '%s\n' "$dash" | grep -c '!8 merge failed · 405 Method Not Allowed')" "1"
# A command the board runs with no terminal (OTIS_ASK, its folder there)
# asks by leaving its question in the folder and waiting for the answer the
# board leaves: how the box ended, and under that what was typed into it.
# What it would say in a box it leaves there too. The board gone, the folder
# with it, a question is a no.
ad=$tmp/ask; mkdir -p "$ad"
( OTIS_ASK=$ad git-confirm "really?"; echo "rc=$?" > "$tmp/ask.rc" ) &
for _ in $(seq 1 40); do [ -e "$ad/q" ] && break; sleep 0.1; done
expect popup/behind-asks "$(cat "$ad/q"):$(cat "$ad/q.msg")" "confirm:really?"
printf '0\n' > "$ad/a.new"; mv "$ad/a.new" "$ad/a"; wait
expect popup/behind-yes "$(cat "$tmp/ask.rc")" "rc=0"
( OTIS_ASK=$ad git-confirm --note "go?" > "$tmp/ask.note"; echo "rc=$?" > "$tmp/ask.rc" ) &
for _ in $(seq 1 40); do [ -e "$ad/q" ] && break; sleep 0.1; done
printf '0\nmind the gap\n' > "$ad/a.new"; mv "$ad/a.new" "$ad/a"; wait
expect popup/behind-note "$(cat "$ad/q.msg" 2>/dev/null; cat "$tmp/ask.note" "$tmp/ask.rc")" "go?mind the gap
rc=0"
OTIS_ASK=$ad otis-popup say "it broke"
expect popup/behind-says "$(cat "$ad"/said.*)" "it broke"
expect popup/behind-gone "$(OTIS_ASK=$tmp/nowhere git-confirm "x?"; echo "rc=$?")" "rc=1"
# A cache asked for with nothing kept and --no-wait, by a screen that names
# a file to be told by (the board), is fetched behind it and the file
# written when it lands. Asked again at once (stale 0, the board's u), what
# is kept is printed at once, the old answer still in it, and fetched behind
# that; a second and a third u while that fetch is out start none of their
# own, and the one that is out asks once more when it lands, so what it
# brings is never from before the last u: three fetches in all.
cj=$tmp/cj; mkdir -p "$cj"
printf '#!/bin/sh\necho run >> "%s/runs"\nsleep 1\nprintf '"'"'{"n": %%s}\\n'"'"' "$(grep -c . "%s/runs")"\n' "$cj" "$cj" > "$cj/fetch"; chmod +x "$cj/fetch"
cjc=$(git rev-parse --path-format=absolute --git-common-dir)/git-alias-cache/lazy.json
expect cached/no-wait-first "$(OTIS_FETCHED=$cj/told git-cached-json --no-wait lazy 60 x -- "$cj/fetch"; echo "rc=$?")" "rc=1"
for _ in $(seq 1 40); do [ -e "$cj/told" ] && break; sleep 0.25; done
expect cached/told-when-landed "$(cat "$cjc")" '{"n": 1}'
rm -f "$cj/told"
expect cached/kept-at-once "$(cat "$(OTIS_FETCHED=$cj/told git-cached-json --no-wait lazy 0 x -- "$cj/fetch")")" '{"n": 1}'
OTIS_FETCHED=$cj/told git-cached-json --no-wait lazy 0 x -- "$cj/fetch" >/dev/null
OTIS_FETCHED=$cj/told git-cached-json --no-wait lazy 0 x -- "$cj/fetch" >/dev/null
for _ in $(seq 1 60); do [ -e "$cjc.pid" ] || break; sleep 0.25; done
expect cached/one-at-a-time "$(grep -c . "$cj/runs"):$(cat "$cjc")" '3:{"n": 3}'
# What a failed call said, whole and in a line, past glab's banner and its
# own line breaks; a login it no longer takes is exit 3, with how to log in.
expect forge/why-login "$(git-forge why "$dl/cache/old.json.err" 2>/dev/null; printf 'rc=%s ' $?; printf '   ERROR  \n\n  Oauth2: "invalid_grant" "expired".\n' > "$dl/e"; git-forge why "$dl/e"; echo "rc=$?")" "rc=1 your GitLab login expired: glab auth login --hostname gitlab.com logs in again
rc=3"
expect forge/why-whole "$(printf '\n   ERROR  \n          \n  Get "https://x/api": dial tcp:            \n  no such host.          \n' > "$dl/e"; git-forge why "$dl/e"; echo "rc=$?")" 'Get "https://x/api": dial tcp: no such host.
rc=0'
# glab's failure, not jq's choking on the error page it piped on; jq's is
# said when it is all there is.
expect forge/why-not-jq "$(printf 'glab: HTTP 503\njq: parse error: Invalid numeric literal at line 2, column 10\n' > "$dl/e"; git-forge why "$dl/e"; printf 'jq: error (at <stdin>:0): Cannot iterate over null\n' > "$dl/e"; git-forge why "$dl/e")" 'glab: HTTP 503
jq: error (at <stdin>:0): Cannot iterate over null'
# With no picker to reload, a cache whose last fetch failed is still fetched
# again when asked for, so it mends by itself once what broke it is fixed;
# one that works is left to u, as before.
cj=$(git rev-parse --path-format=absolute --git-common-dir)/git-alias-cache; mkdir -p "$cj"
printf '{"old":1}\n' > "$cj/heal.json"; printf 'boom\n' > "$cj/heal.json.err"; cp "$cj/heal.json" "$cj/calm.json"
touch -t 202001010000 "$cj/heal.json" "$cj/heal.json.tried" "$cj/calm.json"
( unset FZF_PORT GIT_FZF_STATE; git-cached-json heal 15 x -- sh -c 'echo "{\"new\":1}"' >/dev/null; git-cached-json calm 15 x -- sh -c 'echo "{\"new\":1}"' >/dev/null )
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$cj/heal.json.err" ] || break; sleep 0.1; done
expect cached/failed-mends-unasked "$(cat "$cj/heal.json"):$([ -e "$cj/heal.json.err" ] && echo err)" '{"new":1}:'
expect cached/working-waits-for-u "$(cat "$cj/calm.json")" '{"old":1}'
# A fetch that fails without a word is named whole, with how it ended, so
# the footer says which of the git-forge lists it was.
expect cached/silent-names-command "$(git-cached-json --sync mute 0 -- sh -c 'exit 4'; cat "$cj/mute.json.err"
  git-cached-json --sync blank 0 -- sh -c 'echo hi'; cat "$cj/blank.json.err")" 'sh -c exit 4 exited 4 without saying why
sh -c echo hi printed no JSON'
# A screen with no picker that names a file to be told by (the dashboard)
# has a cache that works fetched behind it too, and the file says it landed.
cp "$cj/calm.json" "$cj/told.json"; touch -t 202001010000 "$cj/told.json"; rm -f "$tmp/fetched"
( unset FZF_PORT GIT_FZF_STATE; OTIS_FETCHED=$tmp/fetched git-cached-json told 15 x -- sh -c 'echo "{\"new\":1}"' >/dev/null )
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$tmp/fetched" ] && break; sleep 0.1; done
expect cached/told-fetches-unasked "$(cat "$cj/told.json"):$([ -e "$tmp/fetched" ] && echo told)" '{"new":1}:told'

