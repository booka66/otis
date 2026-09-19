# Sourced from ~/.config/fish/config.fish (otis-setup says how). The commands
# are programs in bin/, which goes on PATH here; this file is what only the
# shell can do: the gs alias, and following a picker that moves you (git.zsh
# says how). The prompt hooks (background fetch, ahead/behind, alerts, the
# worktree sweep) are zsh's alone for now.
set -l otis_home (dirname (realpath (status filename)))
contains -- $otis_home/bin $PATH; or set -gx PATH $otis_home/bin $PATH

alias gs 'git status'

function _otis_cd
    set -l f (mktemp -t otis-cd.XXXXXX); or return
    env OTIS_CD=$f $argv
    set -l rc $status
    test -s $f; and cd (cat $f)
    rm -f -- $f
    return $rc
end
for c in gb gw gwn gmr gci otis
    function $c --inherit-variable c
        _otis_cd $c $argv
    end
end
