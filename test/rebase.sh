#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-mr-rebase: b has GitLab rebase the MR, and the local branch follows
# it to the rebased commit. GitLab is a stub: its rebase moves the branch on
# origin, and its MR still shows the commit from before the rebase when it
# says the rebase is over, as the real one does for a moment.
here=$PWD rb=$tmp/rb
mkdir -p "$rb/stub" && git init -q --bare "$rb/origin.git"
git init -q "$rb/work" && cd "$rb/work" && git config user.email t@t && git config user.name t
printf 'a\n' > f && git add f && git commit -qm base && git branch -qM main
git checkout -qb feat && printf 'b\n' > g && git add g && git commit -qm change
git remote add origin "$rb/origin.git" && git push -q origin main feat
git clone -q "$rb/origin.git" "$rb/gitlab" 2>/dev/null && git -C "$rb/gitlab" config user.email g@g && git -C "$rb/gitlab" config user.name g
cat > "$rb/stub/glab" <<'STUB'
#!/bin/sh
case "$*" in
  *"-X PUT"*/rebase) (cd "$RB/gitlab" && git fetch -q origin && git checkout -q -B feat origin/feat && git rebase -q origin/main && git push -q --force origin feat) >/dev/null 2>&1; echo '{}' ;;
  *) printf '{"iid":9,"title":"change","sha":"%s","source_branch":"feat","target_branch":"main","diverged_commits_count":1,"rebase_in_progress":false,"merge_error":null}\n' "$(cat "$RB/old")" ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$rb/stub/git-confirm"
printf '#!/bin/sh\necho "$2" >> "$RB/said"\n' > "$rb/stub/otis-popup"
chmod +x "$rb/stub/"*
# rb_rebase: main gets a commit on origin, then b on the MR.
rb_n=0
rb_rebase() {
  rb_n=$((rb_n + 1))
  (cd "$rb/gitlab" && git fetch -q origin && git checkout -q -B main origin/main && echo $rb_n >> f && git commit -qam later && git push -q origin main) >/dev/null 2>&1
  git --git-dir="$rb/origin.git" rev-parse feat > "$rb/old"
  PATH=$rb/stub:$PATH RB=$rb git-mr-rebase 9 >/dev/null 2>&1
}
rb_origin() { git --git-dir="$rb/origin.git" rev-parse feat; }
git checkout -q main
rb_rebase
expect mr-rebase/branch-follows-while-the-mr-lags "$(git rev-parse feat | grep -vx "$(cat "$rb/old")")" "$(rb_origin)"
git checkout -q feat && printf 'wip\n' >> g
rb_rebase
expect mr-rebase/checkout-follows-keeping-changes "$(git rev-parse HEAD | grep -vx "$(cat "$rb/old")"; git status --short)" "$(rb_origin)
 M g"
git commit -qam mine && rb_mine=$(git rev-parse feat)
rb_rebase
expect mr-rebase/own-commits-left-alone "$(git rev-parse feat; grep -c 'left alone' "$rb/said")" "$rb_mine
1"
# An old copy of GitLab's branch, with nothing of yours in it: pushed from
# here, then rewritten on GitLab from somewhere else. It follows too.
git push -q --force origin feat && git checkout -q main
(cd "$rb/gitlab" && git fetch -q origin && git checkout -q -B feat origin/feat && git commit -q --amend -m reworded && git push -q --force origin feat) >/dev/null 2>&1
rb_rebase
expect mr-rebase/old-copy-follows "$(git rev-parse feat; grep -c 'left alone' "$rb/said")" "$(rb_origin)
1"
cd "$here"

