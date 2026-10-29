#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- the pickers themselves, headless, driven through their port (lib.sh).
# feature is a commit past main.
git switch -q -c feature && printf 'f\n' > f.ts && git add f.ts && git commit -qm "Feature" && git switch -q main
git branch stale main~1
printf 'stale\tmerged\t6\t%s\tmine\tmain\n' "$(git rev-parse stale)" > "$(git rev-parse --git-common-dir)/branch-mrs.tsv"

if picker_open "gb"; then
  expect gb/rows "$(picker_rows)" "3"
  expect gb/main-first "$(picker_state | jq -r .current.text | strip | grep -c 'main')" "1"
  picker_key j
  expect gb/j-moves "$(picker_state | jq .position)" "1"
  picker_key /; picker_key feat
  expect gb/search "$(picker_state | jq -c '[.query, .matchCount]')" '["feat",1]'
  picker_key "$(printf '\033')"
  expect gb/esc-keeps-query "$(picker_state | jq -r .query)" "feat"
  # M with the search still there clears it, then marks the merged branch
  # by where it sits in the whole list, not in what the search left.
  picker_key M; sleep 1
  expect gb/M-after-search "$(picker_state | jq -c '[.query, ([.matches[] | select(.text | test("\tstale\t"))] | length), (.selected // [] | map(.text | split("\t")[1]))]')" '["",1,["stale"]]'
  picker_close
else
  expect gb/opens "no picker on port $port" "opened"
fi
git branch -qD stale; rm -f "$(git rev-parse --git-common-dir)/branch-mrs.tsv"

# A key that runs a command, pressed again at once, is a key held down, and
# one press. With another key between, it is a second press: x, x, j, x in a
# breath runs it on the first row once and on the second once, where the
# last x was dropped as a repeat of the first.
rk="git-fzf held '' --bind 'start:reload(printf \"a\\\\nb\\\\n\")' --bind 'x:execute-silent(echo {1} >> $tmp/held-x)'"
if picker_open "$rk"; then
  picker_rows >/dev/null
  printf 'key:x\nkey:x\nkey:j\nkey:x\n' >&7; sleep 1.5
  expect pick/repeat-is-the-same-key "$(tr '\n' ' ' < "$tmp/held-x")" "a b "
  picker_close
else
  expect pick/repeat-opens "no picker on port $port" "opened"
fi

# / searches the fields --nth names, shown or not: gl's whole subject,
# where its row says less.
if picker_open "git-fzf nth '' --delimiter='\t' --with-nth=1 --nth=1,2 --bind 'start:reload(printf \"a\\\\tsecret\\\\nb\\\\tother\\\\n\")'"; then
  picker_rows >/dev/null
  picker_key /; picker_key secret
  expect pick/search-nth "$(picker_state | jq -c '[.matchCount, .current.text]')" '[1,"a\tsecret"]'
  picker_close
else
  expect pick/nth-opens "no picker on port $port" "opened"
fi

# A picker opens on the rows it had when it last closed, while its list
# runs again behind them; a key that runs something waits for that list.
slow="git-fzf memo '' --bind 'start:reload(sleep 2; printf \"a\\\\nb\\\\n\")' --bind 'x:execute-silent(touch $tmp/memo-x)'"
if picker_open "$slow"; then
  picker_rows >/dev/null; sleep 2.5; picker_close
fi
if picker_open "$slow"; then
  expect memo/rows-at-once "$(picker_state | jq -c '[.reading, .totalCount]')" '[true,2]'
  picker_key x
  expect memo/key-waits "$([ -e "$tmp/memo-x" ] && echo ran || echo waits)" "waits"
  sleep 2.5
  expect memo/key-runs-after "$([ -e "$tmp/memo-x" ] && echo ran || echo waits)" "ran"
  picker_close
else
  expect memo/opens "no picker on port $port" "opened"
fi

# --- git-fzf-scroll reset forgets every position in a picker keyed by its
# rows' places, and none in one keyed by --id-nth, whose ids survive the
# reload (t in the symbol picker).
mkdir -p "$tmp/scroll" && : > "$tmp/scroll/off.x" && : > "$tmp/scroll/by-id"
GIT_FZF_STATE=$tmp/scroll git-fzf-scroll reset
expect scroll/reset-by-id "$(ls "$tmp/scroll" | grep -c '^off\.')" "1"
rm "$tmp/scroll/by-id"
GIT_FZF_STATE=$tmp/scroll git-fzf-scroll reset
expect scroll/reset-by-index "$(ls "$tmp/scroll" | grep -c '^off\.')" "0"
