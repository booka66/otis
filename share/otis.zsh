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

# ---------------------------------------------------------- git, picker-driven
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
# d deletes the marked branches, or the one under the cursor, and S marks the
# ones that lose nothing (git-branch-delete); one checked out anywhere stays.
# p force-pushes the branch with gp, asked first (git-branch-push).
gb() {
  _g_repo || return 1
  local sel
  sel=$(git-fzf 'branch ' 'enter=switch to it,c=its commits,C=propose fixes,V=verify in Cursor Cloud (pushes it first if origin is behind),p=force-push it with gp (asks first),W=open in its own worktree,space=mark,d=delete,S=mark safe to delete,n=open an MR for it or a stack (asks first),w=open it in the browser,y=copy its link,t=tests,l=labels,a=reviewers,u=refresh' --multi --ansi --track \
      --delimiter=$'\t' --with-nth=1 --id-nth=2 --keys-from 'otis-keys branch {2} {3} {4} {5} {6}' \
      --bind 'start:reload(git-branch-list --switch | tee "$GIT_FZF_STATE/bg.shown")' \
      --bind 'u:execute-silent(git-fzf-bg git-branch-list --switch --refresh)' \
      --bind 'W:print(worktree)+accept' \
      --bind 'space:toggle' \
      --bind 'S:transform(git-branch-list --safe)' \
      --bind 'result:unbind(result)+transform(git-branch-list --safe-after)' \
      --bind 'd:execute(git-branch-delete {+2})+clear-multi+execute-silent(git-fzf-bg git-branch-list --switch --refresh)' \
      --bind 'c:execute(git-branch-log {2})' \
      --bind 'C:execute(git-branch-fix {2} {5})' \
      --bind 'V:execute(git-verify --branch {2} {5})+refresh-preview' \
      --bind 'p:execute(git-branch-push {2})+execute-silent(git-fzf-bg git-branch-list --switch --refresh)' \
      --bind 't:execute-silent(git-test-files toggle; git-test-files state > "$GIT_FZF_STATE/footer")+refresh-preview' \
      --bind 'n:transform(git-mr-new --check {2} {5})' \
      --bind 'w:transform(git-mr-do web {5})' \
      --bind 'y:transform([ -n {5} ] && exec git-mr-do copy {5}; printf %s {2} | otis-copy; git-fzf-note copied {2})' \
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
# removed if it was made for the branch (W, B in the proposals), and the
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
    [[ -e $wt ]] && { print -u2 "${wt/#$HOME/~} already exists; the board lists it under worktrees"; return 1 }
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
    print -u2 "to leave this checkout as it is, open $b in a worktree of its own: W in gb"
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

# The log, newest first; bare gl shows the newest 500 and says so in the
# footer (git-log-list). f folds what is staged into the commit under the
# cursor, as gfx does, and r rewords it; either only takes this branch's own
# commits (git-log-do), and the list reloads with the rewritten ones. It
# reloads at a new width too, where a row has room for its author or not.
gl() {
  _g_repo || return 1
  # Not "${(q)@}": with no positional args that expands to a literal '', and
  # `git log ''` is a fatal error, which empties the list on reload.
  local args
  (( $# )) && args="${(q)@}"
  git-fzf 'log ' 'enter=read it by symbol,o=its files,t=tests,y=copy sha,f=fold staged in,r=reword' --ansi --no-sort \
      --delimiter=$'\t' --with-nth=1 --nth=1,3 --id-nth=2 \
      --bind "start:reload(git-log-list $args)" \
      --bind "resize:reload(git-log-list $args)" \
      --preview 'git-preview-commit --tests-toggle {2}' \
      --bind 't:execute-silent(git-test-files toggle)+refresh-preview' \
      --preview-window '<66(down,75%,border-top,wrap)' \
      --bind 'enter:execute(git-symbols {2})' \
      --bind 'o:execute(git-commit-open {2})' \
      --bind "f:transform[git-log-do fixup {2} \"reload(git-log-list $args)\"]" \
      --bind "r:transform[git-log-do reword {2} \"reload(git-log-list $args)\"]" \
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
# the cursor and the list redraws in place, p picks hunks of it, c commits
# what is staged (gcm's way) without leaving, d discards a path (asking
# first) and P parks it in a stash instead, which gst brings back. Unstaging everything
# is U, not u: u refreshes in every other picker, and the muscle memory used to
# land here and throw away a careful round of hunk staging with no way back. git-stage-toggle
# and git-file-list live in bin/ because a picker's bindings run in zsh -f and
# cannot see functions. The panel runs from the repo root, where git status's
# paths start, so its keys act on the right file from any subdirectory.
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
  _picked=$(cd "$top" && git-fzf 'files ' 'enter=open in editor,s=by symbol,space=stage it,p=stage hunks,c=commit,d=discard it,P=park it in a stash (untracked too),a=stage all,U=unstage all,y=copy path,u=refresh,t=tests/config/generated,x=clear lock' --ansi \
      --delimiter=$'\t' --with-nth=1 --track --id-nth=6 --keys-from 'otis-keys file {2} {3}' \
      --bind 'enter:execute(git-file-open {3} {2} {4})+reload(git-file-list)' \
      --bind 'start:reload(git-file-list)' \
      --bind 't:execute-silent(git-test-files toggle)+reload(git-file-list --cached)' \
      --bind 'space:reload(git-stage-toggle {3} {2} {4})' \
      --bind "s:$_s" \
      --bind 'p:execute(git-stage-hunks {3} {2})+reload(git-file-list -- {2} {4})' \
      --bind 'c:transform:git diff --cached --quiet && git-fzf-note "nothing staged to commit" || echo "execute(git-commit-edit || { echo press enter; read -r _; })+reload(git-file-list)"' \
      --bind 'x:reload(git-clear-lock)' \
      --bind 'd:execute(git-discard-path {3} {2} {4})+reload(git-file-list -- {2} {4})' \
      --bind 'P:execute-silent(set -- {2} {4}; [ -n "$2" ] || set -- "$1"; git stash push -q -u -m "park-$(date +%Y%m%d-%H%M%S)" -- "$@")+reload(git-file-list)+transform(git-fzf-note parked {2}: gst brings it back)' \
      --bind 'a:reload(git add -A >/dev/null; git-file-list)' \
      --bind 'U:reload(git reset -q >/dev/null; git-file-list)' \
      --bind 'y:execute-silent(printf %s {2} | otis-copy)+transform(git-fzf-note copied {2})' \
      --bind 'u:reload(git-file-list)' \
      --preview 'git-preview-file {3} {2} {4}' </dev/null)
  git status --short
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
    print "done. the branches above want pushing too: p on each in gb"
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
    print -u2 "gam: unstaged changes, and restacking the branches above needs a clean tree; stage them first"
    return 1
  fi
  print -r -- $top
}

# Setting work aside, untracked files too, under refs/otis/wip/<branch>: off
# the branch, so no push sends it (gp, lazygit, any), and out of the stash
# list, which every worktree and session shares. gunwip brings it back onto
# wherever the branch is by then, as a stash would.
gwip() {
  _g_repo || return 1
  local b=$(git branch --show-current) c n
  [[ -n $b ]] || { print -u2 "gwip: not on a branch (detached HEAD); commit, or park files with ga's P (gst brings them back)"; return 1 }
  git rev-parse -q --verify refs/otis/wip/$b >/dev/null && { print -u2 "gwip: $b has work set aside already; gunwip, then gwip again"; return 1 }
  git add -A && c=$(git stash create) || return
  [[ -n $c ]] || { print -u2 "gwip: nothing to set aside"; return 1 }
  n=$(git diff --name-only HEAD $c | wc -l | tr -d ' ')
  git update-ref refs/otis/wip/$b $c && git reset -q --hard &&
    print -r -- "set aside $n file${${n:#1}:+s}; gunwip on $b brings it back"
}

gunwip() {
  _g_repo || return 1
  local b=$(git branch --show-current)
  local ref=refs/otis/wip/$b
  # A wip commit on top is how gwip set work aside before it kept a ref.
  if [[ -z $b ]] || ! git rev-parse -q --verify $ref >/dev/null; then
    if [[ $(git log -1 --format=%s) != wip:* ]]; then
      # A branch renamed or deleted since leaves its work under its old name.
      local -a on=(${(f)"$(git for-each-ref --format='%(refname:lstrip=3)' refs/otis/wip)"})
      print -u2 "gunwip: nothing set aside on ${b:-this detached HEAD}${on:+ (there is on ${(j:, :)on})}"
      return 1
    fi
    git reset --soft HEAD~1 && git status --short
    return
  fi
  local c=$(git rev-parse --short $ref) clash=
  # Conflicts mean it is back, markers and all, so the ref goes either way.
  git stash apply -q $ref || { clash=$(git diff --name-only --diff-filter=U); [[ -n $clash ]] || return 1 }
  git update-ref -d $ref && git status --short
  [[ -z $clash ]] || { print -u2 "gunwip: it came back with conflicts to fix (it was $c)"; return 1 }
}

# The terminal as it should be after a full-screen program that died in it:
# its modes (stty sane: echo, line editing, a newline that returns), and the
# screen's (scroll region, wrap, cursor, mouse reporting, the main screen).
# clear does not reset the scroll region; a TUI that exits badly leaves it set
# and later output scrolls out of view.
fixterm() { stty sane; printf '\033[r\033[?7h\033[?25h\033[0m\033[?1000l\033[?1002l\033[?1006l\033[?2004l\033[?1049l'; clear }

# The board, and the one command named after the tool: every change a row
# that says the one move it needs next, then what is moving without you and
# where you are, and everything else there is in groups under them
# (otis-list, otis-board), drawn by otis-dash. One row a change and never one
# a fact, so a merge request with a failed pipeline and three threads on it
# is one row, the pipeline, because that is what you would do about it next.
# enter does exactly what the row says, whatever that is: opens an MR for
# review, the proposals of a fix run, the jobs of a failed pipeline, the
# stage panel for what is uncommitted here (otis-do).
#
# gb (branches) and gc (otis's settings) are lists of their own, which
# otis-dash hands back to be opened here, since gb may move you, which
# otis-dash cannot; q there comes back to the board. q here goes back to the
# shell. A list that moved you, though, hands you to the shell instead: gb
# switching a branch says what it did, and redrawing over that would be the
# board eating it. Going to a branch or a worktree from a row is done here
# too, for the same reason.
otis() {
  _g_repo || return 1
  local out at on
  # The screens hand the alternate screen to each other (share/screen.zsh),
  # so going from one to the next never shows the terminal between; left
  # up by the last, it is left here.
  export OTIS_ALT=${TMPDIR:-/tmp}/otis-alt.$$
  {
    while :; do
      out=$(otis-dash) || return 0
      at=$PWD on=$(git branch --show-current 2>/dev/null)
      case $out in
        # Each named for the key log, which would file its keys under otis.
        gb)  OTIS_SCREEN=gb gb ;;
        otis-config) OTIS_SCREEN=otis-config otis-config ;;
        # s on a change, or enter on a worktree: only a shell can go
        # there, and it is where the board was leaving you.
        goto$'\t'*) _g_goto_branch "${out#*$'\t'}"; return ;;
        cd$'\t'*) _g_cd "${out#*$'\t'}"; return ;;
        *)   return 0 ;;
      esac
      [[ $PWD == $at && $(git branch --show-current 2>/dev/null) == $on ]] || return 0
    done
  } always {
    [[ -e $OTIS_ALT ]] && { rm -f -- $OTIS_ALT; print -n $'\e[?25h\e[?1049l' > /dev/tty; }
    unset OTIS_ALT
  }
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
  # checked out in another worktree; a reset alone would only put this one back.
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
  (( ! new )) || _g_offer_mr "$b"
}

