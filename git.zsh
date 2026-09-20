# Sourced from ~/.zshrc (otis-setup says how). The commands themselves are
# programs in bin/ (bin/otis-run, share/otis.zsh), which goes on PATH here
# unless it is there already; this file is what only a shell can do: the
# prompt hooks, the gs alias, and following a picker that moves you.
typeset -g OTIS_HOME=${${(%):-%x}:A:h}
[[ ":$PATH:" == *":$OTIS_HOME/bin:"* ]] || path=("$OTIS_HOME/bin" $path)

# oh-my-zsh's git plugin and others alias many of these names (gb, ga, gp, gst),
# and an alias or a function wins over a program on PATH. So any alias or
# function named like an otis command goes, the names read from bin/ itself
# (the links to otis-run) so a new command is covered without a list to keep
# up.
() {
  local -a cmds=($OTIS_HOME/bin/*(@N:t)) taken=(${(k)aliases}) clash
  clash=(${cmds:*taken})
  (( $#clash )) && unalias -- $clash
  taken=(${(k)functions})
  clash=(${cmds:*taken})
  (( $#clash )) && unfunction -- $clash
}

alias gs='git status'

# The theme (otis-theme), once, here: it is a property of your terminal rather
# than of a repo, and every otis command inherits it instead of working it out
# again, which was two thirds of what a bare command cost. otis-theme below
# puts a newly picked one into this shell, so it takes without opening a new one.
[[ -n $OTIS_T_NAME ]] || eval "$(otis-theme --env)"
otis-theme() {
  command otis-theme "$@" || return
  [[ $1 == -* ]] || eval "$(command otis-theme --env)"
}

# The commands that move you (gb and gmr switching into a worktree, gw, gwn,
# and otis through any of them) are programs, and a program cannot change its
# shell's directory. It writes where it went to the file named in OTIS_CD,
# and the shell goes there once it exits.
_otis_cd() {
  local f rc
  f=$(mktemp -t otis-cd.XXXXXX) || return
  OTIS_CD=$f command "$@"
  rc=$?
  [[ -s $f ]] && cd -- "$(<$f)"
  rm -f -- $f
  return rc
}
gb()   { _otis_cd gb "$@" }
gw()   { _otis_cd gw "$@" }
gwn()  { _otis_cd gwn "$@" }
gmr()  { _otis_cd gmr "$@" }
gci()  { _otis_cd gci "$@" }
otis() { _otis_cd otis "$@" }

# Background fetch, like lazygit's, so the prompt's ahead/behind stays honest.
# Only the default branch and this branch's upstream, and the local default
# branch too when it's safe: the remote has ~6k branches, and a full fetch with
# prune would churn all of them. Throttled per worktree by a stamp's mtime.
# BatchMode and no terminal prompt so a locked ssh key can never grab the tty
# from a detached job. The prompt picks it up on the next redraw.
_git_autofetch() {
  local gd
  gd=$(git rev-parse --git-dir 2>/dev/null) || return
  local stamp="$gd/autofetch-stamp"
  local -a fresh=(${~stamp}(Nmm-5))
  (( $#fresh )) && return
  touch "$stamp"
  local up=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null)
  # The default branch is whatever origin/HEAD names (clone sets it), since
  # asking for a branch origin lacks fails the whole fetch. A repo without
  # origin/HEAD fetches only the upstream.
  local def=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  def=${def#origin/}
  local -a refs
  if [[ -n $def ]]; then
    # def:def fast-forwards the local branch without touching any working tree.
    # Git refuses it (failing the whole fetch) while it is checked out somewhere.
    refs=("$def:$def")
    git worktree list --porcelain | grep -qxF "branch refs/heads/$def" && refs=("$def")
  fi
  [[ $up == origin/* && $up != origin/$def ]] && refs+=("${up#origin/}")
  (( $#refs )) || return
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git fetch --quiet --no-tags origin $refs &>/dev/null &!
}
# Ahead/behind for the prompt (⇡ yours, ⇣ theirs), exported for starship's
# env_var module. One git call from the hook that runs anyway, where a starship
# custom module started a shell and git on every prompt.
#
# Against origin's copy of this branch, so ⇡ means not pushed yet: gp pushes
# without -u and new branches track origin/main, so the upstream rarely is that
# copy. push.default=current makes @{push} name it whatever the user's setting.
# A branch never pushed falls back to its upstream, at a second call.
_git_track() {
  local counts
  counts=$(git -c push.default=current rev-list --left-right --count 'HEAD...@{push}' 2>/dev/null ||
    git rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null) || { unset GIT_TRACK; return }
  local -a n=(${=counts})
  local out=
  (( n[1] > 0 )) && out="⇡$n[1]"
  (( n[2] > 0 )) && out+="${out:+ }⇣$n[2]"
  if [[ -n $out ]]; then export GIT_TRACK=$out; else unset GIT_TRACK; fi
}
# Alerts from GitLab: a desktop notification for what needs you, such as a
# review request, a comment, a failed pipeline, or an MR going live (every kind
# is listed in git-alerts, which runs once a minute). One poller for every
# shell: the first prompt starts it, it notifies through that terminal where
# the terminal can (Ghostty best, otis-notify says which) and from the system
# where it cannot, and it stops within a minute of that shell exiting, for the
# next prompt anywhere to start another. A precmd check costs a file read and
# a kill -0 and a glob of its age, all builtins.
_git_alerts() {
  local lock=${XDG_CACHE_HOME:-$HOME/.cache}/git-alias/alerts.lock pid
  if [[ -d $lock ]]; then
    [[ -r $lock/pid ]] && pid=$(<$lock/pid)
    if [[ -n $pid ]]; then
      # The pid alone could be any process's after a restart, so the poller
      # touches it each round, and one untouched for ten minutes is gone.
      local -a beat=($lock/pid(Nmm-10))
      (( $#beat )) && kill -0 $pid 2>/dev/null && return
    else
      # Taken a moment ago by a shell still writing its pid (tabs restored at once).
      local -a fresh=($lock(Nms-10))
      (( $#fresh )) && return
    fi
    rm -rf $lock
  fi
  mkdir -p ${lock:h} && mkdir $lock 2>/dev/null || return
  local shell=$$ tty=$TTY
  {
    local title body
    while kill -0 $shell 2>/dev/null; do
      touch $lock/pid 2>/dev/null
      (cd ~ && git-alerts) | while IFS=$'\t' read -r title body; do
        otis-notify --tty $tty "$title" "$body"
      done
      sleep 60
    done
    rm -rf $lock
  } &!
  print $! > $lock/pid
}
# Worktrees on merged or closed branches go on their own, once an hour per
# repo, in the background (git-worktree-sweep, gw's own rule), and each one
# that went is an alert with the line that brings its branch back
# (otis-notify). So a branch worked on in its
# worktree and merged from gmr does not wait for gw.
_git_sweep() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return
  local stamp="$common/sweep-stamp"
  local -a fresh=(${~stamp}(Nmh-1))
  (( $#fresh )) && return
  touch "$stamp"
  local tty=$TTY
  {
    git-worktree-sweep 2>/dev/null </dev/null | while IFS= read -r line; do
      otis-notify --tty $tty "worktree swept" "$line"
    done
  } &!
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _git_track
add-zsh-hook precmd _git_autofetch
add-zsh-hook precmd _git_sweep
add-zsh-hook precmd _git_alerts
