#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-commit-check
expect commit-check/ok "$(printf 'Fix the thing\n\nBecause.\n' | git-commit-check; echo "rc=$?")" "rc=0"
expect commit-check/long "$(printf '%081d\n' 0 | git-commit-check)" "subject is 81 characters; keep it to 72"
expect commit-check/prefix "$(printf 'feat: add\n' | git-commit-check)" "no type prefix like feat: or fix(area):, just say what it does"
expect commit-check/blank "$(printf 'Subject\nbody\n' | git-commit-check)" "leave a blank line between the subject and the body"
expect commit-check/curly-quote-is-one "$(printf 'don\342\200\231t %066d\n' 0 | git-commit-check; echo "rc=$?")" "rc=0"
expect commit-check/dash "$(printf 'Subject \342\200\224 no\n' | git-commit-check)" "em dash in the message; use a colon, a comma, or two sentences"

# --- git-commit-tidy
expect tidy/blank-after-subject "$(printf 'Subject\nbody\n' | git-commit-tidy)" "$(printf 'Subject\n\nbody')"
expect tidy/wrap "$(printf 'S\n\n%s %s\n' "$(printf 'word%.0s ' $(seq 1 20))" x | git-commit-tidy | awk '{ if (length($0) > 72) print "too long" }')" ""
expect tidy/list-kept "$(printf 'S\n\n- one\n- two\n' | git-commit-tidy)" "$(printf 'S\n\n- one\n- two')"
expect tidy/trailer-kept "$(printf 'S\n\nCo-Authored-By: a\nChangelog: fixed\n' | git-commit-tidy)" "$(printf 'S\n\nCo-Authored-By: a\nChangelog: fixed')"
expect tidy/fence-kept "$(printf 'S\n\n```\na   b\n```\n' | git-commit-tidy)" "$(printf 'S\n\n```\na   b\n```')"
expect tidy/collapse-blanks "$(printf 'S\n\n\n\nbody\n\n\n' | git-commit-tidy)" "$(printf 'S\n\nbody')"

# --- share/rowfmt.awk
expect rowfmt/fit-short "$(awk_fn 'gk_fit("a/b/c.ts", 20)')" "a/b/c.ts"
expect rowfmt/fit-drop-dirs "$(awk_fn 'gk_fit("packages/billing/src/index.ts", 16)')" "…/src/index.ts"
expect rowfmt/fit-name-from-front "$(awk_fn 'gk_fit("averyveryverylongname.ts", 10)')" "…ngname.ts"
expect rowfmt/fit-untracked-dir "$(awk_fn 'gk_fit("tmp/", 10)')" "tmp/"
expect rowfmt/dir "$(awk_fn 'gk_dir("a/b/c")')" "a/b/"
expect rowfmt/dir-bare "$(awk_fn 'gk_dir("c")')" ""
expect rowfmt/bar-empty "$(awk_fn 'gk_bar(0, 0)')" "..."
expect rowfmt/bar-all-add "$(awk_fn 'gk_bar(10, 0)')" "███"
expect rowfmt/bar-keeps-a-block "$(awk "$(cat "$share/rowfmt.awk")"'BEGIN { print gk_bar(300, 1) }' </dev/null | grep -c '146;131;116m█')" "1"
expect rowfmt/stat "$(awk_fn 'gk_stat(4, 12, 2, 2)')" " +4 −12"
expect rowfmt/stat-thousands "$(awk_fn 'gk_stat(1354, 514, 5, 3)')" "+1,354 −514"
# A deletion is no break: dim, never red.
expect rowfmt/removed-is-dim "$(awk "$(cat "$share/rowfmt.awk")"'BEGIN { print gk_counts(0, 3) }' </dev/null | grep -c '146;131;116m−3')" "1"
expect rowfmt/stat-blank "$(awk_fn 'gk_stat("", "", 2, 2)')" "       "
expect rowfmt/numstat-rename "$(awk_fn 'gk_numstat_path("dir/{old => new}.ts")')" "dir/new.ts"
expect rowfmt/numstat-plain "$(awk_fn 'gk_numstat_path("old.ts => new.ts")')" "new.ts"
expect rowfmt/width-narrow "$(awk_fn 'gk_list_width(110)')" "107"
expect rowfmt/width-side-by-side "$(awk_fn 'gk_list_width(120)')" "57"
expect rowfmt/width-wide "$(awk_fn 'gk_list_width(220)')" "125"

