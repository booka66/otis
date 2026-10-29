#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-symbols-past: where the changed code broke before, from git alone.
# A change, a fix to its lines five days on (laid at it), a fix that only
# adds (laid at no one) and a fix of the types (not a fix of what it does).
ps=$tmp/past && git init -q "$ps" && (
  cd "$ps" && git config user.email t@t && git config user.name t
  at() { d=$(( $(date +%s) - $1 * 86400 )); export GIT_AUTHOR_DATE="@$d" GIT_COMMITTER_DATE="@$d"; }
  printf 'export function send() {\n  const a = 1;\n  return a;\n}\n' > s.ts; at 200; git add s.ts; git commit -qm "Add send"
  sed -i.b 's/const a = 1/const a = retry(1)/' s.ts; at 100; git commit -qam "Retry the send"
  sed -i.b 's/retry(1)/retry(1, once)/' s.ts; at 95; git commit -qam "fix: the retry sent twice"
  sed -i.b 's/  return a;/  log(a);\n  return a;/' s.ts; at 50; git commit -qam "Fix the missing log"
  sed -i.b 's/once)/once as N)/' s.ts; at 40; git commit -qam "fix types"
  rm -f s.ts.b
  printf 's.ts\tfn\tsend\t\t1\tbody\tnew\t1\t5\t1\t1\t1\t\t1\t5\n' > t.tsv
  node "$share/past.mjs" "$(git rev-parse HEAD)" t.tsv
) > "$tmp/past.out" 2>&1
expect past/fixes "$(cut -f1-3 "$tmp/past.out")" "s.ts#send	5	2"
expect past/laid "$(cut -f4 "$tmp/past.out" | tr '\036\037' '\n|' | cut -d'|' -f3,6,7)" "Fix the missing log
fix: the retry sent twice|Retry the send|5"

