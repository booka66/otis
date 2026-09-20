# Sourced from ~/.config/fish/config.fish (otis-setup says how). The commands
# are programs in bin/, which goes on PATH here; this file is what only the
# shell can do: the gs alias, and following a picker that moves you (git.zsh
# says how). The prompt hooks (background fetch, ahead/behind, alerts, the
# worktree sweep) are zsh's alone for now.
set -l otis_home (dirname (realpath (status filename)))
contains -- $otis_home/bin $PATH; or set -gx PATH $otis_home/bin $PATH

alias gs 'git status'

# The theme (otis-theme), once, here: it is a property of your terminal rather
# than of a repo, and every otis command inherits it instead of working it out
# again. --env-fish because fish cannot read an export. The function below puts
# a newly picked theme into this shell, so it takes without opening a new one.
if not set -q OTIS_T_NAME
    otis-theme --env-fish | source
end
function otis-theme
    command otis-theme $argv; or return
    # Only the bare picker changes which theme is yours; every flag just prints.
    if test (count $argv) -eq 0
        command otis-theme --env-fish | source
    end
end

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

# Completion: every otis command offers --help, and the ones that take a ref, a
# path or a setting offer those too (bin/otis-complete, the same list zsh and
# bash are given). fish completes filenames itself, so @files is dropped here.
function _otis_complete
    set -l parts (commandline -opc)
    test (count $parts) -gt 0; or return
    for c in (command otis-complete $parts[1] 2>/dev/null)
        # fish offers filenames of its own accord, so @files is nothing to say.
        test "$c" = '@files'; and continue
        echo $c
    end
end
for f in $otis_home/bin/* otis-config otis-theme otis-setup otis-help
    complete -c (string replace -r '.*/' '' -- $f) -a '(_otis_complete)'
end