# --- share/row-wrap.awk: a picker's row too long for its list goes on under
# its text, whole, its colors carried; one that fits is as it is.
rw() { printf '%b\n' "$2" | LC_ALL=C awk -v w="$1" -f "$share/row-wrap.awk" | tr '\036' '\n' | strip; }
expect row-wrap/under-its-text "$(rw 40 'abc1234   2d  \033[33mThe screen keeps the plan after a fuse, because seam hands it over\033[0m' | tr '\n' '|')" \
  "abc1234   2d  The screen keeps the plan |              after a fuse, because seam|              hands it over|"
expect row-wrap/colors-carried "$(printf 'abc1234   2d  \033[33mThe screen keeps the plan after a fuse\033[0m\n' | LC_ALL=C awk -v w=30 -f "$share/row-wrap.awk" | tr '\036' '\n' | sed -n 2p | grep -c '33m')" "1"
expect row-wrap/fits "$(rw 40 'abc1234   2d  Short')" "abc1234   2d  Short"
expect row-wrap/path-at-a-slash "$(rw 40 '.M  +2 ███  packages/billing/src/handlers/refund.ts' | tr '\n' '|')" ".M  +2 ███  packages/billing/src/|            handlers/refund.ts|"
# The few lines a screen wraps itself (screen.zsh's wrapc) break where a
# list's rows do.
for t in 'The screen keeps the plan after a fuse, because seam hands it over' 'abcde fghi jklm nop' \
  'see path/to/somewhere/deep/in/the/tree.ts and more' 'a replyModelTestCaseHandlerFactory goes_on_and_on_further'; do
  expect "row-wrap/as-wrapc-${t%% *}" "$(rw 20 "$t")" "$(st=/nonexistent zsh -fc '. "$1/screen.zsh"; wrapc "$2" 20 2; print -rl -- "${reply[@]}"' - "$share" "$t" 2>/dev/null | strip)"
done

# --- share/otis.jq
expect jq/gid "$(jq_fn '"gid://gitlab/Ci::Pipeline/123" | gid')" "123"
expect jq/gid-null "$(jq_fn 'null | gid')" ""
expect jq/ago "$(jq_fn '(now - 7200 | todate) | ago')" "2h"
expect jq/padr "$(jq_fn '"!12" | padr(6) | "[\(.)]"')" "[!12   ]"
expect jq/padl "$(jq_fn '3 | padl(2) | "[\(.)]"')" "[ 3]"
expect jq/effective-gate "$(jq_fn '{status: "FAILED", jobs: {nodes: [{name: "gate", status: "FAILED", allowFailure: false}]}} | effective(["gate"])')" "APPROVAL"
expect jq/effective-real "$(jq_fn '{status: "FAILED", jobs: {nodes: [{name: "gate", status: "FAILED", allowFailure: false}, {name: "test", status: "FAILED", allowFailure: false}]}} | effective(["gate"])')" "FAILED"
expect jq/glyph "$(jq_fn '"SUCCESS" | pipe_glyph')" "✓"

# --- share/markdown.awk: HTML tags go, but not out of code
md_fn() { LC_ALL=C awk -v width=80 "$(cat "$share/markdown.awk")"' BEGIN { md("'"$1"'", 80, "") }' </dev/null | strip; }
expect md/tags-stripped "$(md_fn 'a <b>bold</b> &lt;x&gt;')" "a bold <x>"
expect md/code-span-kept "$(md_fn 'x `Promise<void>` y')" "x Promise<void> y"
expect md/fence-kept "$(md_fn '```ts\037const a: Array<string> = [];\037```')" "  const a: Array<string> = [];"