# The branch an MR from $1 goes into: the nearest branch below it on a stack
# (in its history but not yet in origin/main, the one furthest past it),
# else main.
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
    mr_why="$b sits on $mr_target, which is not on origin yet, so no MR for it; p on $mr_target in gb pushes it"
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
  project=$(git-forge api projects/:fullpath) || return
  git-forge api -X POST projects/:fullpath/merge_requests -H 'Content-Type: application/json' --input - <<<"$(
    jq -n --arg s "$1" --arg t "$mr_target" --arg title "$mr_title" --arg d "$mr_desc" --argjson p "$project" \
      '{source_branch: $s, target_branch: $t, title: $title, description: $d,
        remove_source_branch: $p.remove_source_branch_after_merge,
        squash: ($p.squash_option | IN("default_on", "always"))}')"
}

_g_offer_mr() {
  local b=$1 out
  { otis-config gitlab || [[ $(otis-config forge) == github ]] } || { _g_review_link "$b"; return }
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
# them a merge, can go up as a glab stack instead, one MR a commit
# (git-stack), from the checkout it is in; a layer of one with no MR yet
# (its first push failed, say) has its stack synced, which opens them.
_g_mr_new() {
  local how=$1 b=$2 iid=$3 said=$GIT_FZF_STATE/mr-new.said
  case $how in
    check)
      [[ -n $iid ]] && { git-fzf-note "$b already has !$iid; w opens it"; return }
      { otis-config gitlab || [[ $(otis-config forge) == github ]] } || { git-fzf-note "origin is on neither GitLab nor GitHub"; return }
      print -r -- "execute(git-mr-new --ask ${(q)b})+transform(git-mr-new --said)+execute-silent(git-fzf-bg git-branch-list --switch --refresh)"
      ;;
    said)
      [[ -s $said ]] && { git-fzf-note "$(<$said)"; rm -f $said }
      ;;
    ask)
      rm -f $said
      local base=$(otis-config base) out wt stack=$(git-stack --of "$b" 2>/dev/null)
      if [[ -n $stack ]]; then
        git-stack --sync "$stack" && print -r -- "the stack $stack is synced; the board has its MRs" > $said
        return
      fi
      local -i n=$(git rev-list --count "$base..$b" 2>/dev/null)
      (( n )) || { print -r -- "$b has nothing past $base" > $said; return }
      # The stack is offered only where git-stack can make it: off main (glab
      # infers main..HEAD, so a branch on another of yours would take that
      # one's commits as layers too; it goes into it instead, one MR), and
      # from a checkout of it, since infer reads HEAD. Without one it says
      # so and offers the one MR.
      if (( n > 1 )) && git-forge can stack && [[ $(_g_mr_target "$b") == $(otis-config main) && -z $(git rev-list --merges "$base..$b") ]]; then
        print "$b has $n commits:"
        git log --reverse --format='  %h %s' "$base..$b"
        print
        wt=$(git-worktree-path of "$b")
        if [[ -z $wt ]]; then
          print -r -- "not checked out anywhere, so no stack from here (enter switches to it, then n again); one MR for all of them instead:"
        elif git-confirm "make them a stack, one MR a commit?"; then
          (cd "$wt" && git-stack) && print -r -- "$b is a stack now; the board has its MRs" > $said
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
        [[ $(git-forge api "projects/:fullpath/merge_requests?state=opened&source_branch=${t//\//%2F}" 2>/dev/null | jq length) == 0 ]]; do
        chain=($t $chain) x=$t
      done
      for x in $chain; do
        git show-ref --verify --quiet "refs/remotes/origin/$x" && continue
        print -r -- "$x is not pushed yet; gp pushes it and offers the MR" > $said
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
