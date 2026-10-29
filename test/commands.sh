#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- the command table: the one place a command's name and what it does are
# written down, so gg, --help and the completions cannot drift from each other
# or from what is actually in bin/
for c in "$root"/bin/*; do
  [ -L "$c" ] || continue
  c=${c##*/}
  awk -F'\t' -v c="$c" '/^#/ { next } $3 == c || $4 == c { found = 1 } END { exit !found }' "$share/commands.tsv" ||
    expect "help/table-has-$c" "missing from share/commands.tsv" "a row"
done
# and the other way: every row names something you can actually run
# awk, not read: a tab is IFS whitespace, so a row's empty columns would
# collapse and every name after one would be read from the wrong field.
for n in $(awk -F'\t' '/^#/ { next } { print $3; if ($4 != "") print $4 }' "$share/commands.tsv"); do
  [ -e "$root/bin/$n" ] || grep -q "^$n()" "$share/otis.zsh" || [ "$n" = gs ] ||
    expect "help/table-names-$n" "no such command" "one"
done
expect help/one-command "$(otis-help gup | strip | sed -n 2p)" "  rebase onto a fresh origin/main"
expect help/args "$(otis-help gl | strip | sed -n 1p)" "gl [range]"
expect help/pair "$(otis-help gunwip | strip | sed -n 1p)" "gwip gunwip"
# A picker's keys come from the one key=label list that also drives its footer
# and its ? help, so a key added there is in --help without being told.
expect help/keys "$(otis-help gb | strip | grep -c '^  W  *open in its own worktree$')" "1"
expect help/unknown "$(otis-help nope 2>/dev/null; echo $?)" "2"
expect help/through-a-command "$(gp --help | strip | sed -n 1p)" "gp"
expect help/gg-is-the-table "$(gg | strip | grep -c '^  gup  *rebase onto a fresh origin/main')" "1"
expect help/gg-sections "$(gg | strip | grep -c '^\(look\|change\|branch and push\|clean up and undo\|other\)$')" "5"

# --- completion: one list of candidates for all three shells
expect complete/refs "$(otis-complete gl | grep -cx main)" "1"
expect complete/paths "$(otis-complete ga | sed -n 1p)" "@files"
expect complete/no-paths-for-a-ref "$(otis-complete gl | grep -c '@files')" "0"
expect complete/help-everywhere "$(otis-complete gp)" "--help"
expect complete/settings "$(otis-complete otis-config | grep -cx deployJob)" "1"
expect complete/settings-tb "$(otis-complete otis-config | grep -cx terminalBrowser)" "1"
expect complete/themes "$(otis-complete otis-theme | grep -cx gruvbox)" "1"
expect complete/unknown "$(otis-complete nope)" ""

# --- gg lists every command there is. A command nobody can find is a command
# nobody uses.
gg_out=$(gg 2>/dev/null | strip)
unlisted=
for fn in $(cd "$root/bin" && for f in *; do [ -L "$f" ] && [ "$f" != gg ] && echo "$f"; done); do
  printf '%s\n' "$gg_out" | grep -qE "^  $fn( |\$)|^  [a-z-]+ $fn( |\$)| $fn " || unlisted="$unlisted $fn"
done
expect gg/lists-every-command "$unlisted" ""
