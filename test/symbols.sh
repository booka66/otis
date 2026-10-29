#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-symbols: the symbol table behind s in the file pickers, its callers,
# marks and folds, from sym_branch's change (lib.sh), whose commits stay in the
# object store once the branch is gone. symbols-cases.sh has the rest of the
# symbol view, and otis-test symbols runs both.
common=$(git rev-parse --path-format=absolute --git-common-dir)
if command -v ast-grep >/dev/null 2>&1 && command -v seam >/dev/null 2>&1; then
  sym_branch
  rows=$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head")
  # otis.callers off (as here) is no tsgo in otis, so nothing kept for it either: node_modules is never installed.
  mkdir -p "$tmp/nmstub" "$tmp/nmst"
  printf '#!/bin/sh\necho "run $*" >> "%s"\n' "$tmp/nm-called" > "$tmp/nmstub/otis-node-modules" && chmod +x "$tmp/nmstub/otis-node-modules"
  PATH=$tmp/nmstub:$PATH GIT_FZF_STATE=$tmp/nmst git-symbols --rows "$base..$head" >/dev/null 2>&1
  expect symbols/no-tsgo-no-node-modules "$(cat "$tmp/nm-called" 2>/dev/null)" ""
  table=$tmp/symst/symbols.tsv
  # Roots first (nothing changed mentions them), then what they use: Opts is
  # under run and fresh.
  expect symbols/order "$(awk -F'\t' '$2 != "file" && $1 == "lib.ts" { print $3 }' "$table" | tr '\n' ' ')" "run Box grow helper fresh Wide Opts "
  expect symbols/changes "$(awk -F'\t' '$2 != "file" && $1 == "lib.ts" { print $6 }' "$table" | tr '\n' ' ')" "signature body body removed added added signature "
  expect symbols/uses "$(awk -F'\t' '$3 == "run" || $3 == "fresh" { print $18 }' "$table" | tr '\n' ' ')" "lib.ts#Opts lib.ts#Opts "
  # What nvim's frame takes for run: its lines, its base's, and what it uses
  # to underline; nothing outside a frame. Removed helper has no lines in the
  # file the change kept, only its base's.
  expect symbols/deps "$(OTIS_NVIM_FRAME=$tmp GIT_FZF_STATE=$tmp/symst git-symbols --deps new 2 4 'lib.ts#run')|$(GIT_FZF_STATE=$tmp/symst git-symbols --deps new 2 4 'lib.ts#run')|$(OTIS_NVIM_FRAME=$tmp GIT_FZF_STATE=$tmp/symst git-symbols --deps old 5 7 'lib.ts#helper')" "2 4 2 4 Opts||0 0 5 7"
  expect symbols/roots "$(awk -F'\t' '$19 == 1 && $1 == "lib.ts" { print $3 }' "$table" | tr '\n' ' ')" "run Box helper fresh Wide "
  expect symbols/same-name "$(awk -F'\t' '$1 == "pair.ts" && $3 ~ /Pair$/ { print $3 ":" $6 ":" $18 }' "$table" | tr '\n' ' ')" "Pair:added: type Pair:added:pair.ts#Pair usePair:added:pair.ts#type Pair "
  expect symbols/gen-isolated "$(awk -F'\t' '$1 == "gen.generated.ts" { print $3 ":" $18 ":" $19 }' "$table")" "G::1"
  expect symbols/gen-section "$(printf '%s\n' "$rows" | strip | grep -A1 'generated file' | grep -c 'const G')" "1"
  # In a template literal the interpolation is code and the text is not.
  expect symbols/template "$(awk -F'\t' '$3 == "tpl" { print $18 }' "$table")" "pair.ts#usePair"
  expect symbols/class-head "$(printf '%s\n' "$rows" | strip | grep 'class Svc' | cut -f1 | sed 's/^ *+ *1  *//')" "export class Svc extends Base<Svc>()(…)"
  expect symbols/run-head "$(awk -F'\t' '$3 == "run" { print $13 }' "$table")" "function run(o: Opts, twice: boolean): number"
  expect symbols/fresh-head "$(awk -F'\t' '$3 == "fresh" { print $13 }' "$table")" "const fresh = (o: Opts)"
  # otis.engine dagger: the same table from dagger, over tsgo's language
  # server, which for lib.ts is seam's row for row; cached apart from seam's.
  if command -v dagger >/dev/null 2>&1 && command -v tsgo >/dev/null 2>&1; then
    printf '[[extractors]]\nadapter = "lsp"\ninclude = ["**/*.ts"]\nsettings = { server = ["tsgo", "--lsp", "--stdio"], options = {} }\n' > dagger.toml
    echo dagger.toml >> "$common/info/exclude"
    git config otis.engine dagger
    dt=$(git-symbols --table "$base..$head")
    lib() { awk -F'\t' '$1 == "lib.ts" { print $2, $3, $4, $6, $8, $9, $13, $18, $19, $20 }' "$1"; }
    expect symbols/dagger-lib "$(lib "$dt")" "$(lib "$table")"
    expect symbols/dagger-cached-apart "$(case $dt in (*-dagger*.tsv) echo apart ;; (*) echo "$dt" ;; esac)" "apart"
    git config --unset otis.engine
    rm dagger.toml
    sed -i.bak '/^dagger\.toml$/d' "$common/info/exclude" && rm -f "$common/info/exclude.bak"
  fi
  expect symbols/removed-side "$(awk -F'\t' '$3 == "helper" { print $7, $8 }' "$table")" "old 5"
  # v on run marks it and Opts under it; Opts is the symbol's, so fresh,
  # which uses it too, is half read. v again clears both.
  GIT_FZF_STATE=$tmp/symst git-symbols --viewed "$base..$head" toggle 'lib.ts#run'
  expect symbols/viewed-marks "$(cut -f1 "$common/otis-viewed" | sort | tr '\n' ' ')" "lib.ts#Opts lib.ts#run "
  rows=$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip)
  expect symbols/viewed-row "$(printf '%s\n' "$rows" | awk -F'\t' '$12 == "lib.ts#run" { print ($1 ~ /✓/) }')" "1"
  expect symbols/viewed-shared "$(printf '%s\n' "$rows" | awk -F'\t' '$12 == "lib.ts#fresh" { print ($1 ~ / 1\/2 /) }')" "1"
  GIT_FZF_STATE=$tmp/symst git-symbols --viewed "$base..$head" toggle 'lib.ts#run'
  expect symbols/viewed-cleared "$(wc -l < "$common/otis-viewed" | tr -d ' ')" "0"
  # --viewed warm: every symbol's hash in the picker's own cache, where v
  # reads the ones it marks rather than diff their files again.
  GIT_FZF_STATE=$tmp/symst git-symbols --viewed "$base..$head" warm
  expect symbols/viewed-warm "$(cut -f1 "$tmp/symst"/vh.* | sort -u | wc -l | tr -d ' ')" "$(awk -F'\t' '{ print ($2 == "file") ? $1 : $1 "#" ($4 != "" ? $4 "+" : "") $3 }' "$table" | sort -u | wc -l | tr -d ' ')"
  # Callers elsewhere, from tsgo: main in app.ts, r in lib.spec.ts and again
  # in lib.ts call run and the change touches none; the row under run, the
  # callers under that in place (the spec one too, not filed under tests),
  # and a caller's preview with run underlined. The preview of again reads
  # lib.ts as the change leaves it even once the disk copy has moved on,
  # since its lines are the change's.
  if command -v tsgo >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    expect callers/spec "$(git-callers --spec lib.ts)" "fx/lib"
    git-callers --run "$base..$head" "$table" 2>/dev/null
    cf=$(git-callers --file "$base..$head" "$table")
    expect callers/found "$(cut -f1,4,6,7,8 "$cf" | tr '\t' ' ' | tr '\n' ' ')" "- other.ts#z 3 3 0 lib.ts#Opts lib.ts#build 21 21 2 lib.ts#run app.ts#main 3 6 1 lib.ts#run lib.spec.ts#r 2 2 1 lib.ts#run lib.ts#again 20 20 1 "
    # run took one argument and takes two: both callers break, checked since
    # the checkout is at head; both are in the one package, fx.
    expect callers/errors "$(awk -F'\t' '{ print $9 ":" $11 }' "$cf" | tr '\n' ' ')" "1:fx 0:fx 1:fx 1:fx 1:fx "
    # Claude's review drafts (git-mr-claude), placed by symbol: one on Opts,
    # which is under run, and one on app.ts, which the change does not touch,
    # naming run. They come back in the tree's order, the second on run's
    # signature, each why opening with where its symbol sits.
    printf '{"base_sha":"%s","head_sha":"%s","start_sha":"%s"}' "$base" "$head" "$base" > "$tmp/refs.json"
    printf '[{"path":"app.ts","side":"new","first_line":5,"last_line":5,"symbol":"lib.ts#run","body":"b1","why":"w1"},{"path":"lib.ts","side":"new","first_line":%s,"last_line":%s,"symbol":"","body":"b2","why":"w2"}]' \
      "$(awk -F'\t' '$3 == "Opts" { print $10 }' "$table")" "$(awk -F'\t' '$3 == "Opts" { print $10 }' "$table")" > "$tmp/findings.json"
    cut -f1 "$table" | sort -u | git-test-files kinds > "$tmp/kinds.tsv"
    drafts=$(git-mr-claude-drafts "$PWD" "$tmp/refs.json" "$tmp/findings.json" "$table" "$cf" "$tmp/kinds.tsv")
    expect claude-drafts/order "$(printf '%s\n' "$drafts" | jq -r '.symbol + " " + .note' | tr '\n' ' ')" "run b1 Opts b2 "
    expect claude-drafts/moved "$(printf '%s\n' "$drafts" | jq -r 'select(.note == "b1") | "\(.where) \(.position.new_path)"')" "lib.ts:$(awk -F'\t' '$3 == "run" { print $10 }' "$table") lib.ts"
    expect claude-drafts/why "$(printf '%s\n' "$drafts" | jq -r '.why | split("\n")[0]' | tr '\n' '|')" "**\`run\`** · ~ signature changed · an entry point · 3 callers elsewhere, ✗ main, r, again · about app.ts:5|**\`Opts\`** · ~ signature changed · reached from \`run\` › \`Opts\` · 1 caller elsewhere|"
    # With a gloss, the tree lists its reading order first, so Opts is met
    # under fresh before run.
    printf 'lib.ts#fresh\n' > "$tmp/order.txt"
    expect claude-drafts/gloss-order "$(git-mr-claude-drafts "$PWD" "$tmp/refs.json" "$tmp/findings.json" "$table" "$cf" "$tmp/kinds.tsv" "$tmp/order.txt" | jq -r 'select(.note == "b2") | .why | split("\n")[0]')" "**\`Opts\`** · ~ signature changed · reached from \`fresh\` › \`Opts\` · 1 caller elsewhere"
    # The break the change reaches through a type: a row of its own, last.
    expect callers/broken-row "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$12 == "->callers" { print $1 }' | sed 's/^ *//')" "▸   1 broken elsewhere without calling anything changed, in 1 package"
    GIT_FZF_STATE=$tmp/symst git-symbols --open '->callers'
    expect callers/broken-open "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$12 == "->callers>other.ts#z" { print $2 ":" $3 " " $1 }' | sed 's/  */ /g; s/^ //')" "other.ts:3 ✗ const z: ReturnType<typeof build> = { a: 1 };"
    expect callers/broken-preview "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" other.ts file 3 3 '->callers>other.ts#z' | strip | sed -n 1p | grep -c 'no longer type-checks')" "1"
    GIT_FZF_STATE=$tmp/symst git-symbols --close '->callers'
    GIT_FZF_STATE=$tmp/symst git-symbols --open 'lib.ts#run'; GIT_FZF_STATE=$tmp/symst git-symbols --open 'lib.ts#run>callers'
    expect callers/rows "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$12 ~ /^lib.ts#run>callers/ && $11 != "package" { print $12 }' | tr '\n' ' ')" "lib.ts#run>callers lib.ts#run>callers>app.ts#main lib.ts#run>callers>lib.spec.ts#r lib.ts#run>callers>lib.ts#again "
    expect callers/text "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$12 == "lib.ts#run>callers" { print $1 }' | sed 's/^ *//')" "▾   3 callers elsewhere, in 1 package · 1 in specs · 3 with type errors"
    expect callers/caller-row "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$12 ~ /^lib.ts#run>callers>/ && $11 == "caller" { print $2 ":" $3 " " $1 }' | sed 's/  */ /g; s/^ //' | tr '\n' ' ')" "app.ts:5 ✗ function main(): number lib.spec.ts:2 ✗ const r = run({ a: 1 }); lib.ts:20 ✗ function again(): number "
    expect callers/package-row "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$11 == "package" { print $1 ":" $12 }' | sed 's/^ *//')" "fx:lib.ts#run>callers>fx"
    expect callers/preview-errors "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" app.ts file 3 6 'lib.ts#run>callers>app.ts#main' | strip | sed -n 1p | grep -c 'type error')" "1"
    # The error under its line, and the preview scrolled to it on first view.
    expect callers/preview-inline "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" app.ts file 3 6 'lib.ts#run>callers>app.ts#main' | strip | grep -A1 '^ *5 ' | tail -1 | sed 's/^ *┃ //' | sed -E 's/^(.{30}).*/\1/')" "✗ Expected 2 arguments, but go"
    expect callers/preview-scrolled "$(cat "$tmp/symst/off.lib.ts#run>callers>app.ts#main" 2>/dev/null | grep -c '^[0-9]')" "1"
    rm -f "$tmp/symst/off.lib.ts#run>callers>app.ts#main"
    # Claude's fix for it under the error, from a cache written by hand,
    # keyed by the answer's shape and the broken rows: its sentence, then its
    # edit, where it goes and that F can make it, as a diff.
    fxdir=$(dirname "$cf")/../callers-fix; mkdir -p "$fxdir"
    printf '{"fixes":[{"caller":"app.ts#main","line":5,"where":"caller","fix":"pass twice as false","edits":[{"path":"app.ts","old":"  return run({ a: 1 });\\n","new":"  return run({ a: 1 }, false);\\n"}]}]}' > "$fxdir/$( { echo v2; awk -F'\t' '$9 > 0' "$cf" | cut -f1,4,12; } | git hash-object --stdin).json"
    expect callers/fix "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" app.ts file 3 6 'lib.ts#run>callers>app.ts#main' | strip | grep -A3 '✦' | sed 's/^ *┃ *//' | tr '\n' '|')" "✦ pass twice as false|app.ts:5 · F makes it|-return run({ a: 1 });|+return run({ a: 1 }, false);|"
    expect callers/fix-prompt "$(git-callers-fix --prompt "$base..$head" "$cf" "$table" | grep -c '^## caller ')" "4"
    # enter on a broken caller opens on its first error.
    expect callers/at-error "$(GIT_FZF_STATE=$tmp/symst git-symbols --at "$base..$head" app.ts file 3 6 'lib.ts#run>callers>app.ts#main' 3)" "5"
    # F makes the edit and saves it, staying in the picker; the preview then
    # marks it made, and a second F says it is made already.
    expect callers/fix-apply "$(GIT_FZF_STATE=$tmp/symst git-callers-fix --apply 'lib.ts#run>callers>app.ts#main' 'reload(x)'):$(sed -n 5p app.ts)" "reload(x):  return run({ a: 1 }, false);"
    expect callers/fix-apply-note "$(cat "$tmp/symst/note")" "made the proposed fix in app.ts · uncommitted, git diff shows it"
    expect callers/fix-made "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" app.ts file 3 6 'lib.ts#run>callers>app.ts#main' | strip | grep -c 'app.ts:5 · made, uncommitted')" "1"
    GIT_FZF_STATE=$tmp/symst git-callers-fix --apply 'lib.ts#run>callers>app.ts#main' 'reload(x)' >/dev/null
    expect callers/fix-apply-again "$(cat "$tmp/symst/note")" "the fix proposed for this caller is made already; git diff shows it"
    expect callers/fix-not-caller "$(GIT_FZF_STATE=$tmp/symst git-callers-fix --apply 'lib.ts#run' 'reload(x)' >/dev/null; cat "$tmp/symst/note")" "F makes the fix proposed for a broken caller, and this row is not one"
    git checkout -q -- app.ts
    rm -rf "$fxdir"
    expect callers/preview "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" app.ts file 3 5 'lib.ts#run>callers>app.ts#main' | grep -c $'\e\[1;4;38;2;250;189;47mrun\e\[22;24m')" "1"
    # From a checkout at the base, the change's files are handed to tsgo as
    # the change leaves them, so the check holds there too.
    git switch -q --detach "$base" && rm -f "$cf" && git-callers --run "$base..$head" "$table" 2>/dev/null; git switch -q sym
    expect callers/checked-from-base "$(awk -F'\t' '{ print $9 }' "$(git-callers --file "$base..$head" "$table")" | tr '\n' ' ')" "1 0 1 1 1 "
    printf '\n\n\n' | cat - lib.ts > lib.ts.moved && mv lib.ts.moved lib.ts
    expect callers/preview-as-changed "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts file 20 20 'lib.ts#run>callers>lib.ts#again' | strip | grep -c 'function again')" "1"
    git checkout -q -- lib.ts
    GIT_FZF_STATE=$tmp/symst git-symbols --close 'lib.ts#run>callers'; GIT_FZF_STATE=$tmp/symst git-symbols --close 'lib.ts#run'
  fi
  # fresh starts at its doc comment and opens on its keyword. The file row is
  # the console.log alone: the blank lines count for nothing, and its preview
  # is that line as a hunk of its own, not the file's diff over again.
  expect symbols/comment-claimed "$(awk -F'\t' '$3 == "fresh" { print $8, $9, $10, $11 }' "$table")" "15 16 16 2"
  expect symbols/unclaimed-count "$(awk -F'\t' '$2 == "file" && $1 == "lib.ts" { print $11, $12 }' "$table")" "1 0"
  expect symbols/unclaimed-preview "$(GIT_SYMBOLS_PLAIN=1 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new | grep '^@@\|^[-+][^-+]' | tr '\n' ' ')" "@@ -16,0 +18,1 @@ +console.log(fresh); "
  # A review's preview has the MR's threads under their lines, and is kept
  # with them: a second draw is the same, and a thread changing draws anew.
  mrc=$(git rev-parse --path-format=absolute --git-common-dir)/git-alias-cache
  mkdir -p "$mrc"
  thread() { printf '[{"id":"d1","resolvable":true,"resolved":false,"notes":[{"id":1,"body":"%s","author":{"username":"ann"},"position":{"new_line":3,"new_path":"lib.ts","head_sha":"%s","base_sha":"%s"}}]}]\n' "$1" "$head" "$base" > "$mrc/mr-7-threads.json"; }
  thread "first thought"; echo '[]' > "$mrc/mr-7-drafts.json"
  mrpv() { GIT_SYMBOLS_MR=7 GIT_FZF_STATE=$tmp/symst FZF_PREVIEW_COLUMNS=90 git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -c "$1"; }
  expect symbols/mr-thread "$(mrpv 'first thought')" "1"
  expect symbols/mr-thread-kept "$(mrpv 'first thought')" "1"
  thread "second thought"
  expect symbols/mr-thread-new "$(mrpv 'second thought'):$(mrpv 'first thought')" "1:0"
  rm -f "$mrc"/mr-7-*
  # v on a symbol marks every file it touched in one call: the same marks
  # as a call a file, a deleted file's holding while it stays deleted.
  git-mr-viewed add 7 "$head" lib.ts; git-mr-viewed add 7 "$head" pair.ts
  printf 'remove\tlib.ts\nadd\tgen.generated.ts\nadd\tgone.ts\n' | git-mr-viewed apply 7 "$head"
  expect mr-viewed/apply "$(git-mr-viewed list 7 "$head" | sort | tr '\n' ' ')" "gen.generated.ts gone.ts pair.ts "
  expect symbols/fields "$(printf '%s\n' "$rows" | strip | awk -F'\t' '{ print NF }' | sort -u)" "12"
  expect symbols/class-collapsed "$(printf '%s\n' "$rows" | strip | grep -c 'grow()')" "0"
  expect symbols/class-count "$(printf '%s\n' "$rows" | strip | cut -f1 | grep -c '▸ 1 export class Box$')" "1"
  expect symbols/child-hidden "$(printf '%s\n' "$rows" | strip | grep -c 'type Opts')" "0"
  GIT_FZF_STATE=$tmp/symst git-symbols --open 'lib.ts#Box'
  expect symbols/class-open "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep -c 'grow()')" "1"
  GIT_FZF_STATE=$tmp/symst git-symbols --open 'lib.ts#run'
  expect symbols/root-open "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep -A1 'function run' | tail -1 | cut -f1 | sed 's/.*    //; s/  *$//')" "▸ 1 export type Opts = { a: number; b: string };"
  # h on the child closes run and, as the picker's transform, puts the
  # cursor on run's row, the first, before the reload.
  expect symbols/close-actions "$(GIT_FZF_STATE=$tmp/symst git-symbols --close 'lib.ts#run>lib.ts#Opts' git-symbols --rows x)" "pos(1)+reload(git-symbols --rows x)"
fi
