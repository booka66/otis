#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- otis-config: settings from git config, the repo's .otis and origin,
# which is on GitLab here.
git remote set-url origin git@gitlab.example.com:group/sub/repo.git
expect config/host "$(otis-config host)" "gitlab.example.com"
expect config/url "$(otis-config url)" "https://gitlab.example.com"
expect config/project "$(otis-config project)" "group/sub/repo"
expect config/main "$(otis-config main)" "main"
expect config/base "$(otis-config base)" "origin/main"
expect config/gitlab "$(otis-config gitlab; echo $?)" "0"
expect config/gates-default "$(otis-config gateJobs)" '[]'
expect config/deploy-default "$(otis-config deployJob)" "deploy"
# The repo's own .otis, under your git config, and only for what a team shares.
printf '[otis]\n\tgateJob = shared-gate\n\tdeployJob = ship\n\tworktrees = /elsewhere\n' > .otis
expect config/repo-file "$(otis-config gateJobs deployJob | tr '\n' ' ')" '["shared-gate"] ship '
expect config/repo-file-not-worktrees "$(otis-config worktrees)" ".claude/worktrees"
git config otis.gateJob one; git config --add otis.gateJob two
expect config/gates-set "$(otis-config gateJobs)" '["one","two"]'
git config --replace-all otis.gateJob ''
expect config/gates-none "$(otis-config gateJobs)" '[]'
rm .otis
expect config/lessons-default "$(otis-config lessons; echo $?)" "1"
git config otis.lessons true
expect config/lessons-on "$(otis-config lessons; echo $?)" "0"
expect config/terminalBrowser-default "$(otis-config terminalBrowser; echo $?)" "0"
git config otis.terminalBrowser false
expect config/terminalBrowser-off "$(otis-config terminalBrowser; echo $?)" "1"
git config --unset otis.terminalBrowser
git config otis.host code.example.com; git config otis.project other/path; git config otis.mainBranch develop
expect config/host-set "$(otis-config host)" "code.example.com"
expect config/project-set "$(otis-config project)" "other/path"
expect config/main-set "$(otis-config main)" "develop"
expect config/base-fallback "$(otis-config base)" "HEAD"
git config --unset otis.host; git config --unset otis.project; git config --unset otis.mainBranch
git remote set-url origin https://github.com/x/y.git
expect config/not-gitlab "$(otis-config gitlab; echo $?)" "1"
expect config/forge-github "$(otis-config forge)" "github"
git config otis.forge gitlab
expect config/forge-set "$(otis-config forge)" "gitlab"
git config --unset otis.forge
expect config/several "$(otis-config project main host | tr '\n' ' ')" "x/y main github.com "
expect config/several-unset "$(otis-config main cursorEnv main | tr '\n' '|')" "main||main|"
expect config/project-https "$(otis-config project)" "x/y"
git remote set-url origin gitlab.example.com:group/repo.git
expect config/project-scp-no-user "$(otis-config project)" "group/repo"
expect config/forge-gitlab "$(otis-config forge)" "gitlab"
git remote set-url origin git@gitlab.example.com:group/sub/repo.git

# The answers are kept in the git dir and exported by a picker (--env), so the
# same questions are asked here three ways: worked out fresh, read back from
# the file, and read from the environment a picker would have set.
cached() { (eval "$(otis-config --env)"; otis-config "$@"); }
rm -f "$(git rev-parse --path-format=absolute --git-dir)/otis-config-cache"
expect config/cache-cold "$(otis-config main base project | tr '\n' ' ')" "main origin/main group/sub/repo "
expect config/cache-warm "$(otis-config main base project | tr '\n' ' ')" "main origin/main group/sub/repo "
expect config/cache-env "$(cached main base project | tr '\n' ' ')" "main origin/main group/sub/repo "
expect config/cache-env-status "$(cached cursorEnv; echo $?)" "1"
expect config/cache-env-bool "$(cached gitlab; echo $?)" "0"
# A setting changed after the cache was made is what the next question answers,
# the environment's copy included, since both are held to the files they came from.
git config otis.deployJob shipped-since
expect config/cache-after-set "$(otis-config deployJob)" "shipped-since"
expect config/cache-env-after-set "$(cached deployJob)" "shipped-since"
git config --unset otis.deployJob
expect config/cache-after-unset "$(cached deployJob)" "deploy"
printf '[otis]\n\tdeployJob = from-repo-file\n' > .otis
expect config/cache-after-repo-file "$(cached deployJob)" "from-repo-file"
rm -f .otis
# A .otis value that could break out of a quote, run something, or pass git an
# option is dropped, and the setting answers as if it were not there.
printf '[otis]\n\tproject = x`touch %s/pwned`\n\tmainBranch = --upload-pack=evil\n\tdeployJob = deploy production\n' "$tmp" > .otis
expect config/repo-file-unsafe "$(cached project main deployJob 2>/dev/null | tr '\n' '|')" "group/sub/repo|main|deploy production|"
rm -f .otis
# A worktree's .otis answers in that worktree alone: its cache is its own, so
# an MR's head checked out for review cannot choose what the main checkout reads.
git worktree add -q --detach "$tmp/cfg-wt"
printf '[otis]\n\tdeployJob = from-worktree\n' > "$tmp/cfg-wt/.otis"
expect config/worktree-own "$(cd "$tmp/cfg-wt" && otis-config deployJob)" "from-worktree"
expect config/worktree-not-main "$(cached deployJob)" "deploy"
git worktree remove --force "$tmp/cfg-wt"
# The editor follows $OTIS_EDITOR, so it is never one of the answers kept.
expect config/cache-editor-env "$(OTIS_EDITOR=chosen cached editor)" "chosen"
expect config/cache-editor-none "$(PATH=$tmp/eds:$PATH OTIS_EDITOR= cached editor)" "nvim"
expect config/cache-env-tb "$(cached terminalBrowser; echo $?)" "0"
# A repo's .otis cannot choose whether pages take this pane.
printf '[otis]\n\tterminalBrowser = false\n' > .otis
expect config/repo-file-not-terminalBrowser "$(otis-config terminalBrowser; echo $?)" "0"
rm -f .otis

