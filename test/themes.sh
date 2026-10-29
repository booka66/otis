#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- themes: each one whole, loading one clears another, and the terminal's
# own colors wherever no theme is loaded
for f in "$root"/share/themes/*; do
  for k in attention good bad elsewhere yours text context faint main delta_syntax bat glow; do
    grep -q "^$k=." "$f" || expect "theme/${f##*/}-has-$k" "missing" "set"
  done
  out=$( (eval "$(otis-theme --env "${f##*/}")"; otis-theme --sample 2>&1 >/dev/null) )
  expect "theme/${f##*/}-sample-clean" "$out" ""
done
expect theme/unknown "$(otis-theme --env nope 2>/dev/null | grep NAME)" "export OTIS_T_NAME='terminal'"
expect theme/default "$(env -u OTIS_THEME otis-theme --env | grep ATTENTION)" "export OTIS_T_ATTENTION='33'"
expect theme/switch-clears "$( (eval "$(otis-theme --env gruvbox)"; eval "$(otis-theme --env terminal)"; printf '%s' "$OTIS_T_MINUS") )" ""
expect theme/awk-without "$(env -u OTIS_T_ATTENTION awk "$(cat "$share/rowfmt.awk")"'BEGIN { printf "%s", GK_ATTENTION }' </dev/null | cat -v)" "^[[33m"
expect theme/jq-without "$(env -u OTIS_T_ATTENTION jq -nj -L "$share" 'include "otis"; attention' | cat -v)" "^[[33m"
# A shell that loaded its theme before removed had a color of its own
# draws removed lines in context's.
expect theme/removed-falls-back "$(env -u OTIS_T_REMOVED awk "$(cat "$share/rowfmt.awk")"'BEGIN { printf "%s", GK_REMOVED }' </dev/null | cat -v):$(env -u OTIS_T_REMOVED jq -nj -L "$share" 'include "otis"; removed' | cat -v)" "^[[38;2;146;131;116m:^[[38;2;146;131;116m"

# --- the theme is loaded once, by the shell, and a run asking for another one
# notices by comparing two strings rather than starting anything
expect theme/want-carries-the-override "$(OTIS_THEME=nord otis-theme --env | grep WANT)" "export OTIS_T_WANT='nord'"
expect theme/inherited-is-kept "$( (eval "$(otis-theme --env gruvbox)"; sh -c '. "$0/palette.sh"; printf %s "$OTIS_T_NAME"' "$share") )" "gruvbox"
expect theme/override-wins "$( (eval "$(otis-theme --env gruvbox)"; OTIS_THEME=nord sh -c '. "$0/palette.sh"; printf %s "$OTIS_T_NAME"' "$share") )" "nord"
expect theme/fish-syntax "$(otis-theme --env-fish gruvbox | grep NAME)" "set -gx OTIS_T_NAME 'gruvbox'"

