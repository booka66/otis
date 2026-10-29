#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-test-files
rows=$(printf 'x\ta.ts\ny\tb.spec.ts\nz\tsrc/c.test.tsx\n')
expect test-files/count "$(printf '%s\n' "$rows" | cut -f2 | git-test-files count)" "2"
expect test-files/filter-shown "$(printf '%s\n' "$rows" | git-test-files filter 2 | wc -l | tr -d ' ')" "3"
expect test-files/section-heading "$(printf '%s\n' "$rows" | git-test-files filter --section 2 | strip | sed -n 2p | sed -E 's/^(.{15}).*/\1/')" "── 2 test files"
cfg=$(printf 'x\tsrc/a.ts\ny\tsrc/BUILD.bazel\nz\tpackage.json\nw\tlibs/tsconfig.build.json\nv\tlibs.bzl\nu\tpackage-json.ts\n')
expect test-files/config-heading "$(printf '%s\n' "$cfg" | git-test-files filter --section 2 | strip | sed -n 3p | sed 's/ ·.*//')" "── 4 build and config files"
expect test-files/config-not-source "$(printf '%s\n' "$cfg" | git-test-files filter --section 2 | sed -n 2p | cut -f2)" "package-json.ts"
git-test-files toggle
expect test-files/hidden "$(git-test-files hidden; echo $?)" "0"
expect test-files/filter-hidden "$(printf '%s\n' "$rows" | git-test-files filter 2 | wc -l | tr -d ' ')" "1"
git-test-files toggle
expect test-files/shown-again "$(git-test-files hidden; echo $?)" "1"

# --- git-log-list, git-file-list: the row shape the pickers rely on
expect log-list/fields "$(git-log-list | strip | awk -F'\t' '{ print NF }' | sort -u)" "3"
expect log-list/sha-last "$(git-log-list -1 | cut -f2)" "$(git rev-parse --short HEAD)"
expect log-list/cap "$(git-log-list | wc -l | tr -d ' ')" "2"
# Your commits are the ones the base has not got, and they stay bright once the
# branch is pushed; the upstream only says which are still in your hands.
shade() { git-log-list -1 | awk 'NR == 1 { match($0, /38;2;[0-9;]+/); print substr($0, RSTART, RLENGTH) }'; }
printf 'yours\n' > yours.txt && git add yours.txt && git commit -qm "one of yours"
expect log-list/held "$(shade)" "38;2;254;128;25"
git update-ref refs/remotes/origin/pushed HEAD && git branch --set-upstream-to=origin/pushed >/dev/null 2>&1
expect log-list/pushed-still-yours "$(shade)" "38;2;250;189;47"
git branch --unset-upstream >/dev/null 2>&1; git update-ref -d refs/remotes/origin/pushed
git reset -q --hard HEAD~1
# A subject longer than two lines is a paragraph: its row says the
# sentences of it that fit, a colon ending one, the preview all of it. A
# title is whole, colon and all, however far past 72 it runs.
long="The row says less: a subject this long goes on past the hundred and sixty columns a title runs to at most, two lines of the eighty a terminal opens at, so it is prose"
printf 'l\n' > long.txt && git add long.txt && git commit -qm "$long"
printf 's\n' > short.txt && git add short.txt && git commit -qm "Fix main: the consumer skips orders missing from the database, as the e2e test found"
expect log-list/first-sentence "$(git-log-list -2 | strip | cut -f1 | grep -o 'The row says less:.*\|Fix main:.*' | sed 's/  .*//' | tr '\n' '|')" \
  "Fix main: the consumer skips orders missing from the database, as the e2e test found|The row says less:|"
expect log-list/preview-whole "$(FZF_PREVIEW_COLUMNS=200 git-preview-commit HEAD~1 | strip | sed -n 1p)" "$long"
git reset -q --hard HEAD~2
printf 'a3\n' > a.ts && printf 'new\n' > d.ts
expect file-list/fields "$(git-file-list | strip | awk -F'\t' '{ print NF }' | sort -u)" "6"
expect file-list/paths "$(git-file-list | cut -f2 | sort | tr '\n' ' ')" "a.ts d.ts "
expect file-list/status "$(git-file-list | awk -F'\t' '$2 == "d.ts" { print $3 $4 }')" "??"
git checkout -q -- a.ts && rm d.ts
