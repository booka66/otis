#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- the symbol view, on from symbols.sh: a change by case (git-sentences),
# Claude's gloss, your words (otis-words), the preview and notes that read
# them, and ga staging by symbol, all from sym_branch's change (lib.sh).
common=$(git rev-parse --path-format=absolute --git-common-dir)
if command -v ast-grep >/dev/null 2>&1 && command -v seam >/dev/null 2>&1; then
  sym_branch
  # By sentence (git-sentences): with no model a sentence is a commit's subject, and the change is under it.
  git config otis.sentencesModel off
  git-sentences "$base..$head" >/dev/null 2>&1
  mkdir -p "$tmp/sentst"
  srows() { GMR_IID=7 GIT_FZF_STATE=$tmp/sentst OTIS_SYMBOLS_WIDTH=80 FZF_COLUMNS=160 git-symbols --rows "$base..$head"; }
  expect sentences/first-row "$(srows | awk -F'\t' '$13 == "sent" { print $12 ":" $13 ":" $15 ":" $25 }')" "sentence:1:sent:closed:Head"
  # Told by an older otis, the cases still show while they are told again (otis.symbolsModel off here, so
  # nothing is told again behind the tests that follow).
  for f in "$(git rev-parse --path-format=absolute --git-common-dir)"/git-alias-cache/symbols-sentences/*.tsv; do touch -t 200001010000 "$f"; done
  expect sentences/stale-shown "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=otis.symbolsModel GIT_CONFIG_VALUE_0=off srows | awk -F'\t' '$13 == "sent" { print $12 }')" "sentence:1"
  rm -f "$tmp/sentst/sentences-asked."*
  git-sentences "$base..$head" >/dev/null 2>&1
  # The whole change in a sentence or two, when the cases came with one, heads the list.
  for f in "$(git rev-parse --path-format=absolute --git-common-dir)"/git-alias-cache/symbols-sentences/*.tsv; do { printf 'M\tThe whole change, said once.\n'; cat "$f"; } > "$f.new" && mv -f "$f.new" "$f"; done
  srows >/dev/null
  expect sentences/summary "$(cat "$tmp/sentst/header")" "The whole change, said once."
  GIT_FZF_STATE=$tmp/sentst git-symbols --open sentence:1
  expect sentences/open "$(srows | awk -F'\t' '$12 == "sentence:1>lib.ts#run" { print $13 ":" $14 }')" "sym:1"
  # Drawn, a symbol's row is its name, in the color of what it is.
  expect sentences/name "$(OTIS_T_FUNCTION=7 srows | awk -F'\t' '$12 == "sentence:1>lib.ts#run" { print $25 }')" "$(printf '\033[7mrun\033[0m')"
  expect sentences/close-child "$(GIT_FZF_STATE=$tmp/sentst git-symbols --close 'sentence:1>lib.ts#run' x)" "pos(2)+reload(x)"
  GIT_FZF_STATE=$tmp/sentst git-symbols --viewed "$base..$head" toggle sentence:1
  expect sentences/viewed-all "$(srows | awk -F'\t' '$12 == "sentence:1" { print $20 }')" "all"
  GIT_FZF_STATE=$tmp/sentst git-symbols --viewed "$base..$head" toggle sentence:1
  expect sentences/viewed-none "$(srows | awk -F'\t' '$12 == "sentence:1" { print "[" $20 "]" }')" "[]"
  expect sentences/pane "$(GIT_FZF_STATE=$tmp/sentst git-symbols --preview "$base..$head" "" "" "" "" sentence:1 | strip | grep -c 'Head')" "1"
  # A case runs through the meat of the change: Claude never sees the generated file, and a stop it gives in a
  # test or a generated file, or data it names there, is dropped.
  mkdir -p "$tmp/meatstub"
  cat > "$tmp/meatstub/claude" <<EOF
#!/bin/sh
cat > "$tmp/meat-prompt"
stop() { jq -n --arg p "\$1" --argjson n "\$2" --arg c "\$3" '{name: "x", is: "", path: \$p, side: "new", lines: [{line: \$n, code: \$c, value: ""}]}'; }
jq -n --argjson a "\$(stop lib.spec.ts 2 'export const r = run({ a: 1 });')" --argjson b "\$(stop gen.generated.ts 1 'export const G = run({ a: 1 }, true);')" \\
  --argjson c "\$(stop lib.ts 2 'export function run(o: Opts, twice: boolean): number {')" \\
  '{structured_output: {summary: "", groups: [], cases: [{group: "a run", name: "run is called", setup: "", was: "", now: "", change: "ends differently",
    described: false, said: "", facts: [], stops: [\$a, \$b, \$c], ends: "", stopped: "", tests: [], data: ["gen.generated.ts"]}]}, num_turns: 1, total_cost_usd: 0}'
EOF
  chmod +x "$tmp/meatstub/claude"
  SEAM_CLAUDE=$tmp/meatstub/claude node "$root/share/sentences.mjs" "$base" "$head" --model stub --outline "$tmp/meat.json" >/dev/null 2>&1
  expect sentences/meat-only "$(jq -r '.sentences[0] | "\([.stops[].path] | unique | join(" ")):\(.data | join(" ")):\([.units[][1]] | unique | join(" "))"' "$tmp/meat.json"):$(grep -c 'gen.generated.ts' "$tmp/meat-prompt")" "lib.ts::lib.ts:0"
  # A case reads its code as it runs now: a stop on a line the change replaced is the new line's, which keeps its
  # own reading; the old line goes under its run, past the brace that closes it, and the rest removed is a count.
  (
    mkdir -p "$tmp/turn" && cd "$tmp/turn" && git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' 'export function pick(list: number[]) {' '  const first = list[0];' '  if (!first) {' '    throw new Error("empty");' '  }' '  log(first);' '  return first + 1;' '}' > a.ts
    git add a.ts && git commit -qm base
    printf '%s\n' 'export function pick(list: number[]) {' '  const first = list[0];' '  if (!first) {' '    throw new EmptyError("empty");' '  }' '  return first + 2;' '}' > a.ts
    git commit -qam head
    cat > stub <<'EOF'
#!/bin/sh
cat > /dev/null
stop() { jq -n --arg s "$1" --arg c "$2" --arg v "$3" '{name: "pick", is: "", path: "a.ts", side: $s, lines: [{line: 4, code: $c, value: $v}]}'; }
jq -n --argjson a "$(stop old '    throw new Error("empty");' 'an Error')" --argjson b "$(stop new '    throw new EmptyError("empty");' 'an EmptyError')" \
  '{structured_output: {summary: "", groups: [], cases: [{group: "a pick", name: "the list is empty", setup: "", was: "", now: "", change: "ends differently",
    described: false, said: "", facts: [], stops: [$a, $b], ends: "", stopped: "", tests: [], data: []}]}, num_turns: 1, total_cost_usd: 0}'
EOF
    chmod +x stub
    SEAM_CLAUDE=$PWD/stub node "$root/share/sentences.mjs" HEAD~ HEAD --model stub --outline turn.json >/dev/null 2>&1
  )
  expect sentences/reads-as-now "$(jq -r '.sentences[0].stops | "\(length):\(.[0].side):\(.[0].lines | map(.notes[].value) | join(",")):\(.[0].code | map(if .gap then "\(.sign // "⋯")\(.gap)" else "\(.n)\(.sign | sub(" "; "="))" end) | join(","))"' "$tmp/turn/turn.json")" \
    "1:new:an EmptyError:1=,2=,3=,4+,5=,4-,6+,-2,7="
  rm -rf "$tmp/turn"
  # The cases that come in the same way are one route: each function on it once, a line saying what holds there for
  # each case by its letter, the cases that read it alike sharing a note. A function the change leaves alone shows
  # only what the route uses of it; one whose doc comment is cited is still one stop; an old stop on a line the
  # change kept reads where it runs now.
  (
    mkdir -p "$tmp/routes" && cd "$tmp/routes" && git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' 'export function run(list: number[]) {' '  const a = 1;' '  const b = 2;' '  const c = 3;' '  const d = 4;' '  const e = 5;' \
      '  const f = 6;' '  const g = 7;' '  const h = 8;' '  return pick(list);' '}' '' '/**' ' * Picks the first.' ' */' \
      'export function pick(list: number[]) {' '  const first = list[0];' '  return first + 1;' '}' > a.ts
    git add a.ts && git commit -qm base
    sed -i.bak -e 's/Picks the first\./Picks the first one./' -e 's/first + 1/first + 2/' a.ts && rm a.ts.bak
    git commit -qam head
    cat > stub <<'EOF'
