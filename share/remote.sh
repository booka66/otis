# Shared by what runs on otis.remote, a workspace reached by ssh, in
# otis.remotePath, its checkout of this repo (git-remote-run, otis-thread):
# . "$share/remote.sh". Both are git config of your own; a repo's .otis
# cannot set where your code is sent.

# ssh, and git's pushes and fetches there: one connection a host, kept a
# minute after its last use. Through coder ssh each new one takes three or
# four seconds, and a thread's turn makes ten.
ssh() { command ssh -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/otis-%C" -o ControlPersist=60 "$@"; }
GIT_SSH_COMMAND="ssh -o ControlMaster=auto -o ControlPath=$HOME/.ssh/otis-%C -o ControlPersist=60"
export GIT_SSH_COMMAND

# quote <text>: <text> as one shell word, for a script sent over ssh, whose
# command line is parsed again on the far side.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# give_claude <host>: what claude needs there to run on your subscription
# with no login (a CLAUDE_CODE_OAUTH_TOKEN), from ~/.claude/remote-env here,
# mode 600, into ~/.claude/env there, the first time a host is used. An ssh
# command reads no login files, so what runs claude there sources it first.
# It is a long-lived token in every workspace it reaches: revoke it in your
# account settings if one is lost.
give_claude() {
  [ -r "$HOME/.claude/remote-env" ] || return 0
  ssh "$1" '[ -r ~/.claude/env ]' 2>/dev/null && return 0
  printf "${GK_CONTEXT}giving %s what it needs to run claude ...${GK_R}\n" "$1"
  ssh "$1" 'umask 077; mkdir -p ~/.claude; cat > ~/.claude/env
    grep -qs claude/env ~/.bashrc 2>/dev/null || echo "[ -r ~/.claude/env ] && . ~/.claude/env" >> ~/.bashrc' \
    < "$HOME/.claude/remote-env" || printf 'could not set up %s to run claude\n' "$1" >&2
}
