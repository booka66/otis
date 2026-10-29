# Sourced by each test/<area>.sh: the helpers the tests share, and a home of
# the area's own under $TMPDIR, with a repo in it (a clone of a two-commit
# origin) that the tests run in. Nothing is shared between areas, so they run
# at once. On exit it prints the area's count last and fails if a test did.
root=$(cd "$(dirname "$0")/.." && pwd)
PATH=$root/bin:$PATH
share=$root/share
export PATH
unset GIT_FZF_STATE OTIS_NVIM_FRAME
# Nor on the settings of the repo this was run from: a shell that otis-config
# --env was evaluated in exports them (OTIS_C_*), and a script that trusts
# them would look at that repo's worktrees instead of the throwaway one's.
for v in $(env | sed -n 's/^\(OTIS_C_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
# The tests check hues, so they run in one theme whatever yours is.
export OTIS_THEME=gruvbox
eval "$(otis-theme --env)"
# Nor on the host's pager: the zpty tests are a terminal, and a pager that
# waits for a key (more, without less installed) would hang them.
export GIT_PAGER=cat
# Nor on the host's editor: with nvim, a picker runs inside it (otis-frame),
# where the zpty tests drive the picker itself.
export OTIS_EDITOR=true
failed=0 passed=0

# expect <name> <got> <want>
expect() {
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"
  fi
}
# strip: ANSI colors out of stdin, so a test checks words, not hues.
strip() { sed -E 's/\x1b\[[0-9;]*[mK]//g'; }
# screen: what a pty drew, as text, every escape and carriage return gone. As
# bytes: sed and tr stop at a byte that is no character, and a pty has some.
screen() { LC_ALL=C sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | LC_ALL=C tr -d '\r'; }
# awk_fn <expression>: evaluate one rowfmt.awk expression.
awk_fn() { awk "$(cat "$share/rowfmt.awk")"'BEGIN { print '"$1"' }' </dev/null | strip; }
jq_fn() { jq -nr -L "$share" "include \"otis\"; $1" | strip; }

tmp=$(mktemp -d) && tmp=$(cd "$tmp" && pwd -P) || exit 1
# finish, on exit: the area's count, last. An area that quit before its end
# (a syntax error, an exit) failed, whatever passed before it.
finish() {
  rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || { failed=1; printf 'FAIL %s quit early (exit %s)\n' "${0##*/}" "$rc"; }
  printf '\n%s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ] || exit 1
}
trap finish EXIT
# A script's scratch files that no state dir names land here, not beside
# another area's running at the same time.
export TMPDIR=$tmp/t && mkdir "$TMPDIR"
# The pickers run here log their keys here, not in your own key log.
export OTIS_KEY_LOG=$tmp/keys.tsv
# Editors that echo what they were asked, so the tests that pick nvim do not
# depend on this machine having it.
mkdir -p "$tmp/eds"
for e in cursor nvim zed hx; do printf '#!/bin/sh\necho "$@"\n' > "$tmp/eds/$e"; chmod +x "$tmp/eds/$e"; done
# 220 columns: the pickers sit side by side from 120 up (git-fzf), so the row
# scripts get 45% of this, the same budget the rows had back when a 100-column
# terminal still gave the list all of itself.
export HOME=$tmp XDG_CACHE_HOME=$tmp/cache GIT_CONFIG_GLOBAL=$tmp/gitconfig FZF_COLUMNS=220
# No cliamp of yours: the screens' music strip and background would be drawn
# over what the tests read of them.
unset CLIAMP_CONFIG_DIR XDG_CONFIG_HOME XDG_DATA_HOME
# Where git-worktree-trash puts what it throws away, under that home.
case $(uname) in Darwin) trash=$HOME/.Trash ;; *) trash=$HOME/.local/share/Trash/files ;; esac
git init -q -b main "$tmp/origin" && (
  cd "$tmp/origin" && git config user.email t@t && git config user.name t &&
  printf 'a\n' > a.ts && printf 'b\n' > b.spec.ts && mkdir -p src && printf 'c\n' > src/c.ts &&
  git add -A && git commit -qm "First" && printf 'a2\n' > a.ts && git commit -qam "Second"
) && git clone -q "$tmp/origin" "$tmp/repo" 2>/dev/null && cd "$tmp/repo" || exit 1
git config user.email t@t; git config user.name t
# No test ever calls Claude: the symbol view would gloss its fixture otherwise.
git config otis.symbolsModel off
git config otis.callersFixModel off
git config otis.callers off