# --- share/delta.sh: a removed line that opens what its added twin opens
# again ("export function old({", then "export function fresh({") does not
# cost the lines after it their colors: each side's code is colored as its
# own file has it, so no keyword is left in one run with the word after it.
# Side by side too, each half of a row, with the text and its columns as
# delta draws them.
mkdir "$tmp/delta"
printf '%s\n' 'export function old({' '  a,' '}: {' '  a: number;' '}) {' '  return a;' '}' > "$tmp/delta/a.ts"
printf '%s\n' 'export function fresh({' '  b,' '}: {' '  b: number;' '}) {' '  if (!b) {' '    return 0;' '  }' '  return b;' '}' > "$tmp/delta/b.ts"
git diff --no-index -U9 "$tmp/delta/a.ts" "$tmp/delta/b.ts" > "$tmp/delta/d"
drawn() { (. "$share/delta.sh"; OTIS_C_ROOT=1; OTIS_C_sideBySide=$1; FZF_PREVIEW_COLUMNS=100; gk_delta --file-style omit < "$tmp/delta/d"); }
expect delta/each-side-colored-as-its-file "$(drawn | grep -c 'return [ab0];\|export function\|if (')|$(drawn | strip | grep -c 'return [ab0];')" "0|3"
expect delta/side-by-side-too "$(drawn always | grep -c 'return [ab0];\|export function\|if (')|$(drawn always | strip | grep -c '│ *6 *│  return a; *│ *7 *│    return 0;')" "0|1"
# A hunk is headed by the function it is in, and by nothing where git's line
# over it names none (a heredoc's EOF, a sentence of prose); a note in
# quotes, the symbol view's, stays.
printf '%s\n' '--- a/x.sh' '+++ b/x.sh' '@@ -3 +3 @@ dots() {' '-a' '+b' '@@ -9 +9 @@ EOF' '-c' '+d' '@@ -20 +20 @@ "grows by two"' '-e' '+f' > "$tmp/delta/h"
heads=$( (. "$share/delta.sh"; OTIS_C_ROOT=1; FZF_PREVIEW_COLUMNS=60; gk_delta --file-style omit < "$tmp/delta/h") | strip)
expect delta/hunk-names-its-function "$(printf '%s\n' "$heads" | grep -c 'dots() │\|"grows by two" │'):$(printf '%s\n' "$heads" | grep -c 'EOF')" "2:0"
# The pane wraps a long line of a diff under its code, reading the line
# numbers as delta.sh has delta draw them.
printf 'one\n' > "$tmp/delta/l1"; printf 'one\nRun it: a menu of short guided tours, most of them hands-on\n' > "$tmp/delta/l2"
git diff --no-index "$tmp/delta/l1" "$tmp/delta/l2" > "$tmp/delta/l"
expect pane-wrap/diff-under-code "$( (. "$share/delta.sh"; OTIS_C_ROOT=1; FZF_PREVIEW_COLUMNS=40; gk_delta --file-style omit < "$tmp/delta/l") |
  LC_ALL=C awk -v w=40 -v cont=/dev/null -f "$share/pane-wrap.awk" | strip | sed -n '/Run it/,$p' | tr '\n' '|')" \
  "    ⋮  2 │Run it: a menu of short |    ⋮    │guided tours, most of them |    ⋮    │hands-on|"
rm -rf "$tmp/delta"

# --- share/story-pane.mjs: in a case's route, a line the change removed and
# the line it became have what changed on the word grounds delta.sh draws it
# on, here in [ ]; a line put in between them pairs with neither.
cat > "$tmp/case.json" <<'EOF'
{"sentences": [{"kind": "case", "text": "A text is cut", "facts": [], "runs": [], "stops": [{"name": "cut", "path": "a.ts", "side": "new", "where": "a.ts", "mark": "◆", "inChange": true, "parent": -1, "lines": [], "code": [
  {"n": 1, "sign": " ", "t": "function cut(text) {", "mine": true},
  {"n": 2, "sign": "-", "t": "  return text.slice(0, MAX);", "mine": false},
  {"n": 2, "sign": "+", "t": "  const count = 1;", "mine": true},
  {"n": 3, "sign": "+", "t": "  return truncate(text, MAX);", "mine": true},
  {"n": 4, "sign": " ", "t": "}", "mine": true}]}]}]}
EOF
e=$(printf '\033')
expect story-pane/changed-words "$(FZF_PREVIEW_COLUMNS=80 git-sentences --pane "$tmp/case.json" 1 |
  sed -E "s/$e\[48;2;(67;131;69|156;53;43)m([^$e]*)$e\[48;2;(38;51;42|60;32;34)m/[\2]/g" | strip | sed -n 's/^ *│ *[0-9]* [−+] *\(.*[^ ]\) *$/\1/p' | tr '\n' '|')" \
  "return text[.slice(0], MAX);|const count = 1;|return [truncate(]text, MAX);|"
rm -f "$tmp/case.json"
# A paragraph of a case's pane says in its map how each of its lines goes on from the one above, after a space or
# inside a word too long for a line, so a selection of it copies as the one line it was: here the author band,
# where it runs, wrapped, and a test file's path, cut.
printf '%s' '{"sentences":[{"kind":"case","text":"A row opens","facts":[],"stops":[],"where":"The page a merchant opens to turn a product on, one row a product.","runs":[{"where":"src/integrations/pages/integration-vendor-page-contextual.test.tsx","name":"shows it"}]}]}' > "$tmp/case.json"
expect story-pane/paragraphs "$(OTIS_PANE_MAP=1 FZF_PREVIEW_COLUMNS=60 git-sentences --pane "$tmp/case.json" 1 | awk 'NR == 1 { n = $2; next } NR <= n + 1' | awk -F'\t' '$2 == "text" { print $5 }' | tr '\n' ' ')" \
  "new new word new cut "
rm -f "$tmp/case.json"