# otis-open: terminal-browser takes the pane when the setting is on and it is
# on PATH; a folder or a recording still opens in its app.
tb=$tmp/tb; mkdir -p "$tb"
printf '#!/bin/sh\nprintf "tb %%s\\n" "$*"\n' > "$tb/terminal-browser"
chmod +x "$tb/terminal-browser"
openpath=$root/bin:/usr/bin:/bin
tbpath=$tb:$root/bin:/usr/bin:/bin
expect open/fzf-url "$(PATH=$openpath otis-open --fzf 'https://example.com/mr')" "execute-silent(otis-open 'https://example.com/mr')"
expect open/fzf-tb "$(PATH=$tbpath otis-open --fzf 'https://example.com/mr')" "execute(otis-open 'https://example.com/mr')"
expect open/fzf-html "$(PATH=$tbpath otis-open --fzf /tmp/report.html)" "execute(otis-open '/tmp/report.html')"
opend=$tmp/open-dir; mkdir -p "$opend"
expect open/fzf-dir "$(PATH=$tbpath otis-open --fzf "$opend")" "execute-silent(otis-open '$opend')"
expect open/fzf-mp4 "$(PATH=$tbpath otis-open --fzf /tmp/c1.mp4)" "execute-silent(otis-open '/tmp/c1.mp4')"
git config otis.terminalBrowser false
expect open/fzf-off "$(PATH=$tbpath otis-open --fzf 'https://example.com/mr')" "execute-silent(otis-open 'https://example.com/mr')"
git config --unset otis.terminalBrowser
expect open/tb "$(PATH=$tbpath otis-open 'https://example.com/mr')" "tb open https://example.com/mr"

# otis-tiles: a frame too big for herdr to draw goes as strips of whole rows,
# each a part of the same file, the cursor back where it was; one small
# enough, and what is not a frame, goes as it came.
frame() { printf '\033[H\033_Ga=T,f=32,s=%s,v=%s,t=f,i=1,p=1,C=1,q=2;L3RtcC9m\033\\' "$1" "$2"; }
expect tiles/strips "$(frame 3540 2501 | otis-tiles --cut 61 2501 | tr '\033' '^')" \
  '^[H^_Ga=T,f=32,s=3540,v=1148,t=f,p=1,C=1,q=2,i=1879048448,S=16255680,O=0;L3RtcC9m^\^[28B^_Ga=T,f=32,s=3540,v=1148,t=f,p=1,C=1,q=2,i=1879048449,S=16255680,O=16255680;L3RtcC9m^\^[28B^_Ga=T,f=32,s=3540,v=205,t=f,p=1,C=1,q=2,i=1879048450,S=2902800,O=32511360;L3RtcC9m^\^[56A'
expect tiles/small "$(frame 1960 2000 | otis-tiles --cut 61 2501 | tr '\033' '^')" "$(frame 1960 2000 | tr '\033' '^')"
expect tiles/not-a-frame "$(printf 'a\033_Gi=300,a=q,t=f,f=32,s=1,v=1;L3RtcC9m\033\\b\033[2J' | otis-tiles --cut 61 2501 | tr '\033' '^')" 'a^_Gi=300,a=q,t=f,f=32,s=1,v=1;L3RtcC9m^\b^[2J'

expect worktree-path/named "$(git-worktree-path named x)" "$tmp/repo/.claude/worktrees/x"
git config otis.worktrees .wt
expect worktree-path/config "$(git-worktree-path named x)" "$tmp/repo/.wt/x"
# The three a worktree list and its preview want, in one run rather than three.
expect worktree-path/roots "$(git-worktree-path roots | tr '\n' ' ')" "$tmp/repo $tmp/repo/.wt/review $tmp/repo/.wt/mine "
git config --unset otis.worktrees

# --- otis-config: what a setting does is one paragraph, for the pane to wrap
# at its own width, not the lines this file's list is broken in.
expect config/about-one-paragraph "$(otis-config --about forge | sed -n 1p | grep -c 'github when origin is on github.com, else gitlab')" "1"
