#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- gam on a layer: the branches above follow the amended commit
git switch -q -c low main && printf 'l\n' > l.ts && git add l.ts && git commit -qm "Low" &&
  git switch -q -c high && printf 'h\n' > h.ts && git add h.ts && git commit -qm "High" &&
  git switch -q -c higher && printf 'i\n' > i.ts && git add i.ts && git commit -qm "Higher" &&
  git switch -q low
git worktree add -q "$tmp/wt" higher
printf 'x\n' > "$tmp/wt/h.ts" && printf 'l2\n' > l.ts && git add l.ts
gam >/dev/null 2>&1
expect gam/dirty-worktree-refused "$(git show low:l.ts)" "l"
git -C "$tmp/wt" checkout -q -- h.ts
gam >/dev/null 2>&1
expect gam/stays-on-layer "$(git branch --show-current)" "low"
expect gam/one-commit "$(git rev-list --count main..low)" "1"
expect gam/middle-follows "$(git rev-list --count low..high) $(git show high:l.ts)" "1 l2"
expect gam/top-follows "$(git rev-list --count high..higher) $(git show higher:l.ts)" "1 l2"
expect gam/worktree-back "$(git -C "$tmp/wt" branch --show-current) $(cat "$tmp/wt/l.ts")" "higher l2"
git worktree remove "$tmp/wt"
git switch -q -c side low && git commit -q --allow-empty -m "Side" && git switch -q low
printf 'l3\n' > l.ts && git add l.ts
gam >/dev/null 2>&1
expect gam/fan-out-refused "$(git show low:l.ts) $(git diff --cached --name-only)" "l2 l.ts"
git reset -q --hard && git switch -q main
# Nothing staged: gam lists the changes and asks, one key, on the terminal.
# answer <key> <command>: run it on a pty and press <key> at its question.
answer() {
  zsh -fc 'zmodload zsh/zpty; zpty -b q "$2"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      zpty -r q out "*\[y/N\] " && break; sleep 0.2
    done
    zpty -wn q "$1"; while zpty -t q; do zpty -r q out >/dev/null 2>&1 || sleep 0.1; done' - "$1" "$2" >/dev/null 2>&1
}
git switch -q -c solo main && printf 's\n' > s.ts && git add s.ts && git commit -qm "Solo" && printf 's2\n' > s.ts
answer n gam
expect gam/declined "$(git show HEAD:s.ts) $(git diff --cached --name-only)" "s "
answer y gam
expect gam/stages-and-amends "$(git show HEAD:s.ts) $(git rev-list --count main..HEAD) $(git status --porcelain)" "s2 1 "
git switch -q main && git branch -qD solo
# The confirm that starts Claude or Cursor: a is yes with a line of your own
# for them, y yes without one.
noted() {
  zsh -fc 'zmodload zsh/zpty; zpty -b q "n=\$(git-confirm --note go); echo \"\$?:\$n\" > $3"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      zpty -r q out "*a=add a note\] " && break; sleep 0.2
    done
    zpty -wn q "$1"; [ -n "$2" ] && { sleep 0.2; zpty -w q "$2"; }
    while zpty -t q; do zpty -r q out >/dev/null 2>&1 || sleep 0.1; done' - "$1" "$2" "$tmp/noted" >/dev/null 2>&1
  cat "$tmp/noted"
}
expect confirm/note "$(noted a 'check the empty state')" "0:check the empty state"
expect confirm/note-yes "$(noted y)" "0:"
expect confirm/note-no "$(noted n)" "1:"
# p's push over a screen (git-branch-push, a frame under it), in a pty: while
# the pre-push hook waits, a box says the last line it printed and the key
# that stops it, never only "…"; a word wider than the box goes on under
# itself, none of it cut; and the footer says it went up.
git switch -q -c hooked main && git commit -q --allow-empty -m "Hooked"
printf '#!/bin/sh\necho "lint: installing %s" >&2\nsleep 2\n' "$(printf 'a%.0s' $(seq 1 70))z" > .git/hooks/pre-push && chmod +x .git/hooks/pre-push
mkdir -p "$tmp/pushed" && : > "$tmp/push.frame"
pushbox=$(GIT_FZF_STATE=$tmp/pushed TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; zpty -b p "stty rows 24 cols 80; OTIS_FRAME=$1 git-branch-push hooked"; out=
  for _ in {1..200}; do while zpty -rt p buf; do out+=$buf; done; [[ $out == *yes* ]] && break; sleep 0.1; done
  zpty -wn p y
  for _ in {1..200}; do while zpty -rt p buf; do out+=$buf; done; zpty -t p || break; sleep 0.1; done
  zpty -d p 2>/dev/null; print -r -- $out' - "$tmp/push.frame" | screen)
rm -f .git/hooks/pre-push
expect push/box-says-the-hook "$(printf '%s' "${pushbox#*pushing hooked}" | grep -o 'lint: installing\|aaaaaaaaaaz\|ctrl-c\|…' | sort -u | tr '\n' ' ')" "aaaaaaaaaaz ctrl-c lint: installing "
expect push/went-up "$(git -C "$tmp/origin" rev-parse hooked 2>&1):$(cat "$tmp/pushed/note" 2>&1)" "$(git rev-parse hooked):pushed hooked"
git push -q origin --delete hooked 2>/dev/null; git switch -q main && git branch -qD hooked

