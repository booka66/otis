#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- ga in a pty, and the key log its keys go to (otis-usage)
printf 'a4\n' > a.ts && printf 'new\n' > d.ts
# ga opens by symbol (otis-symbols), in a pty: these two files have none, so
# they list under a heading, and the cursor starts on the first of them, not
# on the heading; space stages it and U unstages it.
TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; zpty -b g "stty rows 40 cols 140; source $1/share/otis.zsh; ga"; out=
  for _ in {1..200}; do while zpty -rt g buf; do out+=$buf; done; [[ $out == *d.ts* ]] && break; sleep 0.1; done
  print -r -- $out > $2.screen
  zpty -wn g " "; sleep 1.5; while zpty -rt g buf; do :; done
  git diff --cached --name-only > $2.staged
  zpty -wn g U; sleep 1.5; while zpty -rt g buf; do :; done
  git diff --cached --name-only > $2.unstaged
  zpty -wn g q; sleep 0.3; zpty -d g 2>/dev/null' - "$root" "$tmp/ga"
expect ga/rows "$(screen < "$tmp/ga.screen" | grep -c 'FILES, AND WHAT NO SYMBOL CLAIMS')" "1"
expect ga/space-stages "$(cat "$tmp/ga.staged")" "d.ts"
expect ga/U-unstages "$(cat "$tmp/ga.unstaged")" ""
# Each key it acted on is a line in the key log (otis-usage), with what ga
# says it is for; the keys it offers, as it opened.
expect keys/logged "$(awk -F'\t' '$3 == "space" || $3 == "U" { print $3 "=" $4 }' "$OTIS_KEY_LOG" | LC_ALL=C sort -u | tr '\n' ' ')" "U=unstage all space=stage it "
expect keys/opened "$(awk -F'\t' '$3 == ":open" && $4 ~ /space=stage it/' "$OTIS_KEY_LOG" | wc -l | tr -d ' ')" "1"
# otis-usage asks about the keys a screen offered when it last opened: a key
# renamed since is one row under its new name, and one taken out is gone.
now=$(date +%s)
printf '%s\tscr\t:open\ta=old name,z=gone\n%s\tscr\ta\t\n%s\tscr\t:open\ta=new name,b=never pressed\n%s\tscr\ta\tnew name\n' \
  $((now - 30)) $((now - 20)) $((now - 10)) "$now" > "$tmp/usage.tsv"
expect usage/newest-keys "$(OTIS_KEY_LOG=$tmp/usage.tsv COLUMNS=100 otis-usage 1 | strip | sed -n '/^scr/,/^$/p' | sed -E 's/^ +[█░]+ +//; s/ +/ /g' | tr '\n' '|')" "scr opened 2×|2 0m a new name| never b never pressed||"
git checkout -q -- a.ts && rm -f d.ts

