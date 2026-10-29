#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-worktree-sweep: merged branches' worktrees go on their own
cache=$(git rev-parse --git-common-dir)/branch-mrs.tsv
git branch -q old main && git branch -q keep main && git branch -q live main
git-worktree-add old old >/dev/null 2>&1 && git-worktree-add keep keep >/dev/null 2>&1 && git-worktree-add live live >/dev/null 2>&1
printf 'old\tmerged\t7\t%s\tmine\tmain\nkeep\tmerged\t8\t%s\tmine\tmain\nlive\topened\t9\t%s\tmine\tmain\n' "$(git rev-parse old)" "$(git rev-parse keep)" "$(git rev-parse live)" > "$cache"
touch "$tmp/repo/.claude/worktrees/keep/scratch.ts"
printf '.env\n' >> "$tmp/repo/.git/info/exclude" && printf 'secret\n' > "$tmp/repo/.claude/worktrees/old/.env"
touch "$(git -C "$tmp/repo/.claude/worktrees/old" rev-parse --absolute-git-dir)/autofetch-stamp"
expect sweep/shell-there-kept "$(git-worktree-sweep)$([ -d "$tmp/repo/.claude/worktrees/old" ] && echo kept)" "kept"
touch -t 202001010000 "$(git -C "$tmp/repo/.claude/worktrees/old" rev-parse --absolute-git-dir)/autofetch-stamp"
expect sweep/merged-goes "$(git-worktree-sweep | cut -d' ' -f1-6)" "old and its branch old (merged)"
expect sweep/gone "$([ -d "$tmp/repo/.claude/worktrees/old" ] && echo still)$(git rev-parse -q --verify old)" ""
expect sweep/ignored-kept "$(cat "$trash"/old-*/.env 2>/dev/null)" "secret"
expect sweep/dirty-kept "$([ -d "$tmp/repo/.claude/worktrees/keep" ] && echo kept) $(git branch --list keep | tr -d ' +')" "kept keep"
expect sweep/open-kept "$([ -d "$tmp/repo/.claude/worktrees/live" ] && echo kept)" "kept"
git worktree remove --force "$tmp/repo/.claude/worktrees/keep" && git worktree remove "$tmp/repo/.claude/worktrees/live" && git branch -qD keep live && rm -f "$cache"

# --- otis-bazel-sweep: Bazel's builds of checkouts that are gone go too
bz=$tmp/Library/Caches/bazel
build() { mkdir -p "$1/execroot/x" && printf '%s' "$2" | tee "$1/DO_NOT_BUILD_HERE" > "$1/execroot/DO_NOT_BUILD_HERE"; }
md5of() { printf '%s' "$1" | { md5sum 2>/dev/null || md5; } | cut -c1-32; }
build "$bz/_bazel_me/$(md5of "$tmp/repo/.claude/worktrees/gone")" "$tmp/repo/.claude/worktrees/gone"
chmod -R a-w "$bz/_bazel_me/$(md5of "$tmp/repo/.claude/worktrees/gone")/execroot"
build "$bz/_bazel_me/$(md5of "$tmp/repo")" "$tmp/repo"
build "$bz/shared-main" "$tmp/repo/.claude/worktrees/was-nested"
build "$bz/shared-scratch" "$tmp/scratch/wt"
build "$bz/shared-stale" "$tmp/scratch/wt2" && mkdir "$bz/shared-stale/server" && echo $$ > "$bz/shared-stale/server/server.pid.txt"
build "$bz/shared-live" "$tmp/scratch/wt3" && mkdir "$bz/shared-live/server"
sh -c 'sleep 30; :' sh --output_base="$bz/shared-live" & bzlive=$! && echo $bzlive > "$bz/shared-live/server/server.pid.txt"
mkdir -p "$bz/_bazel_me/cache/repos" "$bz/_bazel_me/install"
expect bazel/line "$(otis-bazel-sweep | cut -d' ' -f2-)" "Bazel's builds for 3 checkouts that are gone"
expect bazel/left "$(cd "$bz" && find . -name DO_NOT_BUILD_HERE | LC_ALL=C sort | sed 's|/DO_NOT_BUILD_HERE||; s|/[0-9a-f]\{32\}|/md5|')" "./_bazel_me/md5
./_bazel_me/md5/execroot
./shared-live
./shared-live/execroot
./shared-main
./shared-main/execroot"
expect bazel/cache-kept "$(cd "$bz/_bazel_me" && command ls -d cache install | tr '\n' ' ')" "cache install "
expect bazel/quiet-after "$(otis-bazel-sweep)" ""
kill $bzlive 2>/dev/null; wait $bzlive 2>/dev/null; rm -rf "$bz"

# --- git-stack --sweep: glab stacks left behind by merged ones
git branch alive-layer
st=$(git rev-parse --path-format=absolute --git-common-dir)/stacked
mkdir -p "$st/gone" "$st/kept"
printf '{"branch":"cahoon-gone-853ee756","sha":"x","prev":"","next":""}' > "$st/gone/1.json"
printf '{"branch":"alive-layer","sha":"y","prev":"","next":""}' > "$st/kept/1.json"
git config glab.currentstack gone
git-stack --sweep > "$tmp/sweep.out"
expect stack/sweep-forgets "$(ls "$st" | tr '\n' ' ')" "kept "
expect stack/sweep-says-so "$(strip < "$tmp/sweep.out")" "git-stack: forgot the glab stack gone, whose branches are all gone from here"
expect stack/sweep-unsets "$(git config --get glab.currentstack; echo "rc=$?")" "rc=1"
# One whose layers are still here is left alone, currentstack included.
git config glab.currentstack kept
git-stack --sweep > /dev/null
expect stack/sweep-keeps-live "$(ls "$st" | tr '\n' ' ')" "kept "
expect stack/sweep-keeps-current "$(git config --get glab.currentstack)" "kept"
rm -rf "$st"; git config --unset glab.currentstack; git branch -D alive-layer >/dev/null 2>&1