#!/bin/sh
cat > /dev/null
at() { jq -n --arg name "$1" --arg side "$2" --argjson line "$3" --arg code "$4" --arg value "$5" '{name: $name, is: "", path: "a.ts", side: $side, lines: [{line: $line, code: $code, value: $value}]}'; }
one() { jq -n --arg group "$1" --arg name "$2" --argjson stops "$3" '{group: $group, name: $name, setup: "", was: "it was", now: "it is", change: "ends differently",
  described: false, said: "", facts: [], stops: $stops, ends: "", stopped: "", tests: [], data: []}'; }
a=$(one "a pick" "a list has one" "[$(at run new 10 '  return pick(list);' 'it asks pick'), $(at pick new 14 ' * Picks the first one.' 'the comment says one'), $(at pick new 18 '  return first + 2;' 'one more than before')]")
b=$(one "a pick" "a list has two" "[$(at pick new 18 '  return first + 2;' 'one more than before'), $(at pick old 17 '  const first = list[0];' 'the first is read')]")
c=$(one "an empty list" "the list is empty" "[$(at pick new 17 '  const first = list[0];' 'there is none')]")
jq -n --argjson a "$a" --argjson b "$b" --argjson c "$c" '{structured_output: {summary: "", groups: [], cases: [$a, $b, $c]}, num_turns: 1, total_cost_usd: 0}'
EOF
    chmod +x stub
    SEAM_CLAUDE=$PWD/stub node "$root/share/sentences.mjs" HEAD~ HEAD --model stub --outline r.json >/dev/null 2>&1
  )
  expect sentences/routes "$(jq -r '[.sentences[] | "\(.text)=\(.inputs | map(.letter) | join(""))"] | join(" ")' "$tmp/routes/r.json")" "a pick=AB an empty list=A"
  expect sentences/route-once "$(jq -r '.sentences[0].stops | map("\(.name):\(.side):\(.range[0]):\(.inside)") | join(" ")' "$tmp/routes/r.json")" "run:new:1: pick:new:13:"
  expect sentences/route-notes "$(jq -r '.sentences[0].stops[1].lines | map("\(.n)=" + (.notes | map("\(.of | join("+")):\(.value)") | join("/"))) | join(" ")' "$tmp/routes/r.json")" \
    "14=0:the comment says one 17= 18=0+1:one more than before"
  expect sentences/route-untouched "$(jq -r '.sentences[0].stops[0].code | map(if .gap then "⋯\(.gap)" else .n end) | join(",")' "$tmp/routes/r.json")" "1,⋯8,10,11"
  pane=$(FZF_PREVIEW_COLUMNS=100 git-sentences --pane "$tmp/routes/r.json" 1 | strip)
  expect sentences/route-pane "$(printf '%s\n' "$pane" | grep -c -e '◀ A B one more than before' -e '^  A  a list has one' -e '^  B  a list has two' -e '2 cases take this route')" "4"
  # A flag filed on a case before cases were read as routes is the route's that case now takes, with no one asked.
  printf '%s' '{"version":1,"flags":[{"case":"a list has two","flag":"shallow"}]}' > "$tmp/routes/r.flags.json"
  (cd "$tmp/routes" && SEAM_CLAUDE=false node "$root/share/flags.mjs" r.json --now)
  expect sentences/flags-on-route "$(cat "$tmp/routes/r.flags.tsv")" "$(printf 'a pick\tshallow')"
  rm -rf "$tmp/routes"
  # A route's title and how many cases take it are pinned to the top of its pane, so they stay while the rest
  # scrolls; each case is said once.
  printf '%s' '{"sentences":[{"kind":"case","text":"a retry","facts":[],"stops":[],"runs":[],"inputs":[{"letter":"A","title":"A retry runs out","was":"it hangs","now":"it gives up","change":"ends differently","facts":[]},{"letter":"B","title":"A retry works","was":"it works","now":"it works","change":"the same","facts":[]}]}]}' > "$tmp/case.json"
  pane=$(OTIS_PANE_MAP=1 FZF_PREVIEW_COLUMNS=60 git-sentences --pane "$tmp/case.json" 1 | strip)
  expect sentences/case-pinned "$(printf '%s\n' "$pane" | awk '/^\036pin/ { on = 1 } on' | head -3 | tr '\036\n' '^|'):$(printf '%s\n' "$pane" | grep -c 'A retry runs out')" "^pin 3|  a retry|  2 cases take this route|:1"
  # An outline an older otis told, shown while its change is told again, draws each case as a route of its own.
  printf '%s' '{"sentences":[{"kind":"case","text":"A retry runs out","was":"it hangs","now":"it gives up","change":"ends differently","facts":[],"stops":[],"code":[],"tests":[],"links":[],"runs":[]}]}' > "$tmp/case.json"
  expect sentences/older-outline "$(FZF_PREVIEW_COLUMNS=60 git-sentences --pane "$tmp/case.json" 1 2>&1 | strip | grep -c -e 'A retry runs out' -e 'it hangs → it gives up')" "3"
  expect sentences/all-placed "$(srows | grep -c 'gk-loose-heading')" "0"
  # A screen with tabs lists cases, never the tree: before they come, it says why there are none.
  rm -rf "$(git rev-parse --path-format=absolute --git-common-dir)/git-alias-cache/symbols-sentences"
  mkdir -p "$tmp/tabst"
  # (otis.symbolsModel off, so no build starts behind the tests that follow.)
  expect sentences/tabs-none "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=otis.symbolsModel GIT_CONFIG_VALUE_0=off GMR_IID=7 GIT_FZF_STATE=$tmp/tabst OTIS_SYMBOLS_WIDTH=80 FZF_COLUMNS=160 git-symbols --rows "$base..$head" | strip | awk -F'\t' '$13 == "sym" { n++ } /cases need Claude/ { w++ } END { print n + 0 ":" w + 0 }')" "0:1"
  # Claude failing (its usage limit, say) tells no cases and glosses nothing: the screen says why, and nothing
  # asks again but r. A stand-in for Claude at its limit counts the times it is asked.
  mkdir -p "$tmp/limit" "$tmp/failst"
  cat > "$tmp/limit/claude" <<EOF
