# Every otis command, as zsh functions: bin/otis-run sources this and calls
# the one it was run as, so each command is a program on PATH and works from
# any shell. The shell side (prompt hooks, aliases, the cd a picker hands
# back) is git.zsh, otis.bash and otis.fish.

# Every command starts here: outside a git repo it says so plainly, instead of
# git's "fatal: not a git repository" followed by a misleading message.
_g_repo() {
  git rev-parse --git-dir >/dev/null 2>&1 && return 0
  print -u2 "${funcstack[2]}: not inside a git repo"
  return 1
}

# Go to <dir>, and hand it to the shell that ran this command: a program
# cannot move its parent, so the shell's wrapper (git.zsh, otis.bash,
# otis.fish) names a file in OTIS_CD and goes where it says once the command
# exits. Run without one, it says where to go instead.
_g_cd() {
  cd "$1" || return
  if [[ -n $_otis_cd_file ]]; then
    print -r -- "$PWD" > "$_otis_cd_file"
  else
    print -u2 "now: cd ${PWD/#$HOME/~}"
  fi
}

# Stage everything, commit it with gcm's checks, and push with gp.
gcp() {
  _g_repo || return 1
  [[ -n $1 ]] || { print -u2 'usage: gcp "subject"   stage everything, commit, push'; return 2 }
  git add -A && gcm "$*" && gp
}

