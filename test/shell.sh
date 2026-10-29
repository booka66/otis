#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- gb's n: an MR in one key, drafted from the branch's commits as gp's
# first push offers one; refused, in the footer, where there is one already
# feature is a commit past main.
git switch -q -c feature && printf 'f\n' > f.ts && git add f.ts && git commit -qm "Feature" && git switch -q main
mkdir -p "$tmp/dash"
expect mr-new/draft "$(zsh -fc "source '$root/share/otis.zsh'; _g_mr_draft feature && print -r -- \"\$mr_target|\$mr_title\"")" "main|Feature"
expect mr-new/has-one "$(GIT_FZF_STATE=$tmp/dash git-mr-new --check feature 12 >/dev/null; strip < "$tmp/dash/note")" "feature already has !12; w opens it"
expect mr-new/no-forge "$(GIT_FZF_STATE=$tmp/dash git-mr-new --check feature >/dev/null; strip < "$tmp/dash/note")" "origin is on neither GitLab nor GitHub"
GIT_FZF_STATE=$tmp/dash git-mr-new --ask feature </dev/null >/dev/null 2>&1
expect mr-new/not-pushed "$(GIT_FZF_STATE=$tmp/dash git-mr-new --said >/dev/null; strip < "$tmp/dash/note")" "feature is not pushed yet; gp pushes it and offers the MR"

# --- gb's enter brings a branch here from its worktree (_g_goto_branch)
goto() { zsh -fc "source '$root/share/otis.zsh'; _g_goto_branch $* >/dev/null 2>&1 && git rev-parse --show-toplevel" 2>/dev/null; }
git branch -q away main
git-worktree-add away away >/dev/null 2>&1
expect goto/away-in-worktree "$(git-worktree-path of away)" "$tmp/repo/.claude/worktrees/away"
# A worktree nested in the checkout is not the checkout (share/in-root.sh):
# the main checkout's top and HEAD are not its own.
inroot() { (cd "$1" && OTIS_C_ROOT=$tmp/repo sh -c ". '$share/in-root.sh'; in_root && echo in || echo not"); }
expect root/nested-worktree "$(inroot "$tmp/repo/.claude/worktrees/away")" "not"
expect root/checkout "$(mkdir -p "$tmp/repo/sub" && inroot "$tmp/repo/sub")" "in"
printf 'w\n' > "$tmp/repo/.claude/worktrees/away/w.ts"
expect goto/dirty-refused "$(goto away)$(git branch --show-current)" "main"
rm "$tmp/repo/.claude/worktrees/away/w.ts"
expect goto/W-goes-there "$(goto away worktree)" "$tmp/repo/.claude/worktrees/away"
expect goto/comes-here "$(goto away)" "$tmp/repo"
expect goto/worktree-gone "$(git-worktree-path of away)$([ -e "$tmp/repo/.claude/worktrees/away" ] && echo still)" "$tmp/repo"
expect goto/trashed "$(ls -d "$trash"/away-* 2>/dev/null | wc -l | tr -d ' ') $(ls "$trash"/away-*/.git 2>/dev/null | wc -l | tr -d ' ')" "1 0"
git switch -q main
git-worktree-add mine --detach main >/dev/null 2>&1 && git -C "$tmp/repo/.claude/worktrees/mine" switch -q away
expect goto/mine-detached "$(goto away) $(git -C "$tmp/repo/.claude/worktrees/mine" branch --show-current)$([ -e "$tmp/repo/.claude/worktrees/mine" ] && echo kept)" "$tmp/repo kept"
git switch -q main
expect goto/main-checkout-is-home "$(cd "$tmp/repo/.claude/worktrees/mine" && goto main)" "$tmp/repo"
git worktree remove --force "$tmp/repo/.claude/worktrees/mine" && git branch -qD away

