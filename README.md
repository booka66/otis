# otis

Git and GitLab from the terminal. `otis` is a dashboard of everything that wants you: MRs to review, failed pipelines, threads on yours, deploys. Under it are fzf pickers for branches, staging, the log, worktrees and merge requests. You review and comment on lines right in the picker (or in nvim, with the comments inline), and read a change by symbol instead of file by file. Claude Code can review an MR, propose fixes, watch production after a deploy, or check that a change actually works. It runs on macOS and Linux.

## Install

```sh
brew tap booka66/otis https://github.com/booka66/otis
brew trust --formula booka66/otis/otis booka66/seam/seam
brew install booka66/otis/otis
otis-setup
```

Homebrew 7 won't load a formula from someone else's tap until you trust it, and seam comes in as a dependency from its own tap, so trust both first. Older Homebrew has no `brew trust`; skip that line.

Or clone it and run setup from the clone:

```sh
git clone https://github.com/booka66/otis.git ~/otis && ~/otis/bin/otis-setup
```

`otis-setup` checks what's missing and offers to install it, asks a few questions (branch prefix, editor, theme), and adds one line to your shell config. It won't change anything without asking, and you can rerun it whenever you like. Open a new terminal when it's done.

You need zsh installed, though your own shell can be zsh, bash or fish. You also need git 2.41+, fzf, jq 1.7+, glab logged in to your GitLab, delta, and a Nerd Font. Setup checks all of these. nvim 0.10+, seam, ast-grep, glow and Claude Code are optional, and each turns on more features: with nvim, a review opens with its comments inline beside the diff; without it, files open in your editor and you comment from the review itself.

## Getting started

Run `otis-tour`. It's a menu of short guided tours, most of them hands-on with a made-up repo: reviewing by symbol, the review loop in `gmr`, Claude's reviews and fixes, verifying a change, shipping to production, committing, branches and worktrees, settings, and a cheat sheet.

After that, run `otis` in a repo and go from there. `gg` lists every command, and any command answers `--help` with what it does and every key it has. Tab completion knows what each one takes: a branch for `gl`, a path for `ga`, a setting for `otis-config`. In any picker, `j`/`k` moves, `/` searches, `q` quits, and `?` shows every key and explains the columns.

## Settings

Run `otis-config` to see every setting, where its value comes from, and what it does, and to change it. You can also press `c` on the dashboard. Settings live in git config under `otis.*`, so a setting can apply to one repo or to all of them.

A team can commit a `.otis` file at the top of its repo, in git config format, with shared settings like its CI's deploy job or its approval gate jobs. Your own git config always wins. A `.otis` can't set anything that runs commands or picks paths on your machine (what Claude may run, lint commands, your editor, worktree location), so cloning a repo can't choose those for you.

Claude's background runs have no shell unless you allow specific commands with `git config --add otis.claudeCommand '<prefix>'`. That list is what stops a hostile MR's text from getting Claude to run its own commands, so name your checks and never a shell.

## Uninstall

Remove the line `otis-setup` added to your shell config. Caches are in `~/.cache/git-alias` and each repo's `.git/git-alias-cache`. Claude's run records are under `.git/gmr-claude`, `gmr-fix`, `gmr-watch` and `otis-verify`, and otis's worktrees are under `.claude/worktrees`.

## Hacking on it

`bin/otis-test` runs the tests in a throwaway repo, no GitLab needed, including the pickers driven headless through fzf's port. Every picker is a call to `git-fzf`, whose `key=label` list drives the footer, the `?` help, `--help` and which keys get unbound while you search. Adding a key takes one entry in that list and one `--bind`. A key whose answer has to come from GitLab wraps its command in `git-fzf-later`, which runs it behind the picker and sends its actions back over fzf's port, because fzf draws nothing at all while a `transform` runs — not its own spinner, and not an action sent to its port. A command's name and what it does are written once, in `share/commands.tsv`: `gg` renders it, `otis-help` prints one row of it, and the completions offer the names from it, so a new command is a row there and nothing else. `otis-config` is the only place that reads settings. Colors come from one palette, in `share/rowfmt.awk`, `share/otis.jq` and `share/palette.sh`; your shell loads the theme once when it starts, and every command inherits it. What otis brings to seam is in `share/seam`: a lazy references provider over tsgo's callers (git-callers) and what a file is (git-test-files); the shell line puts that directory on `SEAM_PATH`, so `seam --html`, `--score` and `--md` see the callers otis finds without anything written into your config. The gloss is asked for through `seam --gloss` and `symbols.md` is `seam --md`, so both have one owner.