# --- the pickers themselves, headless: otis-pick runs on a pty (zsh's zpty)
# and the test drives it through its port (it takes OTIS_FZF_LISTEN and
# OTIS_FZF_API_KEY for exactly this) and by typing into the pty.
#   picker_open <zsh command>   start it; picker_state prints the picker's state JSON
#   picker_key <keys>           type into it   picker_act <action>  an fzf action
#   picker_close                end it, and wait for it to go
opened=0 drive=$tmp/drive
picker_open() {
  # Each picker on a port of its own, ten to an area by its pid: one just
  # closed can be waiting out TCP's TIME_WAIT, and the next could not listen.
  # All below 49152, where the system takes ports for connections going out.
  port=$((40000 + $$ % 900 * 10 + opened % 10)) opened=$((opened + 1))
  rm -f "$drive"; mkfifo "$drive"
  # The driver types what comes down the fifo into the pty, and drains what
  # the picker draws, since a pty nobody reads fills up and stalls it.
  OTIS_FZF_LISTEN=$port OTIS_FZF_API_KEY=otis-test TERM=xterm-256color FZF_COLUMNS= \
    zsh -fc 'zmodload zsh/zpty; zpty -b p "stty rows 40 cols 140; $1"; exec 3< "$2"
      while zpty -t p; do
        if read -t 0.1 -r -u 3 line; then k=${line#key:}; [ "$k" = space ] && k=" "; zpty -wn p "$k"; fi
        while zpty -r p buf; do :; done
      done' - "$1" "$drive" &
  driver=$!
  # The fifo needs a writer open for the driver to keep reading.
  exec 7> "$drive"
  for _ in $(seq 80); do
    curl -s -H 'x-api-key: otis-test' "localhost:$port" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}
picker_state() { curl -s -H 'x-api-key: otis-test' "localhost:$port"; }
# picker_rows: the row count once the first load has landed; the port answers
# before the list does.
picker_rows() {
  for _ in $(seq 80); do
    n=$(picker_state | jq .matchCount); [ "${n:-0}" -gt 0 ] && { echo "$n"; return; }
    sleep 0.25
  done
  echo "${n:-0}"
}
# An action sent while the picker reloads is dropped, so wait for the reload.
picker_act() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ "$(picker_state | jq -r .reading 2>/dev/null)" = false ] && break
    sleep 0.25
  done
  curl -s -H 'x-api-key: otis-test' -XPOST "localhost:$port" -d "$1"; sleep 0.3
}
picker_key() { printf 'key:%s\n' "$1" >&7; sleep 0.4; }
picker_close() { picker_act abort; exec 7>&-; wait "$driver" 2>/dev/null; }

# sym_branch: the change the symbol view reads, as a branch sym of two commits,
# $base and $head: lib.ts's type, functions and class changed, callers of them
# elsewhere for tsgo, a const and a type of one name, and a generated file.
sym_branch() {
  git checkout -qb sym
  # stale is wrong on both sides and moves down as the change adds lines
  # above it: an error the changed file had already is not the change's.
  printf 'export type Opts = { a: number };\nexport function run(o: Opts): number {\n  return o.a;\n}\nfunction helper() {\n  return 1;\n}\nexport class Box {\n  size = 1;\n  grow(): void {\n    this.size++;\n  }\n  shrink(): void {\n    this.size--;\n  }\n}\nexport function again(): number { return run({ a: 1 }); }\nexport function build(a: number): Opts { return { a } as Opts; }\nexport const stale: number = "x";\n' > lib.ts
  # app.ts calls run and the change never touches it: a caller elsewhere, for
  # tsgo to find (the tsconfig makes the repo a project, the package.json
  # names it for git-callers --spec).
  # main has a type error of its own already; only the one run's new
  # parameter brings is the change's.
  printf 'import { run } from "./lib";\n\nexport function main(): number {\n  const bad: number = "x";\n  return run({ a: 1 });\n}\n' > app.ts
  printf 'import { run } from "./lib";\nexport const r = run({ a: 1 });\n' > lib.spec.ts
  # other.ts never names Opts, only build, which is unchanged; Opts gaining
  # b breaks its literal all the same: what the change breaks without a call.
  printf 'import { build } from "./lib";\n\nexport const z: ReturnType<typeof build> = { a: 1 };\n' > other.ts
  printf '{ "compilerOptions": { "strict": true, "module": "esnext", "moduleResolution": "bundler" } }\n' > tsconfig.json
  printf '{ "name": "fx", "type": "module" }\n' > package.json
  git add lib.ts app.ts lib.spec.ts other.ts tsconfig.json package.json && git commit -qm "Base" && base=$(git rev-parse HEAD)
  printf 'export type Opts = { a: number; b: string };\nexport function run(o: Opts, twice: boolean): number {\n  return o.a;\n}\nexport class Box {\n  size = 1;\n  grow(): void {\n    this.size += 2;\n  }\n  shrink(): void {\n    this.size--;\n  }\n}\n\n/** the new one */\nexport const fresh = (o: Opts) => o.b;\n\nconsole.log(fresh);\nexport type Wide = Opts extends { a: 1 } ? 1 : 0;\nexport function again(): number { return run({ a: 1 }); }\nexport function build(a: number): Opts { return { a } as Opts; }\nexport const stale: number = "x";\n' > lib.ts
  # A const and a type of one name, Effect's schema pattern: two symbols.
  printf 'export const Pair = { a: 1 };\nexport type Pair = typeof Pair;\nexport function usePair(p: Pair) { return p; }\nexport function usePairToo(p: Pair) { return p; }\nexport class Svc extends Base<Svc>()("Svc", { a: 1 }) {}\nexport const tpl = `Svc ${usePair(1)}`;\n' > pair.ts
  # A generated file that uses run: listed in its own section, and no edge
  # to run, which stays an entry point.
  printf 'export const G = run({ a: 1 }, true);\n' > gen.generated.ts
  git add pair.ts gen.generated.ts && git commit -qam "Head" && head=$(git rev-parse HEAD)
  mkdir -p "$tmp/symst"
}
# peek [width]: p on run's row in sym_branch's change, at a preview this wide,
# afresh: the notes under its names.
peek() { rm -f "$tmp/symst/peeks"; printf '%s' "${1:-100}" > "$tmp/symst/cols"; GIT_FZF_STATE=$tmp/symst git-symbols --peeks "$base..$head" lib.ts new 2 4 'lib.ts#run'; }
