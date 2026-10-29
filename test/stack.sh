#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-mr-rebase on a stack: b on any layer rebases all of it here, the
# bottom onto origin/main and each layer onto the one below as rebased, pushes
# it all at once, and the local branches follow. GitLab is a stub answering
# from a list of MRs; origin is a bare repo. !2 (high) was cut from !1 (low)
# before low's last commit, as a stack is once its bottom moves on. Claude
# is a stub that gives up on a conflict, or with RS_CLAUDE=settle settles it
# by keeping both sides.
here=$PWD rs=$tmp/rs
mkdir -p "$rs/stub" && git init -q --bare "$rs/origin.git"
printf '1 low main make it low\n2 high low make it high\n3 solo main all alone\n' > "$rs/mrs"
cat > "$rs/stub/glab" <<'STUB'
#!/bin/sh
p=${2#projects/:fullpath/merge_requests}
mr() { jq -R 'split(" ") | {iid: (.[0] | tonumber), source_branch: .[1], target_branch: .[2], title: (.[3:] | join(" "))}'; }
case $p in
  \?*) q=${p#*opened&}; f=${q%%=*} v=${q#*=}; [ "$f" = source_branch ] && c=2 || c=3
    awk -v c=$c -v v="$v" '$c == v' "$RS/mrs" | mr | jq -s . ;;
  /*) i=${p#/}; i=${i%%\?*}; awk -v i="$i" '$1 == i' "$RS/mrs" | mr | jq --arg i "$i" '. + {has_conflicts: ($i == "3")}' ;;
esac
STUB
cat > "$rs/stub/claude" <<'STUB'
#!/bin/sh
cat > /dev/null
if [ "$RS_CLAUDE" = settle ]; then
  for f in $(git diff --name-only --diff-filter=U); do grep -vE '^(<<<<<<<|[|]{7}|=======|>>>>>>>)' "$f" > "$f.n"; mv "$f.n" "$f"; done
  echo '{"type":"result","is_error":false,"structured_output":{"resolved":true,"summary":"kept both sides."}}'
else
  echo '{"type":"result","is_error":false,"structured_output":{"resolved":false,"summary":"which side wins is the author'"'"'s call."}}'
fi
STUB
printf '#!/bin/sh\n[ -z "$RS_NO" ] && exit 0; echo "$1" > "$RS/asked"; exit 1\n' > "$rs/stub/git-confirm"
printf '#!/bin/sh\necho "$2" >> "$RS/said"\n' > "$rs/stub/otis-popup"
chmod +x "$rs/stub/"*
git init -q "$rs/work" && cd "$rs/work" && git config user.email t@t && git config user.name t
seq 1 9 > f && echo k > k && git add f k && git commit -qm base && git branch -qM main
git checkout -qb low && echo l1 > l && git add l && git commit -qm l1
git checkout -qb high && echo h1 > h && git add h && git commit -qm h1
git checkout -q low && echo l2 >> l && git commit -qam l2
git remote add origin "$rs/origin.git" && git push -q origin main low high
git clone -q -b main "$rs/origin.git" "$rs/gitlab" 2>/dev/null && git -C "$rs/gitlab" config user.email g@g && git -C "$rs/gitlab" config user.name g
(cd "$rs/gitlab" && sed -i.x 1s/1/one/ f && git commit -qam later && git push -q origin main) >/dev/null 2>&1
git worktree add -q "$rs/wt" high && echo wip >> "$rs/wt/k" && rs_orig=$(git rev-parse high)
rs() { PATH=$rs/stub:$PATH RS=$rs git-mr-rebase "$@" 2>&1; }
rs_subjects() { git log --format=%s "$1" | paste -sd' ' -; }
expect mr-rebase/stack-check-from-either-layer "$(rs --check mine 1; rs --check mine 2)" "execute(git-mr-rebase --here 1)
execute(git-mr-rebase --here 2)"
expect mr-rebase/alone-with-conflicts-goes-here "$(rs --check mine 3)" "execute(git-mr-rebase --here 3)"
(RS_NO=1 rs --here 2 >/dev/null)
expect mr-rebase/stack-asks-first "$(cat "$rs/asked"; git --git-dir="$rs/origin.git" rev-parse high | grep -cx "$rs_orig")" "!1  make it low
  2 commits onto main, 1 new there
!2  make it high
  1 commit onto !1
every layer is pushed at once, each with a new pipeline; your branches here follow

rebase the stack?
1"
rs --here 2 >/dev/null
expect mr-rebase/stack-rebased-on-origin "$(git --git-dir="$rs/origin.git" log --format=%s high | paste -sd' ' -)" "h1 l2 l1 later base"
expect mr-rebase/stack-local-follows "$(git rev-parse low high | tr '\n' ' '; git -C "$rs/wt" status --short)" "$(git --git-dir="$rs/origin.git" rev-parse low high | tr '\n' ' ') M k"
expect mr-rebase/stack-in-place "$(rs --here 1 >/dev/null; tail -1 "$rs/said")" "!1, !2 are already in place on main"
# Your own commit on high, not pushed yet, goes up with it.
(cd "$rs/gitlab" && git pull -q && echo more >> f && git commit -qam later2 && git push -q origin main) >/dev/null 2>&1
(cd "$rs/wt" && echo h2 >> h && git commit -qm h2 h)
rs --here 1 >/dev/null
expect mr-rebase/stack-takes-your-commits "$(git --git-dir="$rs/origin.git" log --format=%s high | paste -sd' ' -)|$(git rev-parse high)" "h2 h1 l2 l1 later2 later base|$(git --git-dir="$rs/origin.git" rev-parse high)"
# Moved both here and on GitLab: refused, nothing changed.
(cd "$rs/gitlab" && git fetch -q && git checkout -q -B low origin/low && echo l3 >> l && git commit -qam l3 && git push -q origin low) >/dev/null 2>&1
git checkout -q low && echo l4 >> l && git commit -qam l4 && git checkout -q main
rs_before=$(git --git-dir="$rs/origin.git" rev-parse low high)
rs --here 2 >/dev/null
expect mr-rebase/stack-diverged-refused "$(tail -1 "$rs/said" | grep -c 'each have commits'; git --git-dir="$rs/origin.git" rev-parse low high | grep -cxF "$rs_before")" "1
2"
# The bottom conflicting with main, and Claude giving up: refused, nothing
# changed, and gup there is the way on. Fixed by hand (a rebase taking low's side), b takes your
# rebased low over GitLab's, and high brings only its own commits along, not
# the copies of low's it was cut from.
git branch -qf low origin/low
(cd "$rs/gitlab" && git checkout -q main && git pull -q && echo theirs > l && git add l && git commit -qm clash-l && git push -q origin main) >/dev/null 2>&1
rs_before=$(git --git-dir="$rs/origin.git" rev-parse low high)
rs --here 2 >/dev/null
expect mr-rebase/stack-bottom-conflict-refused "$(tail -1 "$rs/said" | grep -c "commit .* \"l1\" conflicts with main, in l. Claude could not settle it: which side wins is the author's call. gup in a checkout of low, fix it there, then b again does the rest"; git --git-dir="$rs/origin.git" rev-parse low high | grep -cxF "$rs_before")" "1
2"
git checkout -q low && git rebase -q -X theirs origin/main >/dev/null 2>&1 && git checkout -q main
rs --here 2 >/dev/null
expect mr-rebase/stack-after-a-fix-by-hand "$(git --git-dir="$rs/origin.git" log --format=%s high | paste -sd' ' -)|$(git rev-parse low high | grep -cxF "$(git --git-dir="$rs/origin.git" rev-parse low high)")" "h2 h1 l3 l2 l1 clash-l later2 later base|2"
# A layer conflicting with the one below as rebased, Claude giving up:
# refused, nothing changed.
(cd "$rs/gitlab" && git pull -q && echo theirs > h && git add h && git commit -qm clash && git push -q origin main) >/dev/null 2>&1
rs_before=$(git --git-dir="$rs/origin.git" rev-parse low high)
rs --here 1 >/dev/null
expect mr-rebase/stack-conflict-refused "$(tail -1 "$rs/said" | grep -c "commit .* \"h1\" conflicts with !1 as rebased, in h. Claude could not settle it: which side wins is the author's call. rebase it onto !1 by hand"; git --git-dir="$rs/origin.git" rev-parse low high | grep -cxF "$rs_before")" "1
2"
# The same, Claude settling it: the confirm says so, and in it goes.
(RS_NO=1 RS_CLAUDE=settle rs --here 1 >/dev/null)
expect mr-rebase/stack-claude-settled-asks "$(grep -c "^  Claude settled [0-9a-f]* in h: kept both sides.$" "$rs/asked")" "1"
# With otis.lintCommand set, what Claude settled is linted before the confirm,
# which says how that went, and what lint fixed goes in with it.
git config otis.lintCommand 'echo "error: h is wrong" >&2; exit 1'
(RS_NO=1 RS_CLAUDE=settle rs --here 1 >/dev/null)
expect mr-rebase/stack-claude-settled-lint-failed "$(grep -c '^  lint failed: error: h is wrong (all of it in .*/lint.log)$' "$rs/asked")" "1"
git config otis.lintCommand 'git cat-file -e "$GIT_BASE_REF^{commit}" && cat "$OTIS_CHANGED_FILES" > "$RS/linted" && { echo linted; cat h; } > h.n && mv h.n h'
(RS_NO=1 RS_CLAUDE=settle rs --here 1 >/dev/null)
expect mr-rebase/stack-claude-settled-lint-passed "$(grep -A1 '^  Claude settled' "$rs/asked" | tail -1)" "  lint passed"
(RS_CLAUDE=settle rs --here 1 >/dev/null)
git config --unset otis.lintCommand
expect mr-rebase/stack-claude-settled "$(git --git-dir="$rs/origin.git" log --format=%s high | paste -sd' ' -)|$(git --git-dir="$rs/origin.git" show high:h | paste -sd' ' -)|$(cat "$rs/linted")|$(git rev-parse high | grep -cxF "$(git --git-dir="$rs/origin.git" rev-parse high)")" "h2 h1 l3 l2 l1 clash clash-l later2 later base|linted theirs h1 h2|h|1"
# A commit that comes out empty, its change there already, is dropped, and
# the confirm says so.
(cd "$rs/gitlab" && git pull -q && printf 'x\n' > same && git add same && git commit -qm same-x && printf 'y\n' >> same && git commit -qam same-y && git push -q origin main) >/dev/null 2>&1
(cd "$rs/wt" && printf 'x\ny\n' > same && git add same && git commit -qm same)
(RS_NO=1 rs --here 1 >/dev/null)
expect mr-rebase/stack-says-what-dropped "$(grep -c '^  2 commits onto !1, with 1 of yours not on GitLab yet; 1 more dropped, as !1 has its change already$' "$rs/asked")" "1"
# An old copy of GitLab's low, with nothing of yours in it (pushed from here,
# then rewritten on GitLab from somewhere else), is not refused: the layer
# starts from GitLab's, and yours follows.
(cd "$rs/gitlab" && git fetch -q && git checkout -q -B low origin/low && git commit -q --amend -m l3-reworded && git push -q --force origin low) >/dev/null 2>&1
rs --here 1 >/dev/null
expect mr-rebase/stack-old-copy-follows "$(grep -c 'each have commits' "$rs/said"; git --git-dir="$rs/origin.git" log -1 --format=%s low; git rev-parse low | grep -cxF "$(git --git-dir="$rs/origin.git" rev-parse low)")" "1
l3-reworded
1"
git worktree remove --force "$(git-worktree-path named claude-fix)"
git worktree remove --force "$rs/wt"
cd "$here"