# --- a command that moves you hands the directory to the shell that ran it:
# each shell's wrapper follows it, and with none it says where to go. The
# board, stubbed, leaving for a worktree as enter on one does.
hop=$tmp/repo/.claude/worktrees/hop
mkdir -p "$tmp/cdstub" "$hop"
printf '#!/bin/sh\nprintf "cd\\t%%s\\n" "%s"\n' "$hop" > "$tmp/cdstub/otis-dash"; chmod +x "$tmp/cdstub/otis-dash"
expect cd/zsh "$(PATH=$tmp/cdstub:$PATH zsh -fc "source '$root/git.zsh'; otis >/dev/null 2>&1; pwd")" "$hop"
expect cd/bash "$(PATH=$tmp/cdstub:$PATH bash --norc --noprofile -c "source '$root/otis.bash'; otis >/dev/null 2>&1; pwd")" "$hop"
if command -v fish >/dev/null 2>&1; then
  expect cd/fish "$(PATH=$tmp/cdstub:$PATH fish --no-config -c "source '$root/otis.fish'; otis >/dev/null 2>&1; pwd")" "$hop"
fi
expect cd/no-wrapper "$(PATH=$tmp/cdstub:$PATH otis 2>&1 >/dev/null | tail -1; pwd)" "now: cd ~/repo/.claude/worktrees/hop
$tmp/repo"
rm -rf "$tmp/cdstub" "$hop"
# An alias or function of the same name (oh-my-zsh's gb, gst) would win over
# the command, so sourcing takes it away.
expect shell/zsh-clash "$(zsh -fc "alias gst='git stash'; gl() { echo mine; }; source '$root/git.zsh'; whence -w gst gl gb")" "gst: command
gl: command
gb: function"
expect shell/bash-clash "$(bash --norc --noprofile -c "shopt -s expand_aliases; alias gst='git stash'; source '$root/otis.bash'; type -t gst gb")" "file
function"

# --- otis-edit: nvim unless told otherwise, and each editor's way to a line
expect edit/default "$(PATH=$tmp/eds:$PATH OTIS_EDITOR= otis-edit --name)" "nvim"
# Without nvim, the editor you already have.
expect edit/default-without-nvim "$(EDITOR=nano VISUAL= OTIS_EDITOR= PATH=$root/bin:/usr/bin:/bin otis-config editor)" "nano"
expect edit/nvim "$(OTIS_EDITOR=$tmp/eds/nvim otis-edit -R +3 -- a.ts)" "-R +3 -- a.ts"
expect edit/cursor "$(OTIS_EDITOR=$tmp/eds/cursor otis-edit -R +12 -- a.ts)" "--goto a.ts:12"
expect edit/nvim-col "$(OTIS_EDITOR=$tmp/eds/nvim otis-edit +12:5 -- a.ts)" "+call cursor(12, 5) -- a.ts"
expect edit/cursor-col "$(OTIS_EDITOR=$tmp/eds/cursor otis-edit +12:5 -- a.ts)" "--goto a.ts:12:5"
expect edit/zed "$(OTIS_EDITOR=$tmp/eds/zed otis-edit +7 -- -odd.ts)" "./-odd.ts:7"
git config otis.editor "$tmp/eds/hx"
expect edit/git-config "$(OTIS_EDITOR= otis-edit +2 -- b.ts)" "b.ts:2"
git config --unset otis.editor
# Under one of otis's screens (OTIS_FRAME, the file it drew itself into),
# the editor opens as anywhere: that is not nvim's frame.
expect edit/under-a-screen "$(OTIS_FRAME=$tmp/frame OTIS_EDITOR=$tmp/eds/nvim otis-edit +3 -- a.ts)" "+3 -- a.ts"
expect frame/focus-outside "$(OTIS_FRAME=$tmp/frame otis-frame --focus; echo "rc=$?")" "rc=0"
# In otis-frame's picker, the file opens in the frame's nvim.
mkdir -p "$tmp/nvs" && printf '#!/bin/sh\necho "$@" > "%s"\n' "$tmp/nvs.args" > "$tmp/nvs/nvim" && chmod +x "$tmp/nvs/nvim"
expect edit/inside-nvim "$(OTIS_NVIM_FRAME=1 NVIM=/s.sock PATH=$tmp/nvs:$PATH OTIS_EDITOR= otis-edit -R +12:5 -- a.ts; cat "$tmp/nvs.args")" "--server /s.sock --remote-expr luaeval('dofile(_A[1]).open(_A[2], _A[3], _A[4], _A[5], _A[6])', ['$share/frame.lua', '$PWD/a.ts', 12, 5, v:true, ''])"