# Bare gi lists the tags there are; gi <tags> fetches those rules. The list is
# kept as it goes by, so completing a tag never has to fetch anything
# (bin/otis-complete).
gi() {
  local cache=${XDG_CACHE_HOME:-$HOME/.cache}/git-alias/gitignore-tags
  if (( ! $# )); then
    local tags
    tags=$(curl -fsSL "https://www.toptal.com/developers/gitignore/api/list") || return 1
    mkdir -p ${cache:h} && print -r -- ${tags//,/$'\n'} > $cache
    # COLUMNS is 0 rather than unset where there is no terminal, which fold refuses.
    print -r -- ${tags//,/ } | fold -s -w $(( COLUMNS > 20 ? COLUMNS : 80 ))
    print
    return
  fi
  curl -fsSL "https://www.toptal.com/developers/gitignore/api/${(j:,:)@}"
}

# Push a stack of branches with gp's safety checks. With no branches named, the
# whole stack this branch is on: it, every branch below it past origin/main (the
# ones gup here moves) and every branch stacked above it (the ones gam here
# restacks); never main, whose commits past origin/main are not a stack to
# force-push.
#
# One push per branch, bottom first, each switched to here: a pre-push hook
# that lints what is pushed and may commit fixes refuses several branches in
# one push and any branch that is not checked out. A branch another worktree
# has checked out is pushed from that worktree instead. This checkout goes back
# where it was at the end. A push that fails, the hook stopping to add a lint fix
# included, stops the rest, since the branches above were built on what that
# branch had.
stack-push() {
  _g_repo || return 1
  local base=$(otis-config base) main=$(otis-config main)
  local -a branches=("$@")
  if (( ! $# )); then
    branches=(${(f)"$(git for-each-ref --format='%(refname:short)' --merged HEAD --no-merged $base refs/heads | grep -vx $main)"})
    (( $#branches )) || { print -u2 "stack-push: no branches here past $base to push"; return 1 }
    branches+=(${(f)"$(git for-each-ref --format='%(refname:short)' --contains HEAD --no-merged $base refs/heads | grep -vx $main)"})
    branches=(${(u)branches})
  fi
  # Bottom first: the fewest commits past the base.
  local b
  branches=(${${(f)"$(for b in $branches; do print -r -- "$(git rev-list --count $base..$b) $b"; done | sort -n)"}#* })

  if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    print -u2 "stack-push: uncommitted changes, and pushing switches branches; commit them or set them aside with gwip"
    return 1
  fi
  local -A held
  local line
  for line in ${(f)"$(_g_held_elsewhere $branches)"}; do
    held[${line%%$'\t'*}]=${line#*$'\t'}
    if [[ -n $(git -C "${line#*$'\t'}" status --porcelain --untracked-files=no) ]]; then
      print -u2 "stack-push: ${line%%$'\t'*} is checked out in ${line#*$'\t'}, which has uncommitted changes the hook's lint commit would take; commit or set them aside first"
      return 1
    fi
  done
  local here=$(git symbolic-ref -q --short HEAD) at=$(git rev-parse HEAD) tip rc=0
  for b in $branches; do
    print "pushing $b${held[$b]:+ from ${held[$b]}}"
    tip=$(git rev-parse "$b")
    if [[ -n ${held[$b]} ]]; then
      git -C "${held[$b]}" push origin HEAD --force-with-lease --force-if-includes || { rc=1; break }
    else
      git switch -q "$b" && git push origin HEAD --force-with-lease --force-if-includes || { rc=1; break }
    fi
  done
  if [[ $(git rev-parse HEAD) != $at || $(git symbolic-ref -q --short HEAD) != $here ]]; then
    if [[ -n $here ]]; then git switch -q "$here"; else git switch -q --detach "$at"; fi
  fi
  if (( rc )) && [[ $(git rev-parse "$b") != $tip && $b != $branches[-1] ]]; then
    # The hook committed lint fixes onto $b, which the branches above lack.
    print -u2 "stack-push: the hook added lint fixes to $b; put the branches above on it, then push again:"
    print -u2 "  git switch $branches[-1] && git rebase --update-refs $b && stack-push"
  elif (( rc )); then
    print -u2 "stack-push: stopped at $b"
  fi
  return $rc
}

# ------------------------------------------------------------- git, fzf-driven
# gs is a plain alias in git.zsh. These are the ones that replace reaching
# for lazygit: each one is a picker, so you never load a TUI.

# Switch branches. main is pinned first, then newest first; each row shows the
# branch's MR state, how far it is ahead of and behind origin/main, and when it
# last moved. c opens its own commits in gl (git-branch-log), and C has Claude
# propose fixes for the branch you are on, before it has an MR (git-branch-fix).
# A branch checked out in another worktree comes here: that worktree is
# detached or removed first (_g_goto_branch), so this checkout is where you
# work and worktrees are for what runs beside it. W leaves this checkout alone
# and opens the branch in a worktree of its own, or goes to the one it is in.
# d deletes the marked branches, or the one under the cursor, and M marks the
# ones that lose nothing (git-branch-delete); one checked out anywhere stays.
gb() {
  _g_repo || return 1
  local sel
  sel=$(git-fzf 'branch ' 'enter=switch to it,c=its commits,C=Claude proposes fixes,V=verify in Cursor Cloud (pushes it first if origin is behind),W=open in its own worktree,space=mark,d=delete,M=mark safe to delete,n=open an MR for it or a stack (asks first),w=open MR,y=copy MR link,t=tests,l=labels,a=reviewers,u=refresh' --multi --ansi --track \
      --delimiter=$'\t' --with-nth=1 --id-nth=2 \
      --bind 'start:reload(git-branch-list --switch | tee "$GIT_FZF_STATE/bg.shown")' \
      --bind 'u:execute-silent(git-fzf-bg git-branch-list --switch --refresh)' \
      --bind 'W:print(worktree)+accept' \
      --bind 'space:toggle' \
      --bind 'M:transform(git-branch-list --safe)' \
      --bind 'result:unbind(result)+transform(git-branch-list --safe-after)' \
      --bind 'd:execute(git-branch-delete {+2})+clear-multi+execute-silent(git-fzf-bg git-branch-list --switch --refresh)' \
      --bind 'c:execute(git-branch-log {2})' \
      --bind 'C:execute(git-branch-fix {2} {5})' \
      --bind 'V:execute(git-verify --branch {2} {5})+refresh-preview' \
      --bind 't:execute-silent(git-test-files toggle; git-test-files state > "$GIT_FZF_STATE/footer")+refresh-preview+transform-footer(git-fzf-footer)' \
      --bind 'n:transform(git-mr-new --check {2} {5})' \
      --bind 'w:transform(git-mr-do web {5})' \
      --bind 'y:transform(git-mr-do copy {5})' \
      --bind 'l:transform(git-mr-do labels {5})' \
      --bind 'a:transform(git-mr-do reviewers {5})' \
      --preview 'git-branch-preview {2} {3} {6} {4} {5} {7} {8} {9}' </dev/null) || return
  [[ -z $sel ]] && return
  # W prints "worktree" above the row; enter prints the row alone.
  local -a lines=("${(@f)sel}")
  local how=
  [[ $lines[1] == worktree ]] && { how=worktree; shift lines }
  local -a f=("${(@ps:\t:)lines[1]}")
  _g_goto_branch "$f[2]" $how
}

# Get onto a branch the way gb and gmr do: already on it says so, and one
# missing locally is fetched from origin and tracked. One checked out in
# another worktree is brought here, since git allows a branch one place: that
# worktree is detached if it is one otis reuses (gmr's review and mine), or
# removed if it was made for the branch (gwn, W, B in the proposals), and the
# branch keeps every commit either way. Uncommitted changes there are yours
# to settle first; W goes there. A branch checked out in the main checkout is
# never taken from it: that is home, so you go there. With "worktree" (W in
# gb and gmr) the branch goes in a worktree of its own, named after its last
# part, instead of switching this checkout, or you go to the one it is in.
_g_goto_branch() {
  local b=$1 how=$2 wt
  [[ -n $b ]] || return 1
  if [[ $(git branch --show-current) == $b ]]; then
    print "already on $b"
    return
  fi
  wt=$(git-worktree-path of "$b")
  if [[ -n $wt ]]; then
    if [[ $how == worktree || $wt == $(git-worktree-path main) ]]; then
      print "$b is checked out in ${wt/#$HOME/~}, going there"
      _g_cd "$wt"
      return
    fi
    _g_free_branch "$b" "$wt" || return 1
  fi
  if ! git show-ref --verify --quiet "refs/heads/$b"; then
    print "$b is not on this machine; fetching it from origin"
    git fetch --quiet --no-tags origin "+refs/heads/${b}:refs/remotes/origin/${b}" || return 1
  fi
  if [[ $how == worktree ]]; then
    local name=${b##*/}
    [[ -e $(git-worktree-path named "$name") ]] && name=${b//\//-}
    wt=$(git-worktree-path named "$name")
    [[ -e $wt ]] && { print -u2 "${wt/#$HOME/~} already exists; gw shows what is in it"; return 1 }
    if git show-ref --verify --quiet "refs/heads/$b"; then
      git-worktree-add "$name" --quiet "$b" || return 1
    else
      git-worktree-add "$name" --quiet --track -b "$b" "origin/$b" || return 1
    fi
    print "$b is in its own worktree: ${wt/#$HOME/~}"
    _g_cd "$wt"
    return
  fi
  if ! git switch "$b"; then
    print -u2 "to leave this checkout as it is, open $b in a worktree of its own: W in gb or gmr"
    return 1
  fi
}

# Take <branch> out of <worktree>, where it is checked out, so this checkout
# can switch to it. gmr's review and mine are reused, so they are detached
# where they stand; any other worktree exists for its branch, so it goes, to
# the Trash (git-worktree-trash), so nothing ignored there is lost either.
# Anything uncommitted there (or untracked, as git worktree remove counts it)
# stops this, and says how many.
_g_free_branch() {
  local b=$1 wt=$2 n
  n=$(git -C "$wt" --no-optional-locks status --porcelain | wc -l | tr -d ' ')
  if (( n )); then
    print -u2 "$b has $n uncommitted in ${wt/#$HOME/~}; commit or gwip there first, or W goes there"
    return 1
  fi
  if [[ $wt == $(git-worktree-path named review) || $wt == $(git-worktree-path named mine) ]]; then
    git -C "$wt" switch -q --detach || return 1
    print "$b was in ${wt/#$HOME/~}, now detached"
  else
    git-worktree-trash "$wt" || return 1
    print "$b was in ${wt/#$HOME/~}, now in the Trash"
  fi
}

# Worktrees: where your work is, and what can go. Each row leads with its
# branch's state as gb names it, then anything in the way: uncommitted changes,
# a rebase left in progress (git-worktree-list). enter goes there. d removes the
# marked worktrees, or the one under the cursor, leaving any with uncommitted
# changes; a merged or closed branch goes with its worktree, any other stays
# (git-worktree-remove). M marks the ones safe to remove. The picker runs from the main checkout, so removing the worktree you
# are in cannot break it, and you land in the main checkout afterwards.
gw() {
  _g_repo || return 1
  local main=$(git-worktree-path main) here=$(git rev-parse --show-toplevel) sel
  sel=$(cd "$main" && GW_HERE=$here git-fzf 'worktree ' 'enter=go there,space=mark,d=remove,M=mark safe to remove,u=refresh' \
      --multi --ansi --track --delimiter=$'\t' --with-nth=1 --id-nth=2 \
      --bind 'start:reload(git-worktree-list | tee "$GIT_FZF_STATE/bg.shown")' \
      --bind 'u:execute-silent(git-fzf-bg git-worktree-list --refresh)' \
      --bind 'space:toggle' \
      --bind 'M:transform(git-worktree-list --safe)' \
      --bind 'result:unbind(result)+transform(git-worktree-list --safe-after)' \
      --bind 'd:execute(git-worktree-remove {+2})+clear-multi+execute-silent(git-fzf-bg git-worktree-list --refresh)' \
      --preview 'git-worktree-preview {2} {3} {4} {6} {7} {8}' </dev/null)
  if [[ ! -d $PWD ]]; then
    print "the worktree you were in is gone; now in the main checkout"
    _g_cd "$main"
  fi
  [[ -n $sel ]] || return 0
  local -a lines=("${(@f)sel}")
  local -a f=("${(@ps:\t:)lines[1]}")
  [[ -n $f[2] ]] && _g_cd "$f[2]"
}

# Your branch prefix, from git config otis.branchPrefix (otis-setup
# asks for it); unset, gbn and gwn say how to set it rather than guess.
_gprefix() {
  local p=$(git config --get otis.branchPrefix)
  if [[ -z $p ]]; then
    print -u2 "${1:-gbn}: no branch prefix set; new branches are named <prefix>/<name>"
    print -u2 "  run otis-setup, or: git config --global otis.branchPrefix <your name>"
    return 1
  fi
  print -r -- $p
}

# Shared by gbn and gwn: checks <name> and prints <prefix>/<name>, or explains
# what to do instead. Spaces become dashes, so a name can be typed as a phrase,
# and a name typed with the prefix already on it is not doubled.
_gbranch() {
  local cmd=$1 prefix b
  git rev-parse --git-dir >/dev/null 2>&1 || { print -u2 "$cmd: not inside a git repo"; return 1 }
  prefix=$(_gprefix $cmd) || return 1
  local name=${2#$prefix/}
  local -a words=(${=name})
  name=${(j:-:)words}
  b="$prefix/$name"
  if ! git check-ref-format --branch "$b" >/dev/null 2>&1; then
    print -u2 "$cmd: '$name' can't be a branch name"
    print -ru2 "  use letters, digits and - _ / .   no spaces, '..', ~ ^ : ? * [ \\ or a trailing .lock"
    return 2
  fi
  if git show-ref --verify --quiet "refs/heads/$b"; then
    local wt=$(git-worktree-path of "$b")
    print -u2 "$cmd: $b already exists"
    if [[ -n $wt ]]; then
      print -u2 "  it's checked out at $wt   jump there with gw"
    else
      print -u2 "  switch to it with gb, or: git switch $b"
    fi
    return 1
  fi
  print -r -- "$b"
}

gwn() {
  if [[ -z $1 ]] || (( $# > 2 )); then
    print -u2 "usage: gwn <name> [base]   new worktree on <prefix>/<name>, from $(otis-config base) unless base is given"
    print -u2 "  quote a name with spaces; they become dashes"
    print -u2 "  e.g. gwn billing-dupes"
    return 2
  fi
  local b dir
  b=$(_gbranch gwn "$1") || return
  local name=${b#$(_gprefix gwn)/}
  dir=$(git-worktree-path named "$name")
  [[ -e $dir ]] && { print -u2 "gwn: $dir already exists   jump there, or remove it, with gw"; return 1 }
  git-worktree-add "$name" -b "$b" "${2:-$(otis-config base)}" && _g_cd "$dir"
}

# The log, newest first; bare gl shows the newest 500 and says so in the
# footer (git-log-list). f folds what is staged into the commit under the
# cursor, as gfx does, and r rewords it; either only takes this branch's own
# commits (git-log-do), and the list reloads with the rewritten ones.
gl() {
  _g_repo || return 1
  # Not "${(q)@}": with no positional args that expands to a literal '', and
  # `git log ''` is a fatal error, which empties the list on reload.
  local args
  (( $# )) && args="${(q)@}"
  git-fzf 'log ' 'enter=read it by symbol,o=its files,t=tests,y=copy sha,f=fold staged in,r=reword,m=reset mixed,s=reset soft,h=reset hard' --ansi --no-sort \
      --delimiter=$'\t' --with-nth=1 --id-nth=2 \
      --bind "start:reload(git-log-list $args)" \
      --preview 'git-preview-commit --tests-toggle {2}' \
      --bind 't:execute-silent(git-test-files toggle)+refresh-preview' \
      --preview-window '<66(down,75%,border-top,wrap)' \
      --bind 'enter:execute(git-symbols {2})' \
      --bind 'o:execute(git-commit-open {2})' \
      --bind "f:transform[git-log-do fixup {2} \"reload(git-log-list $args)\"]" \
      --bind "r:transform[git-log-do reword {2} \"reload(git-log-list $args)\"]" \
      --bind "m:execute(git-reset-to mixed {2})+reload(git-log-list $args)" \
      --bind "s:execute(git-reset-to soft {2})+reload(git-log-list $args)" \
      --bind "h:execute(git-reset-to hard {2})+reload(git-log-list $args)" \
      --bind 'y:execute-silent(printf %s {2} | otis-copy)+transform(git-fzf-note copied {2})' </dev/null
}

# Everything this branch changed, as if its commits were one: a file picker over
# the diff from where it left main (three dots, so main's newer commits never
# show as reversed changes), with each file's diff in the preview and enter
# opening your editor at its first change. gdm <base> compares against another base.
gdm() {
  _g_repo || return 1
  local base=${1:-$(otis-config base)}
  git rev-parse -q --verify "$base^{commit}" >/dev/null || { print -u2 "gdm: no such base: $base"; return 1 }
  if [[ -z $(git diff --name-only "$base...HEAD" 2>/dev/null) ]]; then
    print "no changes on this branch since it left $base"
    return
  fi
  git-symbols "$base...HEAD"
}

# Applies by SHA, never pops: the stash stack is shared across all worktrees
# and other sessions push to it concurrently. d drops one, found by SHA the
# same way (git-stash-drop).
gst() {
  _g_repo || return 1
  if [[ -z $(git stash list) ]]; then
    print "no stashes"
    return
  fi
  local sha list='git stash list --color=always --format="%h  %gs  %x1b[${OTIS_T_CONTEXT}m%cr%C(reset)"'
  sha=$(git-fzf 'stash ' 'enter=apply it,d=drop it' --ansi \
      --bind "start:reload[$list]" \
      --bind "d:execute(git-stash-drop {1})+reload[$list]" \
      --preview 'git-preview-commit {1}' </dev/null | awk '{print $1}') || return
  [[ -n $sha ]] && git stash apply "$sha"
}

# One panel for staging, like lazygit's files view: space toggles the row under
# the cursor and the list redraws in place, p picks hunks of it (gah's way),
# and c commits what is staged (gcm's way) without leaving. Unstaging everything
# is U, not u: u refreshes in every other picker, and the muscle memory used to
# land here and throw away a careful round of hunk staging with no way back. git-stage-toggle
# and git-file-list live in bin/ because fzf bindings run in sh and cannot see
# functions. Like gdd, gpark and gah, the panel runs from the repo root, where
# git status's paths start, so its keys act on the right file from any
# subdirectory.
ga() {
  _g_repo || return 1
  if (( $# )); then
    git add -- "$@" && git status --short
    return
  fi
  if [[ -z $(git status --porcelain) ]]; then
    print "nothing to stage or unstage"
    return
  fi
  # By symbol first (git-symbols), where space stages one function; f is the
  # file panel below, where p picks hunks and d discards.
  git-symbols worktree
  git status --short
}

# The file panel, ga's f (and ga itself before the symbol view): one row a
# changed path.
_ga_files() {
  _g_repo || return 1
  local _picked top=$(git rev-parse --show-toplevel)
  # s and git-symbols' f switch between the two views. Opened from the symbol
  # view, s goes back to it rather than opening another on top, or every trip
  # back and forth would be one more q on the way out.
  local _s='execute(OTIS_UNDER=files git-symbols worktree)+reload(git-file-list)'
  [[ $OTIS_UNDER == symbols ]] && _s=abort
  _picked=$(cd "$top" && git-fzf 'files ' 'enter=open in editor,s=by symbol,space=stage it,p=stage hunks,c=commit,d=discard it,a=stage all,U=unstage all,y=copy path,u=refresh,t=tests/config/generated,x=clear lock' --ansi \
      --delimiter=$'\t' --with-nth=1 --track --id-nth=6 \
      --bind 'enter:execute(git-file-open {3} {2} {4})+reload(git-file-list)' \
      --bind 'start:reload(git-file-list)' \
      --bind 't:execute-silent(git-test-files toggle)+reload(git-file-list --cached)' \
      --bind 'space:reload(git-stage-toggle {3} {2} {4})' \
      --bind "s:$_s" \
      --bind 'p:execute(git-stage-hunks {3} {2})+reload(git-file-list -- {2} {4})' \
      --bind 'c:transform:git diff --cached --quiet && git-fzf-note "nothing staged to commit" || echo "execute(git-commit-edit || { echo press enter; read -r _; })+reload(git-file-list)"' \
      --bind 'x:reload(git-clear-lock)' \
      --bind 'd:execute(git-discard-path {3} {2} {4})+reload(git-file-list -- {2} {4})' \
      --bind 'a:reload(git add -A >/dev/null; git-file-list)' \
      --bind 'U:reload(git reset -q >/dev/null; git-file-list)' \
      --bind 'y:execute-silent(printf %s {2} | otis-copy)+transform(git-fzf-note copied {2})' \
      --bind 'u:reload(git-file-list)' \
      --preview 'git-preview-file {3} {2} {4}' </dev/null)
  git status --short
}

gu() {
  _g_repo || return 1
  if (( $# )); then
    git restore --staged -- "$@" && git status --short
  else
    print -u2 "usage: gu <path>   unstage it (or ga, then space)"
    return 2
  fi
}


# Fold what is staged into an earlier commit of this branch. Only this branch's
# commits are offered, and anything in the way is refused before the picker
# opens; the rules and the fold are git-commit-fixup's, shared with gl's f.
gfx() {
  _g_repo || return 1
  git-commit-fixup --check || return 1
  local base=$(otis-config base) sha
  sha=$(git log --oneline --color=always "$base..HEAD" |
    git-fzf 'fixup into ' 'enter=fold the staged changes in' --ansi --no-sort \
      --preview 'git-preview-commit {1}' | awk '{print $1}') || return
  [[ -z $sha ]] && return
  git-commit-fixup "$sha"
}

# Discarding unstaged work is the one git operation with no undo: those changes
# were never objects, so no reflog holds them. Hence the explicit confirm.
# What discarding a row means comes from its status, as in ga's d
# (git-discard-path), not from whether git tracks the path: after git rm
# --cached one path is both a staged deletion and an untracked file. Paths are
# relative to the repo root, where the picker runs.
gdd() {
  _g_repo || return 1
  if [[ -z $(git status --porcelain) ]]; then
    print "nothing to discard"
    return
  fi
  local sel top=$(git rev-parse --show-toplevel)
  sel=$(cd "$top" && git-fzf 'discard ' 'space=mark,t=tests/config/generated,enter=discard marked' --multi --ansi \
      --delimiter=$'\t' --with-nth=1 \
      --bind 'start:reload(git-file-list)' \
      --bind 'space:toggle' \
      --bind 't:execute-silent(git-test-files toggle)+clear-selection+reload(git-file-list --cached)' \
      --preview 'git-preview-file {3} {2} {4}' </dev/null) || return
  [[ -z $sel ]] && return

  local -a f revert new untracked
  local line
  for line in "${(@f)sel}"; do
    f=("${(@ps:\t:)line}")
    case $f[3] in
      '??')  untracked+=("$f[2]") ;;
      A?|?A) new+=("$f[2]") ;;
      # Undoing a rename deletes the new path and brings the old one back.
      R?)    new+=("$f[2]"); revert+=("$f[4]") ;;
      *)     revert+=("$f[2]") ;;
    esac
  done

  print "about to discard:"
  (( $#revert ))    && { print "  revert to HEAD ($#revert):"; printf '    %s\n' $revert }
  (( $#new ))       && { print "  DELETE new files, edits and all ($#new):"; printf '    %s\n' $new }
  (( $#untracked )) && { print "  DELETE untracked ($#untracked):"; printf '    %s\n' $untracked }
  print -n "this cannot be undone. proceed? [y/N] "
  if ! read -q; then print; print "aborted"; return 1; fi
  print

  # Untracked first: with both rows of a git rm --cached marked, the file is
  # deleted and then comes back from HEAD, not the other way round.
  (( $#untracked ))      && rm -rf -- "$top/"${^untracked}
  (( $#revert + $#new )) && git -C "$top" restore --staged --worktree -- $revert $new
  git status --short
}

# Safer sibling: park the selection in a tagged stash instead of destroying it.
gpark() {
  _g_repo || return 1
  if [[ -z $(git status --porcelain) ]]; then
    print "nothing to park"
    return
  fi
  local sel top=$(git rev-parse --show-toplevel)
  sel=$(cd "$top" && git-fzf 'park ' 'space=mark,t=tests/config/generated,enter=stash marked' --multi --ansi \
      --delimiter=$'\t' --with-nth=1 \
      --bind 'start:reload(git-file-list)' \
      --bind 'space:toggle' \
      --bind 't:execute-silent(git-test-files toggle)+clear-selection+reload(git-file-list --cached)' \
      --preview 'git-preview-file {3} {2} {4}' </dev/null) || return
  [[ -z $sel ]] && return
  local -a paths
  paths=("${(@f)$(print -r -- "$sel" | cut -f2)}")
  local tag="park-$(date +%Y%m%d-%H%M%S)"
  git -C "$top" stash push -u -m "$tag" -- $paths &&
    git stash list --format='%h %gs' | grep -F "$tag" |
      sed 's/^/restore with: git stash apply /'
}


# The command list. Each picker's own keys live in its footer and its ? help,
# which come from the same list the bindings do, so they cannot go stale here.
gg() {
  otis-help --all
}

_g_staged_or_die() {
  git diff --cached --quiet 2>/dev/null || return 0
  print -u2 "nothing staged. run ga first."
  return 1
}

# Commit message rules live in git-commit-check, for messages given on the
# command line and ones written in an editor (git-commit-edit) alike.
_g_msg_ok() {
  local problems
  problems=$(print -r -- "$1" | git-commit-check) && return 0
  print -u2 -r -- "$problems"
  return 1
}

# gcm "subject" commits staged work with that message; bare gcm opens your editor with
# the staged diff below the message.
gcm() {
  _g_repo || return 1
  _g_staged_or_die || return 1
  if (( $# )); then
    _g_msg_ok "$*" || return 1
    git-lock || return 1
    git diff --cached --stat | tail -25
    print
    git commit -m "$*"
  else
    git-commit-edit
  fi
}

# gam folds staged work into the last commit, offering to stage everything
# first when nothing is; gam "subject" also rewords it, and
# gam -e rewrites the whole message in your editor with the commit's diff below.
# On a layer of a stack, the branches above it are then rebased onto the new
# commit, so they don't keep the old one. One checked out in another, clean
# worktree is detached there for the rebase (its files stay as they are) and
# put back after, which moves that worktree's files to the restacked commit.
gam() {
  _g_repo || return 1
  # Nothing staged but changes there: they are listed, and y stages them all
  # and goes on. Only for the plain amend; a reword needs nothing staged.
  if (( ! $# )) && git diff --cached --quiet 2>/dev/null && [[ -n $(git status --porcelain) ]]; then
    git status --short
    git-confirm "nothing staged; stage all of these and amend?" || return 1
    git add -A || return 1
  fi
  local here=$(git branch --show-current) old=$(git rev-parse HEAD) top line
  local -a above held
  if [[ -n $here && $here != $(otis-config main) ]]; then
    above=(${(f)"$(git for-each-ref --format='%(refname:short)' --contains HEAD refs/heads | grep -vxF -e "$here" -e "$(otis-config main)")"})
    if (( $#above )); then
      top=$(_g_stack_top $above) || return 1
      held=(${(f)"$(_g_held_elsewhere $above)"})
      for line in $held; do
        if [[ -n $(git -C "${line#*$'\t'}" status --porcelain --untracked-files=no) ]]; then
          print -u2 "gam: ${line%%$'\t'*} sits above this commit, checked out in ${line#*$'\t'} with uncommitted changes there; commit or set them aside first"
          return 1
        fi
      done
    fi
  fi
  if [[ $1 == -e ]]; then
    git-commit-edit --amend
  elif (( $# )); then
    _g_msg_ok "$*" || return 1
    git-lock || return 1
    git commit --amend -m "$*"
  else
    # With nothing staged this would only mint a new SHA for the same commit,
    # which forces a restack and a push of every layer above for nothing.
    if git diff --cached --quiet 2>/dev/null; then
      print -u2 "gam: nothing staged, so there is nothing to amend in"
      print -u2 "  stage first with ga, reword with gam \"new subject\", or rewrite it in your editor with gam -e"
      return 1
    fi
    git-lock || return 1
    git commit --amend --no-edit && git log -1 --oneline
  fi || return
  [[ -n $top && $(git rev-parse HEAD) != $old ]] || return 0
  local n=$#above
  print "restacking $n branch${${n:#1}:+es} above $here"
  for line in $held; do
    git -C "${line#*$'\t'}" switch -q --detach || return 1
  done
  if git rebase --quiet --update-refs --onto "$here" "$old" "$top"; then
    git switch -q "$here"
    for line in $held; do
      git -C "${line#*$'\t'}" switch -q "${line%%$'\t'*}" ||
        print -u2 "gam: could not put ${line#*$'\t'} back on ${line%%$'\t'*}; it is detached at the old commit"
    done
    print "done. push the stack with stack-push"
  else
    print -u2 ""
    print -u2 "conflict restacking $top. fix the files, git add them, git rebase --continue, then git switch $here"
    print -u2 "or git rebase --abort: the amend stays, and the branches above keep the old commit"
    for line in $held; do
      print -u2 "${line#*$'\t'} is detached for this; after, put it back: git -C ${line#*$'\t'} switch ${line%%$'\t'*}"
    done
    return 1
  fi
}

# "<branch>\t<worktree>" for each branch in $@ checked out in another worktree.
_g_held_elsewhere() {
  local wt=$(git rev-parse --show-toplevel)
  git worktree list --porcelain | awk -v here="$wt" -v want=" $* " '
    /^worktree / { w = substr($0, 10) }
    /^branch refs\/heads\// { b = substr($0, 19); if (w != here && index(want, " " b " ")) print b "\t" w }'
}

# The top of the stack above HEAD, the branch every one in $@ leads to, or a
# refusal for what one rebase from it can't carry: chains fanning out from
# HEAD, or unstaged changes.
_g_stack_top() {
  local b top n most=-1
  for b in "$@"; do
    n=$(git rev-list --count HEAD..$b)
    (( n > most )) && { most=$n; top=$b }
  done
  for b in "$@"; do
    if ! git merge-base --is-ancestor $b $top; then
      print -u2 "gam: $b and $top are separate chains on this commit, and one rebase can't carry both; amend with git commit --amend and restack each"
      return 1
    fi
  done
  if ! git diff --quiet; then
    print -u2 "gam: unstaged changes, and restacking the branches above needs a clean tree; stage them or set them aside with gwip"
    return 1
  fi
  print -r -- $top
}

# Setting work aside: a WIP commit beats a stash here, since the stash stack is
# shared across every worktree and other sessions push to it.
gwip() {
  _g_repo || return 1
  git add -A && git commit -qm "wip: ${*:-$(date +%H:%M)}" && git log -1 --oneline
}

gunwip() {
  _g_repo || return 1
  [[ $(git log -1 --format=%s) == wip:* ]] || { print -u2 "HEAD is not a wip commit"; return 1 }
  git reset --soft HEAD~1 && git status --short
}

# clear does not reset the scroll region; a TUI that exits badly leaves it set
# and later output scrolls out of view.
fixterm() { printf '\033[r\033[?7h\033[?25h\033[0m'; clear }

# The three things lazygit still does better, as pickers.

# Hunk-level staging. Pick the file, then git add -p drives the hunks
# (git-stage-hunks, which ga's p uses too). Needed whenever one file's changes
# belong to two different commits in a stack.
gah() {
  _g_repo || return 1
  if [[ -z $(git status --porcelain) ]]; then
    print "nothing to stage"
    return
  fi
  local sel top=$(git rev-parse --show-toplevel)
  sel=$(cd "$top" && git-fzf 'hunks in ' 't=tests/config/generated,enter=pick hunks' --ansi \
      --delimiter=$'\t' --with-nth=1 \
      --bind 'start:reload(git-file-list)' \
      --bind 't:execute-silent(git-test-files toggle)+reload(git-file-list --cached)' \
      --preview 'git-preview-file {3} {2} {4}' </dev/null) || return
  [[ -z $sel ]] && return
  local -a f=("${(@ps:\t:)sel}")
  git-stage-hunks "$f[3]" "$f[2]"
  git status --short
}

# Interactive rebase starting just below the commit you pick, so that commit is
# the first one you can reword, edit, squash or drop. --update-refs keeps the
# branches stacked above it pointing at the right commits.
grb() {
  _g_repo || return 1
  local sha args
  (( $# )) && args="${(q)@}"
  sha=$(git-fzf 'rebase from ' 'enter=edit this and later' --ansi --no-sort \
      --delimiter=$'\t' --with-nth=1 --id-nth=2 \
      --bind "start:reload(git-log-list $args)" \
      --preview 'git-preview-commit {2}' </dev/null | cut -f2) || return
  [[ -z $sha ]] && return
  if git rev-parse -q --verify "$sha~1" >/dev/null 2>&1; then
    git rebase -i --autosquash --update-refs "$sha~1"
  else
    git rebase -i --autosquash --update-refs --root
  fi
}

# The reflog as an undo list: every state HEAD has been in, newest first.
# This is what gets you back after a rebase or reset went wrong. The age is
# when HEAD moved there, which %gd names under --date ("HEAD@{2 minutes ago}");
# %ar would be the commit's own date, months back for a reset onto main.
gundo() {
  _g_repo || return 1
  local sel sha
  sel=$(git reflog --date=relative --format='%h%x09%gd%x09%gs%x09%gd' -60 |
    awk -F'\t' -v OFS='\t' '{ sub(/^[^{]*[{]/, "", $4); sub(/[}]$/, "", $4); print }' |
    git-fzf 'undo to ' 'enter=restore this state' --ansi \
      --delimiter=$'\t' --with-nth='1,3,4' \
      --preview 'git-preview-commit {1}; echo; echo "--- history from there ---"; git log --oneline --color=always -8 {1}') || return
  [[ -z $sel ]] && return
  sha=$(print -r -- "$sel" | cut -f1)

  print "restore the tree and HEAD to:"
  git log -1 --format='  %h %s' "$sha"
  print "  ($(print -r -- "$sel" | cut -f3))"
  print -n "this discards uncommitted changes. proceed? [y/N] "
  if ! read -q; then print; print "aborted"; return 1; fi
  print
  git reset --hard "$sha" && git log --oneline -3
}

# Everything Claude is doing, or has done, in this repo in the background, in
# one list (git-agent-list): its reviews, fix runs, production watches and
# verifications, running ones first, each with its state, what it is about,
# when, and its last word. The preview is the run's own account of itself
# and its verdict where it has one (git-agent-preview); enter is every step
# (git-claude-view, whose x stops a run), d forgets a finished run. The
# results themselves stay where they are used: drafts and fixes in gmr and
# gb. Every 5s it reloads if a run has moved on (git-fzf-bg), keeping the
# cursor and where the preview is scrolled to.
# The dashboard, and the one command named after the tool: everything that
# wants you, then what is running, then where you are (otis-list). One row a
# thing and never one a fact, so a merge request with a failed pipeline and
# three threads on it is one row, the pipeline, because that is what you would
# do about it next. enter does exactly what the row says, whatever that is:
# opens an MR for review, the proposals of a fix run, the jobs of a failed
# pipeline, the stage panel for what is uncommitted here (otis-do).
#
# m, b, a, d and w open the full list behind a section (gmr, gb, gag, gd, gw),
# c otis's own settings (otis-config), and q there comes back here, so the
# dashboard is a hub rather than a detour;
# q here goes back to the shell. A picker that moved you, though, hands you to
# the shell instead: gb switching a branch and gw going to a worktree both say
# what they did, and redrawing over that would be the dashboard eating it.
#
# It redraws every 10s, not every 2 like gag: a draw costs about what gmr's
# does, since it asks the same four scripts what Claude has left you, and a
# dashboard left open all day should not spend a tenth of a core on ticking a
# duration over. u draws now.
otis() {
  _g_repo || return 1
  local out at on
  while :; do
    out=$(git-fzf 'otis ' 'enter=do what it says,m=every MR,b=branches,d=deploys,a=background runs,w=worktrees,c=otis settings,D=discard it,o=open MR,y=copy MR link (a run: its folder for Claude),u=refresh' --ansi --no-sort \
      --delimiter=$'\t' --with-nth=1 --track --id-nth=11 \
      --bind 'start:reload(otis-list | tee "$GIT_FZF_STATE/bg.shown")' \
      --bind 'every(10):execute-silent(git-fzf-bg --tick otis-list)' \
      --bind 'u:execute-silent(git-fzf-bg otis-list --refresh)' \
      --bind 'enter:transform(otis-do enter {6} {14} {13} {2} {3} {4} {5} {7} {8} {9} {12})' \
      --bind 'D:transform(otis-do dismiss {6} {14} {13} {2} {3} {4} {5} {7} {8} {9} {12})' \
      --bind 'o:transform(git-mr-do web {2})' \
      --bind 'y:transform(otis-do copy {6} {14} {13} {2} {3} {4} {5} {7} {8} {9} {12})' \
      --bind 'm:print(gmr)+accept' \
      --bind 'b:print(gb)+accept' \
      --bind 'a:print(gag)+accept' \
      --bind 'd:print(gd)+accept' \
      --bind 'w:print(gw)+accept' \
      --bind 'c:print(otis-config)+accept' \
      --preview 'otis-preview {6} {2} {11} {13}' </dev/null) || return 0
    at=$PWD on=$(git branch --show-current 2>/dev/null)
    case ${${(f)out}[1]} in
      gmr) gmr ;;
      gb)  gb ;;
      gag) gag ;;
      gd)  gd ;;
      gw)  gw ;;
      otis-config) otis-config ;;
      *)   return 0 ;;
    esac
    [[ $PWD == $at && $(git branch --show-current 2>/dev/null) == $on ]] || return 0
  done
}

gag() {
  _g_repo || return 1
  git-fzf 'agents ' 'enter=every step (a fix run: its proposals),y=copy its folder for Claude,d=forget a finished run,u=refresh' --ansi --no-sort \
    --delimiter=$'\t' --with-nth=1 --track --id-nth=5 \
    --bind 'start:reload(git-agent-list | tee "$GIT_FZF_STATE/bg.shown")' \
    --bind 'every(2):execute-silent(git-fzf-bg --tick git-agent-list)' \
    --bind 'u:execute-silent(git-fzf-bg git-agent-list)' \
    --bind 'enter:transform(git-agent-list --open {2})' \
    --bind 'd:execute(git-agent-list --forget {2})+reload(git-agent-list)' \
    --bind 'y:transform(otis-do copy run run {2})' \
    --preview 'git-agent-preview {2}' </dev/null >/dev/null
}

# Production deploys, newest first (git-deploy-list): each with what it carried,
# the ones carrying your MRs marked, and the last 40 as a strip of glyphs in
# the footer, oldest left, so a bad afternoon reads as a run of ✗. The
# preview is the deploy: the merge requests and commits it took out, and for
# a failed one the end of its log (git-deploy-preview). enter is its
# pipeline's jobs and logs, w opens the job, p the pipeline, y copies the
# sha, u refetches. gd <pipeline id> opens on that pipeline's deploy, which is
# what enter on a merged MR in gmr does. Reloads every 30s.
gd() {
  _g_repo || return 1
  local -a at
  [[ -n $1 ]] && at=(--bind "result:transform(git-deploy-list --pos ${(q)1})+unbind(result)")
  git-fzf 'deploys ' 'enter=jobs and logs,w=open the job,p=pipeline in browser,y=copy sha,u=refresh' --ansi --no-sort \
    --delimiter=$'\t' --with-nth=1 --track --id-nth=2 \
    --bind 'start:reload(git-deploy-list | tee "$GIT_FZF_STATE/bg.shown")' \
    --bind 'every(30):execute-silent(git-fzf-bg --tick git-deploy-list)' \
    --bind 'u:execute-silent(git-fzf-bg git-deploy-list --refresh)' \
    --bind 'enter:execute(git-ci-jobs {4} "")' \
    --bind 'w:execute-silent(otis-open {5})' \
    --bind "p:execute-silent(otis-open \"$(otis-config url)/$(otis-config project)/-/pipelines/\"{4})" \
    --bind 'y:execute-silent(printf %s {3} | otis-copy)+transform(git-fzf-note copied {3})' \
    "${at[@]}" \
    --preview 'git-deploy-preview {2}' </dev/null >/dev/null
}

# Every merge request in one picker (git-mr-list): MRs to review, yours with
# their pipelines, and yours merged this week with whether each is live (f:
# every open MR instead). gci is the same picker with yours first.
#
# enter does the obvious thing for the row: review an MR (a shared review
# worktree moves to it, git-mr-review), address the comments on one of yours
# (in its branch's checkout, git-mr-mine), or show a merged one's deploy jobs.
# Either of the first two is a file picker over the whole diff with threads
# inline; q in there comes back here, and q again returns you where you were.
# c is CI jobs and logs, R retries failed jobs, m merges once GitLab says it
# is ready, r has GitLab rebase it onto its target (git-mr-rebase), A approves, l and a manage labels and reviewers, s switches to the
# branch (bringing it here from a worktree), W opens it in a worktree of its own, w and y open
# and copy the MR, p opens its pipeline and v is glab's stage graph. C has
# Claude draft comments on an MR to review, or propose fixes on one of yours,
# as C in the file picker does (git-mr-do claude); D, on a merged one, has
# Claude watch production for it (git-mr-watch); V verifies one in Cursor
# Cloud. The list reloads every 30s, keeping the cursor.
_gmr() {
  _g_repo || return 1
  local out
  out=$(GMR_FIRST=$1 git-fzf 'MRs ' 'enter=review / address comments / its deploy,c=CI jobs and logs,m=merge,r=rebase onto target,A=approve,d=draft / ready (yours),l=labels,a=reviewers,s=switch to branch,W=branch in its own worktree,C=Claude reviews / proposes fixes,D=Claude watches production (merged),V=verify in Cursor Cloud,R=retry failed,N=new pipeline,w=open MR,y=copy MR link,p=pipeline in browser,v=stage graph,f=all MRs or yours,u=refresh' --ansi \
    --delimiter=$'\t' --with-nth=1 --track --id-nth=11 \
    --bind 'start:reload(git-mr-list | tee "$GIT_FZF_STATE/bg.shown")' \
    --bind 'every(30):execute-silent(git-fzf-bg --tick git-mr-list)' \
    --bind 'f:execute-silent(git-fzf-bg git-mr-list toggle)' \
    --bind 'u:execute-silent(git-fzf-bg git-mr-list --refresh)' \
    --bind 'enter:transform(git-mr-do open {6} {2} {3} {4} {5} {7} {8} {9} {12})' \
    --bind 'C:transform(git-mr-do claude {6} {2} {3} {4} {5} {7} {8} {9} {12})' \
    --bind 'c:transform(git-ci-do jobs {9} {2})' \
    --bind 'R:transform(git-ci-do retry {9} {2})' \
    --bind 'N:transform(git-ci-do new {9} {2})' \
    --bind 'm:transform(git-ci-merge --check {2})' \
    --bind 'r:transform(git-mr-rebase --check {6} {2})' \
    --bind 'A:transform(git-mr-do approve {6} {2} {7} {8})' \
    --bind 'd:transform(git-mr-do draft {6} {2})' \
    --bind 'l:transform[git-mr-do labels {2} "execute-silent(git-fzf-bg git-mr-list --refresh)"]' \
    --bind 'a:transform[git-mr-do reviewers {2} "execute-silent(git-fzf-bg git-mr-list --refresh)"]' \
    --bind 's:print(switch)+accept' \
    --bind 'W:print(worktree)+accept' \
    --bind 'w:transform(git-mr-do web {2})' \
    --bind 'y:transform(git-mr-do copy {2})' \
    --bind 'p:transform(git-ci-do pipeline {9} {2} {10})' \
    --bind 'v:execute(glab ci view -b {5})' \
    --bind 'D:transform(git-mr-watch --check {6} {2})' \
    --bind 'V:transform(git-verify --check {6} {2})' \
    --preview 'git-mr-preview {2} {6} {11}' </dev/null)
  # s and W print "switch" or "worktree" and the MR's row; anything else leaves out empty.
  local -a lines=("${(@f)out}")
  [[ $lines[1] == (switch|worktree) ]] || return 0
  local -a f=("${(@ps:\t:)lines[2]}")
  _g_goto_branch "$f[5]" ${lines[1]:#switch}
}
gmr() { _gmr review }
gci() { _gmr mine }

# This branch's commits as a glab stack, one branch and MR a commit, then
# synced (git-stack). r in gmr rebases a glab stack onto origin/main.
gstack() {
  _g_repo || return 1
  git-stack "$@"
}

# Bring this branch up to date with main: fetch origin/main and replay the
# branch's commits on top. --update-refs carries any stacked branches along.
# A dirty tree is refused rather than auto-stashed, since the stash list is
# shared by every worktree and session in this repo; gwip sets work aside.
gup() {
  _g_repo || return 1
  local b=$(git branch --show-current) main=$(otis-config main)
  [[ -z $b ]] && { print -u2 "gup: not on a branch (detached HEAD)"; return 1 }
  [[ $b == $main ]] && { print -u2 "gup: you are on $main; use git pull --ff-only"; return 1 }
  if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    print -u2 "gup: uncommitted changes. commit them, or set them aside with gwip (gunwip after)"
    return 1
  fi
  git remote get-url origin >/dev/null 2>&1 || { print -u2 "gup: no origin remote to rebase onto"; return 1 }
  git fetch --quiet origin $main || { print -u2 "gup: could not fetch origin/$main"; return 1 }
  local behind=$(git rev-list --count HEAD..origin/$main)
  if (( behind == 0 )); then
    print "$b already has everything on origin/$main"
    return
  fi
  # Note where everything the rebase will move points now, for a one-paste undo.
  # --update-refs moves the local branches on commits being replayed, except any
  # checked out in another worktree; gundo alone would only reset this one.
  local replayed=$'\n'"$(git rev-list origin/$main..HEAD)"$'\n' line ref sha
  local undo="git reset --hard $(git rev-parse --short=10 HEAD)"
  for line in ${(f)"$(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads)"}; do
    ref=${line% *} sha=${line#* }
    [[ $ref == $b || $replayed != *$'\n'$sha$'\n'* ]] && continue
    git worktree list --porcelain | grep -qxF "branch refs/heads/$ref" && continue
    undo+=" && git branch -f $ref ${sha:0:10}"
  done

  print "rebasing $b onto origin/$main, $behind new commit${${behind:#1}:+s} on $main"
  if git rebase --quiet --update-refs origin/$main; then
    local mine=$(git rev-list --count origin/$main..HEAD)
    print "done. your $mine commit${${mine:#1}:+s} now sit on top; push with gp"
    print "to undo: $undo"
  else
    print -u2 ""
    print -u2 "conflict. fix the files, git add them, then: git rebase --continue"
    print -u2 "to put everything back as it was: git rebase --abort"
    return 1
  fi
}

# A branch's first push ends by offering to create its MR (y/N): into the
# branch below it when it sits on a stack, else main, titled and described
# from its commits the way glab mr create --fill does, with the project's
# squash and delete-branch defaults, as GitLab's form would. N, or GitHub,
# prints the link to open one instead; the server prints one too, but the
# pre-push hook's lint output buries it. "First" means origin has no copy of
# the branch yet; upstream tracking says nothing here, since new branches
# track origin/main.
#
# The lease alone checks origin against origin/<branch>, which the background
# fetch keeps fresh, so after an amend it would match a push someone else just
# made and overwrite it. --force-if-includes also wants that commit somewhere
# in this branch's own history.
gp() {
  _g_repo || return 1
  local b=$(git branch --show-current) new=0
  [[ -n $b ]] && ! git show-ref --verify --quiet "refs/remotes/origin/$b" && new=1
  git push origin HEAD --force-with-lease --force-if-includes "$@" || return
  (( new )) && _g_offer_mr "$b"
}

# The branch an MR from $1 goes into: the nearest branch below it on a stack
# (in its history but not yet in origin/main, the one furthest past it, as
# stack-push counts), else main.
_g_mr_target() {
  local base=$(otis-config base) main=$(otis-config main) b most=0 n tip=$(git rev-parse "$1")
  local best=$main
  for b in ${(f)"$(git for-each-ref --format='%(refname:short)' --merged "$1" --no-merged $base refs/heads)"}; do
    [[ $b == $main || $b == $1 || $(git rev-parse "$b") == $tip ]] && continue
    n=$(git rev-list --count $base..$b)
    (( n > most )) && { most=$n; best=$b }
  done
  print -r -- $best
}

# What an MR from $1 would be: into the branch below it on a stack, else
# main (_g_mr_target), titled and described from its commits the way glab mr
# create --fill does. Sets mr_target, mr_title and mr_desc, or fails with
# mr_why when the target is not on origin.
_g_mr_draft() {
  local b=$1
  typeset -g mr_target=$(_g_mr_target "$b") mr_title= mr_desc= mr_why=
  if ! git show-ref --verify --quiet "refs/remotes/origin/$mr_target"; then
    mr_why="$b sits on $mr_target, which is not on origin yet, so no MR for it; stack-push pushes both"
    return 1
  fi
  local -a subjects=(${(f)"$(git log --reverse --format=%s "origin/$mr_target..$b")"})
  if (( $#subjects == 1 )); then
    mr_title=$subjects[1]
    mr_desc=$(git log -1 --format=%b "$b")
  else
    mr_title=${${b#*/}//-/ }
    mr_title=${(U)mr_title[1]}${mr_title[2,-1]}
    mr_desc=$(printf -- '- %s\n' $subjects)
  fi
}

# The drafted MR (_g_mr_draft) from $1, made, with the project's squash and
# delete-branch defaults as GitLab's form would: prints the new MR's JSON.
_g_mr_create() {
  local project
  project=$(glab api projects/:fullpath) || return
  glab api -X POST projects/:fullpath/merge_requests -H 'Content-Type: application/json' --input - <<<"$(
    jq -n --arg s "$1" --arg t "$mr_target" --arg title "$mr_title" --arg d "$mr_desc" --argjson p "$project" \
      '{source_branch: $s, target_branch: $t, title: $title, description: $d,
        remove_source_branch: $p.remove_source_branch_after_merge,
        squash: ($p.squash_option | IN("default_on", "always"))}')"
}

_g_offer_mr() {
  local b=$1 out
  otis-config gitlab || { _g_review_link "$b"; return }
  _g_mr_draft "$b" || { print -u2 "gp: $mr_why"; return }
  print
  git-confirm "create an MR from $b into $mr_target: \"$mr_title\"?" || { _g_review_link "$b"; return }
  out=$(_g_mr_create "$b" 2>&1) || { print -u2 "gp: could not create the MR: $out"; _g_review_link "$b"; return 1 }
  local c=$'\e['$OTIS_T_ATTENTION'm' r=$'\e[0m'
  print -r -- "${c}!$(jq -r .iid <<<"$out") created:${r} $(jq -r .web_url <<<"$out")"
}

# gb's n (git-mr-new): an MR for a branch that has none, asked first. check
# is the transform: what cannot be done says why in the footer, else the
# rest runs in the terminal (ask), and what it did is the footer after
# (said). A branch on others of yours brings the ones below it with no MR
# along, all asked at once. A branch off main of several commits, none of
# them a merge, can go up as a glab stack instead, one MR a commit (gstack),
# from the checkout it is in.
_g_mr_new() {
  local how=$1 b=$2 iid=$3 said=$GIT_FZF_STATE/mr-new.said
  case $how in
    check)
      [[ -n $iid ]] && { git-fzf-note "$b already has !$iid; w opens it"; return }
      otis-config gitlab || { git-fzf-note "origin is not on GitLab"; return }
      local stack=$(git-stack --of "$b" 2>/dev/null)
      [[ -n $stack ]] && { git-fzf-note "$b is a layer of the stack $stack; gstack on it opens the stack's MRs"; return }
      print -r -- "execute(git-mr-new --ask ${(q)b})+transform(git-mr-new --said)+execute-silent(git-fzf-bg git-branch-list --switch --refresh)"
      ;;
    said)
      [[ -s $said ]] && { git-fzf-note "$(<$said)"; rm -f $said }
      ;;
    ask)
      rm -f $said
      local base=$(otis-config base) out wt
      local -i n=$(git rev-list --count "$base..$b" 2>/dev/null)
      (( n )) || { print -r -- "$b has nothing past $base" > $said; return }
      # The stack is offered only where gstack can make it: off main (glab
      # infers main..HEAD, so a branch on another of yours would take that
      # one's commits as layers too; it goes into it instead, one MR), and
      # from a checkout of it, since infer reads HEAD. Without one it says
      # so and offers the one MR.
      if (( n > 1 )) && [[ $(_g_mr_target "$b") == $(otis-config main) && -z $(git rev-list --merges "$base..$b") ]]; then
        print "$b has $n commits:"
        git log --reverse --format='  %h %s' "$base..$b"
        print
        wt=$(git-worktree-path of "$b")
        if [[ -z $wt ]]; then
          print -r -- "not checked out anywhere, so no stack from here (enter switches to it, then gstack); one MR for all of them instead:"
        elif git-confirm "make them a stack, one MR a commit (gstack)?"; then
          (cd "$wt" && git-stack) && print -r -- "$b is a stack now; gmr has its MRs" > $said
          return
        fi
        print
      fi
      # A branch on others of yours goes into the one below it, and that
      # one is no use without an MR of its own: every branch down the chain
      # with no open MR comes too, asked once, made bottom first so each
      # has its target's MR there. The walk stops at main or at a branch
      # that has an MR.
      local main=$(otis-config main) x=$b t
      local -a chain=($b) made
      while t=$(_g_mr_target "$x"); [[ $t != $main ]] &&
        [[ $(glab api "projects/:fullpath/merge_requests?state=opened&source_branch=${t//\//%2F}" 2>/dev/null | jq length) == 0 ]]; do
        chain=($t $chain) x=$t
      done
      for x in $chain; do
        git show-ref --verify --quiet "refs/remotes/origin/$x" && continue
        print -r -- "$x is not pushed yet; ${${chain:#$b}:+stack-push pushes the chain, }gp pushes it and offers the MR" > $said
        return
      done
      for x in $chain; do
        _g_mr_draft "$x" || { print -r -- "$mr_why" > $said; return }
        print -r -- "$x into $mr_target: \"$mr_title\""
      done
      local ask="create the MR?"
      (( $#chain > 1 )) && ask="create these $#chain MRs, bottom first?"
      git-confirm "$ask" || return
      for x in $chain; do
        _g_mr_draft "$x"
        out=$(_g_mr_create "$x" 2>&1) || {
          print -r -- "${made:+${(j:, :)made} created; }could not create the MR for $x: ${${(f)out}[1]}" > $said
          return
        }
        made+=("!$(jq -r .iid <<<"$out") into $mr_target")
      done
      print -r -- "created ${(j:, :)made}" > $said
      ;;
  esac
}

_g_review_link() {
  local url=$(git remote get-url origin) host repo
  case $url in
    *://*) repo=${url#*://}; repo=${repo#*@}; host=${${repo%%/*}%%:*}; repo=${repo#*/} ;;
    *@*:*) repo=${url#*@}; host=${repo%%:*}; repo=${repo#*:} ;;
    *) return ;;
  esac
  repo=${repo%.git}
  local c=$'\e['$OTIS_T_ATTENTION'm' r=$'\e[0m'
  case $host in
    gitlab.com) print -r -- $'\n'"${c}open an MR:${r} https://gitlab.com/$repo/-/merge_requests/new?merge_request%5Bsource_branch%5D=${1//\//%2F}" ;;
    github.com) print -r -- $'\n'"${c}open a PR:${r} https://github.com/$repo/pull/new/$1" ;;
  esac
}
gbn() {
  if [[ -z $1 ]]; then
    print -u2 "usage: gbn <name>   new branch <prefix>/<name> off the current HEAD ($(git branch --show-current 2>/dev/null)); spaces become dashes"
    print -u2 "  e.g. gbn billing-dupes     for a fresh branch off origin/main in its own worktree, use gwn"
    return 2
  fi
  local b
  b=$(_gbranch gbn "$*") || return
  git switch -c "$b"
}