#!/bin/sh
cat >/dev/null; echo asked >> "$tmp/limit/calls"
printf '%s\n' '{"type":"result","is_error":true,"result":"You have hit your limit · resets 5pm"}'
EOF
  chmod +x "$tmp/limit/claude"
  cache=$(git rev-parse --path-format=absolute --git-common-dir)/git-alias-cache
  lrows() { SEAM_CLAUDE=$tmp/limit/claude GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=otis.symbolsModel GIT_CONFIG_VALUE_0=stub \
    GIT_CONFIG_KEY_1=otis.sentencesModel GIT_CONFIG_VALUE_1=stub GMR_IID=7 OTIS_SYMBOLS_WIDTH=80 FZF_COLUMNS=160 git-symbols "$@" | strip; }
  # settle <n>: Claude asked n times, and the runs that asked it ended (a run's pid file goes last).
  settle() {
    for _ in $(seq 100); do [ "$(cat "$tmp/limit/calls" 2>/dev/null | wc -l)" -ge "$1" ] && break; sleep 0.1; done
    for _ in $(seq 100); do ls "$cache"/symbols-sentences/*.running "$cache"/symbols-gloss/*.running >/dev/null 2>&1 || break; sleep 0.1; done
  }
  # gl, gdm and ga ask Claude for nothing, though it is there to ask: cases and a gloss are a review's (GMR_IID).
  mkdir -p "$tmp/plainst"
  expect symbols/no-claude-outside-review "$(SEAM_CLAUDE=$tmp/limit/claude GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=otis.symbolsModel GIT_CONFIG_VALUE_0=stub \
    GIT_CONFIG_KEY_1=otis.sentencesModel GIT_CONFIG_VALUE_1=stub GIT_FZF_STATE=$tmp/plainst git-symbols --rows "$base..$head" | grep -c 'cases'):$(ls "$tmp/plainst"/sentences-asked.* "$cache/symbols-gloss/$base-$head".* 2>/dev/null | wc -l | tr -d ' ')" "0:0"
  GIT_FZF_STATE=$tmp/failst lrows --rows "$base..$head" >/dev/null; settle 2
  expect sentences/failed-kept "$(cat "$cache/symbols-sentences/$base-$head.failed"):$(ls "$cache/symbols-sentences" | grep -c '\.tsv$')" \
    "Claude could not tell its cases: You have hit your limit · resets 5pm:0"
  # Opened again, a list asks neither again: the cases tab says why, the gloss in the line under the bar.
  mkdir -p "$tmp/failst2"
  failrows=$(GIT_FZF_STATE=$tmp/failst2 lrows --rows "$base..$head"); sleep 1; settle 2
  expect sentences/failed-shown "$(printf '%s\n' "$failrows" | grep -c -e 'Claude could not tell its cases: You have hit your limit' -e 'r asks Claude again · tab shows its files'):$(strip < "$tmp/failst2/footer" | grep -c 'Claude did not gloss this: You have hit your limit · resets 5pm · r asks Claude again')" "2:1"
  expect sentences/failed-not-asked "$(grep -c . "$tmp/limit/calls")" "2"
  GIT_FZF_STATE=$tmp/failst2 lrows --again "$base..$head" >/dev/null; settle 4
  expect sentences/again "$(grep -c . "$tmp/limit/calls")" "4"
  rm -f "$cache/symbols-gloss/$base-$head.failed"
  rm -rf "$(git rev-parse --path-format=absolute --git-common-dir)/git-alias-cache/symbols-sentences" "$tmp/sentst"
  git config --unset otis.sentencesModel
  # Your words (otis-words): what you know, what you don't and your notes, thing by thing: a word marked in a
  # case is placed (the thing it names there, where it lives), so one queue is not another. A selection that
  # runs on into an explanation is the word before it; a word not placed holds wherever it comes up.
  export OTIS_WORDS="$tmp/words.tsv"
  otis-words know "  Commerce Agent (the AI that answers shoppers for a store" >/dev/null
  otis-words learn queue >/dev/null
  otis-words note bucket "the shop's request allowance" >/dev/null
  expect words/kept "$(cut -f1,2,4 "$OTIS_WORDS" | tr '\t\n' ':|')" "known:Commerce Agent:|learning:queue:|noted:bucket:|"
  otis-words place learning queue "the cloud queue events wait on" infra/events
  otis-words place known queue "the tickets a person works through" support/queue
  expect words/placed "$(awk -F'\t' '$2 == "queue" { print $1 ":" $4 }' "$OTIS_WORDS" | tr '\n' '|')" "learning:infra/events|known:support/queue|"
  expect words/reader "$(otis-words --reader | grep -c '"queue" naming'):$(otis-words --reader | grep -c 'wherever it comes up')" "2:2"
  otis-words place known queue "the cloud queue events wait on" infra/events
  expect words/known-now "$(grep -c '^known' "$OTIS_WORDS"):$(grep -c . "$OTIS_WORDS")" "3:4"
  unset OTIS_WORDS
  expect symbols/close-from-child "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep -c 'type Opts')" "0"
  # run used Opts before the change and fresh is new, so only under fresh is
  # the mention a new call: there Opts is a ↑, drawn whole under run.
  GIT_FZF_STATE=$tmp/symst git-symbols --open 'lib.ts#run'; GIT_FZF_STATE=$tmp/symst git-symbols --open 'lib.ts#fresh'
  expect symbols/new-call "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep 'type Opts\|↑ Opts' | grep -c '⇢')" "1"
  expect symbols/new-call-under-fresh "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep -A1 'const fresh' | tail -1 | grep -c '⇢  ')" "1"
  # Bottom up: the sinks first, Opts opening to run and fresh, its callers.
  GIT_FZF_STATE=$tmp/symst git-symbols --flip
  expect symbols/up-roots "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$11 != "" && $11 != "file" && $11 != "callers" { print $12 }' | tr '\n' ' ')" "lib.ts#Opts lib.ts#Box lib.ts#helper pair.ts#Pair pair.ts#Svc gen.generated.ts#G "
  GIT_FZF_STATE=$tmp/symst git-symbols --open 'lib.ts#Opts'
  expect symbols/up-callers "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$11 != "callers" { print $12 }' | grep -c '^lib.ts#Opts>')" "3"
  expect symbols/up-new-caller "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep 'const fresh' | grep -c '⇢')" "1"
  GIT_FZF_STATE=$tmp/symst git-symbols --flip
  expect symbols/down-again "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$11 != "" && $11 != "file" { print $12 }' | head -1)" "lib.ts#run"
  # Claude's glosses. The asking is seam's (seam --gloss): --run hands it the
  # table and keeps the answer in the picker's shape. A stand-in for Claude
  # answers the schema from the ids seam's prompt gave it.
  gdir=$(git rev-parse --path-format=absolute --git-common-dir)/git-alias-cache/symbols-gloss
  mkdir -p "$gdir" "$tmp/stub"
  cat > "$tmp/stub/claude" <<'EOF'
#!/bin/sh
p=$(cat)
n=$(printf '%s\n' "$p" | grep -c '^## s')
jq -n --argjson n "$n" '{is_error: false, structured_output: {spine: "the spine of it",
  symbols: [range(1; $n + 1) | {id: "s\(.)", does: "does \(.)", gloss: "gloss \(.)"}],
  edges: [{from: "s1", to: "s2", gloss: "an edge"}], order: [{id: "s1", why: "first"}]}}'
EOF
  chmod +x "$tmp/stub/claude"
  SEAM_CLAUDE=$tmp/stub/claude git-symbols-gloss --run "$base..$head" "$tmp/symst/symbols.tsv"
  firstdef=$(awk -F'\t' '$2 != "file" { print $1 "#" ($4 != "" ? $4 "." : "") $3; exit }' "$tmp/symst/symbols.tsv")
  expect gloss/run-through-seam "$(jq -r '.spine' "$gdir/$base-$head.json")" "the spine of it"
  expect gloss/run-every-symbol "$(jq -r '.symbols | length' "$gdir/$base-$head.json")" "$(awk -F'\t' '$2 != "file"' "$tmp/symst/symbols.tsv" | wc -l | tr -d ' ')"
  expect gloss/run-shape "$(jq -r --arg id "$firstdef" '(.symbols[] | select(.id == $id) | .does), (.order[0].id == $id), (.edges[0].from == $id)' "$gdir/$base-$head.json" | tr '\n' ' ')" "does 1 true true "
  rm -f "$gdir/$base-$head.json"
  # A run that fails is kept failed, with Claude's reason: the list, which asks for the gloss every time, does
  # not start it again (it would say running), and r (--again) does. seam keeps the answer it had too.
  rm -f "$(git rev-parse --path-format=absolute --git-common-dir)/seam-gloss/$base-$head.json"
  SEAM_CLAUDE=$tmp/limit/claude git-symbols-gloss --run "$base..$head" "$tmp/symst/symbols.tsv"
  gon() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=otis.symbolsModel GIT_CONFIG_VALUE_0=stub git-symbols-gloss "$@"; }
  expect gloss/failed "$(SEAM_CLAUDE=$tmp/limit/claude gon "$base..$head" "$tmp/symst/symbols.tsv")" "failed Claude did not gloss this: You have hit your limit · resets 5pm"
  expect gloss/again "$(SEAM_CLAUDE=$tmp/stub/claude gon --again "$base..$head" "$tmp/symst/symbols.tsv")" "running"
  for _ in $(seq 100); do [ "$(gon --state "$base..$head" "$tmp/symst/symbols.tsv")" = running ] || break; sleep 0.1; done
  expect gloss/again-done "$(gon --state "$base..$head" "$tmp/symst/symbols.tsv"):$(jq -r .spine "$gdir/$base-$head.json")" "done:the spine of it"
  rm -f "$gdir/$base-$head.json"
  # From here, a cache written by hand: the gloss after the signature, its
  # order for the roots, and the preview's head.
  printf '{"symbols":[{"id":"lib.ts#run","does":"runs the options once","gloss":"takes a twice flag"},{"id":"lib.ts#Box.grow","does":"enlarges the box","gloss":"grows by two"},{"id":"lib.ts#Opts","does":"options for one run","gloss":"gains a b flag"}],"edges":[{"from":"lib.ts#fresh","to":"lib.ts#Opts","gloss":"reads b off the options"}],"order":[{"id":"lib.ts#fresh","why":"the new entry point"},{"id":"lib.ts#run","why":"then the changed one"}],"spine":"Adds a b option and a fresh reader of it."}' > "$gdir/$base-$head.json"
  expect gloss/state "$(git-symbols-gloss --state "$base..$head" "$tmp/symst/symbols.tsv")" "done"
  # Outside a review not even a gloss already cached shows.
  mkdir -p "$tmp/plainst2"
  expect gloss/review-only "$(GIT_FZF_STATE=$tmp/plainst2 git-symbols --rows "$base..$head" >/dev/null; GIT_FZF_STATE=$tmp/plainst2 git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -c 'runs the options once\|takes a twice flag'):$(grep -c . "$tmp/plainst2/header" 2>/dev/null)" "0:0"
  # A gloss landing while the picker is open goes in with the next list, on a review's symbols tab.
  : > "$tmp/symst/by-symbol"
  expect gloss/order "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | awk -F'\t' '$12 != "" && $12 !~ /^gk-/ { print $12 }' | head -3 | tr '\n' ' ')" "lib.ts#fresh lib.ts#run lib.ts#Box "
  expect gloss/not-in-row "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep -c 'takes a twice flag')" "0"
  # The spine heads the picker, where the cursor never lands; no row is it.
  expect gloss/spine-header "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep -c 'gk-spine'):$(strip < "$tmp/symst/header")" "0:Adds a b option and a fresh reader of it."
  expect symbols/legend "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" >/dev/null; strip < "$tmp/symst/legend" | grep -c '⇢ a call new')" "1"
  expect gloss/preview-edge "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 1 1 'lib.ts#fresh>lib.ts#Opts' | strip | sed -n 3p)" "new call from fresh: reads b off the options"
  expect gloss/preview-no-edge "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 1 1 'lib.ts#run>lib.ts#Opts' | strip | grep -c 'new call')" "0"
  expect gloss/preview-why "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | sed -n 3p)" "then the changed one"
  expect gloss/preview-header "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -c 'takes a twice flag')" "1"
  expect gloss/preview-does "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | sed -n 1p)" "runs the options once"
  # Under run's mention of Opts, what Opts does and then what the change does to it.
  peek
  expect gloss/note-does "$(FZF_PREVIEW_COLUMNS=100 GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -A2 '↳' | sed 's/^[ │]*//; s/ *$//' | sed -n '2,3p' | tr '\n' '|')" "options for one run|gains a b flag|"
  expect gloss/member-header "$(GMR_IID=7 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 7 9 'lib.ts#Box+grow' | strip | grep -c 'grows by two')" "1"
  rm -f "$gdir/$base-$head.json"
  GIT_FZF_STATE=$tmp/symst git-symbols --open-all "$base..$head"
  # Opts is drawn whole once, under run; fresh and Wide use nothing else, so
  # open-all leaves them closed.
  expect symbols/open-all "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep -c 'type Opts\|grow()')" "2"
  # type Pair sits under usePairToo and under tpl's usePair: whole under the
  # first, a ↑ under usePair, which open-all leaves closed and dim.
  sym() { GIT_FZF_STATE=$tmp/symst OTIS_SYMBOLS_WIDTH=100 git-symbols --rows "$base..$head" | awk -F'\t' -v id="$1" -v f="$2" '$12 == id { print $f }'; }
  expect symbols/open-once "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | cut -f1 | grep -c 'const Pair')" "1"
  expect symbols/open-once-quiet "$(sym 'pair.ts#tpl>pair.ts#usePair' 15)" "quiet"
  GIT_FZF_STATE=$tmp/symst git-symbols --open 'pair.ts#tpl>pair.ts#usePair'
  expect symbols/ref-home "$(sym 'pair.ts#tpl>pair.ts#usePair>pair.ts#type Pair' 13):$(sym 'pair.ts#tpl>pair.ts#usePair>pair.ts#type Pair' 28)" "ref:pair.ts#usePairToo>pair.ts#type Pair"
  # l on the ↑ goes home: what is above it opened, and the screen sent there.
  GIT_FZF_STATE=$tmp/symst git-symbols --close 'pair.ts#usePairToo'
  GIT_FZF_STATE=$tmp/symst git-symbols --open 'pair.ts#tpl>pair.ts#usePair>pair.ts#type Pair'
  expect symbols/ref-goes-home "$(grep -cx 'pair.ts#usePairToo' "$tmp/symst/open"):$(cat "$tmp/symst/goto")" "1:pair.ts#usePairToo>pair.ts#type Pair"
  GIT_FZF_STATE=$tmp/symst git-symbols --close-all
  expect symbols/close-all "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..$head" | strip | grep -c 'type Opts\|grow()')" "0"
  expect symbols/preview "$(git-symbols --preview "$base..$head" lib.ts new 2 4 | strip | grep -c 'twice\|return o.a')" "2"
  # enter opens where the preview is scrolled to: with no scroll the row's
  # own line, on the symbol's name, scrolled to the preview's last row the
  # symbol's last line, 4.
  expect symbols/at-unscrolled "$(GIT_FZF_STATE=$tmp/symst git-symbols --at "$base..$head" lib.ts new 2 4 'lib.ts#run' 2)" "2:17"
  expect symbols/at-member "$(GIT_FZF_STATE=$tmp/symst git-symbols --at "$base..$head" lib.ts new 7 9 'lib.ts#Box+grow' 7)" "7:3"
  expect symbols/at-type "$(GIT_FZF_STATE=$tmp/symst git-symbols --at "$base..$head" lib.ts new 1 1 'lib.ts#type Opts' 1)" "1:13"
  printf '100\n' > "$tmp/symst/cols"
  FZF_PREVIEW_COLUMNS=100 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | wc -l | tr -d ' ' > "$tmp/symst/off.lib.ts#run"
  expect symbols/at-scrolled "$(GIT_FZF_STATE=$tmp/symst git-symbols --at "$base..$head" lib.ts new 2 4 'lib.ts#run' 2)" "4"
  # In nvim's frame there is no preview to have scrolled: on the name.
  expect symbols/at-in-frame "$(OTIS_NVIM_FRAME=$tmp GIT_FZF_STATE=$tmp/symst git-symbols --at "$base..$head" lib.ts new 2 4 'lib.ts#run' 2)" "2:17"
  # A changed line on the screen wins: scrolled two rows above run's changed
  # signature with a five-row screen, enter lands on it, line 2, not on the
  # header row itself.
  n=$(FZF_PREVIEW_COLUMNS=100 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -n 'function run' | cut -d: -f1)
  printf '%s\n' "$((n - 2))" > "$tmp/symst/off.lib.ts#run"; printf '5\n' > "$tmp/symst/plines"
  expect symbols/at-hunk-in-view "$(GIT_FZF_STATE=$tmp/symst git-symbols --at "$base..$head" lib.ts new 2 4 'lib.ts#run' 9)" "2"
  rm -f "$tmp/symst/off.lib.ts#run" "$tmp/symst/plines"
  # What run uses, Opts, is marked in its preview, once per mention, and
  # shown under the diff: its name, where it is, and its lines.
  expect symbols/preview-uses "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | grep -c $'\e\[1;4;38;2;250;189;47mOpts\e\[22;24m')" "1"
  peek
  expect symbols/preview-uses-note "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -c '↳ type Opts = { a: number; b: string };  signature.changed')" "1"
  # A picker starts with no notes; p brings them, under the changed line
  # that mentions the name rather than an unchanged one above it; p again
  # takes them away, and the names stay marked either way.
  mkdir -p "$tmp/symst-fresh" && cp "$tmp/symst"/*.tsv "$tmp/symst"/key "$tmp/symst"/cache-root "$tmp/symst-fresh/" 2>/dev/null
  expect symbols/peeks-off-to-start "$(GIT_FZF_STATE=$tmp/symst-fresh git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -c '↳')" "0"
  runpv() { GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run'; }
  peek
  expect symbols/peeks-on "$(runpv | strip | grep -c '↳')" "1"
  expect symbols/peek-on-a-changed-line "$(runpv | grep -B1 '↳' | head -1 | grep -c $'\e\[48;')" "1"
  GIT_FZF_STATE=$tmp/symst git-symbols --peeks "$base..$head" lib.ts new 2 4 'lib.ts#run'
  expect symbols/peeks-off "$(runpv | strip | grep -c '↳')" "0"
  expect symbols/peeks-off-names-marked "$(runpv | grep -c $'\e\[1;4;38;2;250;189;47mOpts')" "1"
  # They are the row's until p there again: another row has none, and
  # coming back they are still there.
  peek
  expect symbols/peeks-this-row-only "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 19 19 'lib.ts#Wide' | strip | grep -c '↳')" "0"
  expect symbols/peeks-kept-coming-back "$(runpv | strip | grep -c '↳')" "1"
  # The line at the top of the pane stays there, on and off: scrolled to
  # the line under the note's, p moves the position past the note, and p
  # again moves it back.
  rm -f "$tmp/symst/peeks"
  n=$(runpv | strip | grep -n 'function run' | cut -d: -f1)
  printf '%s\n' "$((n + 1))" > "$tmp/symst/off.lib.ts#run"
  GIT_FZF_STATE=$tmp/symst git-symbols --peeks "$base..$head" lib.ts new 2 4 'lib.ts#run'
  expect symbols/peek-keeps-the-top "$(cat "$tmp/symst/off.lib.ts#run"):$(runpv | strip | sed -n "$(cat "$tmp/symst/off.lib.ts#run")p" | grep -c '↳')" "$((n + 2)):0"
  GIT_FZF_STATE=$tmp/symst git-symbols --peeks "$base..$head" lib.ts new 2 4 'lib.ts#run'
  expect symbols/unpeek-keeps-the-top "$(cat "$tmp/symst/off.lib.ts#run")" "$((n + 1))"
  rm -f "$tmp/symst/off.lib.ts#run" "$tmp/symst/peeks"
  # A review reads a change as a branch does, by case and by symbol, so every
  # key that changes what the list or the preview shows has to be there too.
  for k in l h L H b i p; do
    for f in git-symbols git-mr-files; do
      grep -q "bind \"$k:.*git-symbols" "$root/bin/$f" || expect "symbols/$f-binds-$k" "unbound" "bound"
      grep -qE "(keys|first|rest)=.*[,']$k=" "$root/bin/$f" || expect "symbols/$f-lists-$k" "not in its keys" "listed"
    done
  done
  # In a narrow pane the signature keeps to its one row, on the code
  # background, giving up the object type before anything else.
  peek 56
  note=$(FZF_PREVIEW_COLUMNS=56 GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | grep "$(printf '\033\\[%sm' "$OTIS_T_CODEBG")")
  expect symbols/preview-uses-note-fits "$(printf '%s\n' "$note" | strip | sed "s/$(printf '\302\240')/ /g; s/^.*│ *//; s/ *$//")" "↳ type Opts = {…};  signature changed"
  # i: the row's preview is what it uses, whole, and i again is its diff,
  # scrolled where it was.
  printf '5\n' > "$tmp/symst/off.lib.ts#run"
  GIT_FZF_STATE=$tmp/symst git-symbols --uses 'lib.ts#run' 2 new
  expect symbols/uses-view "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -c '^Opts  lib.ts:\|type Opts = ')" "2"
  expect symbols/uses-view-top "$(cat "$tmp/symst/off.lib.ts#run" 2>/dev/null)" ""
  GIT_FZF_STATE=$tmp/symst git-symbols --uses 'lib.ts#run' 2 new
  expect symbols/uses-view-back "$(cat "$tmp/symst/off.lib.ts#run" 2>/dev/null):$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 2 4 'lib.ts#run' | strip | grep -c '^Opts  lib.ts:')" "5:0"
  rm -f "$tmp/symst/off.lib.ts#run"
  # usePair uses type Pair, which is typeof the const: shown as the pair.
  GIT_FZF_STATE=$tmp/symst git-symbols --uses 'pair.ts#usePair' 3 new
  expect symbols/uses-view-pair "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" pair.ts new 3 3 'pair.ts#usePair' | strip | grep -c 'export const Pair\|export type Pair')" "2"
  GIT_FZF_STATE=$tmp/symst git-symbols --uses 'pair.ts#usePair' 3 new
  # A space is a boundary: Opts before "extends" is a mention.
  expect symbols/preview-uses-space "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 19 19 'lib.ts#Wide' | grep -c $'\e\[1;4;38;2;250;189;47mOpts\e\[22;24m')" "1"
  expect symbols/preview-uses-none "$(GIT_FZF_STATE=$tmp/symst git-symbols --preview "$base..$head" lib.ts new 1 1 'lib.ts#run>lib.ts#Opts' | grep -c $'\e\[1;4')" "0"
  expect symbols/commit-rev "$(rm -rf "$tmp/symst"; mkdir "$tmp/symst"; GIT_FZF_STATE=$tmp/symst git-symbols --rows "$head" >/dev/null; awk -F'\t' '$2 != "file" && $1 == "lib.ts" { print $3 }' "$tmp/symst/symbols.tsv" | tr '\n' ' ')" "run Box grow helper fresh Wide Opts "
  # ga's view: two symbols edited and one untracked file; stage one symbol,
  # then unstage it, then stage the untracked file's.
  sed -i.bak 's/return o.a;/return o.a + 1;/; s/this.size--;/this.size -= 2;/' lib.ts && rm lib.ts.bak
  printf 'export function extra(): number {\n  return 2;\n}\n' > u.ts
  rm -rf "$tmp/symst"; mkdir "$tmp/symst"
  wt() { GIT_FZF_STATE=$tmp/symst git-symbols --rows worktree >/dev/null; awk -F'\t' '$2 != "file" { print $3 ":" $16 $17 }' "$tmp/symst/symbols.tsv" | tr '\n' ' '; }
  expect symbols/wt "$(wt)" "run:01 Box:01 shrink:01 extra:01 "
  git-symbols --stage worktree lib.ts new 2 4 2 4 0 1
  expect symbols/stage-lines "$(git diff --cached | grep -c '^[+-] ')" "2"
  expect symbols/stage-only-that "$(git diff --cached | grep -c 'size -=')" "0"
  expect symbols/wt-staged "$(wt)" "run:10 Box:01 shrink:01 extra:01 "
  git-symbols --stage worktree lib.ts new 2 4 2 4 1 0
  expect symbols/unstage "$(git diff --cached | wc -l | tr -d ' ')" "0"
  git-symbols --stage worktree u.ts new 1 3 "" "" 0 1
  expect symbols/stage-untracked "$(git diff --cached --name-only) $(git diff --cached | grep -c '^+[^+]')" "u.ts 3"
  git reset -q && git checkout -q -- lib.ts && rm -f u.ts
  # A symbol added between two others stages there, not at the file's end,
  # though the cut leaves it no context, and unstages again.
  printf 'function a() {\n  return 1;\n}\n\nfunction c() {\n  return 3;\n}\n' > mid.ts && git add mid.ts && git commit -qm Mid
  printf 'function a() {\n  return 1;\n}\n\nfunction b() {\n  return 2;\n}\n\nfunction c() {\n  return 3;\n}\n' > mid.ts
  git-symbols --stage worktree mid.ts new 5 7 5 7 0 1
  expect symbols/stage-middle "$(git show :mid.ts | grep -o '^function [a-z]' | tr '\n' ' ')" "function a function b function c "
  git-symbols --stage worktree mid.ts new 5 7 5 7 1 0
  expect symbols/unstage-middle "$(git diff --cached | wc -l | tr -d ' ')" "0"
  git reset -q --hard HEAD^
  # A range naming HEAD follows a commit made while the picker is open.
  rm -rf "$tmp/symst"; mkdir "$tmp/symst"
  GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..HEAD" > /dev/null
  printf 'export const late = 1;\n' >> lib.ts && git commit -qam "Late"
  expect symbols/moving-head "$(GIT_FZF_STATE=$tmp/symst git-symbols --rows "$base..HEAD" | strip | grep -c 'const late')" "1"
  git reset -q --hard "$head"
  git checkout -q main && git branch -qD sym
fi

