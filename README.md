# otis

Git and GitLab from the terminal. `otis` is a board of your changes: a row each, and each row says the one move its change needs next, in words, before its title: review it, pipeline broke, answer 2 threads, merge it. Enter does what the row says. Beside the board, or under it on a narrow screen, the row you are on in full: how its verification, its pipeline, its review and its merge each stand. MRs stacked on one another stay together, joined by a rail, the first to merge at the bottom. Red is only for a change of yours that broke. Under those rows is everything else, folded to a line a group until you open one: the other open MRs, the branches with none, what shipped this week, what can be deleted, the worktrees and the deploys. The board keeps itself fresh and says when GitLab last answered. Beside it are pickers for branches, staging and the log, drawn in the terminal, whose footer says what each key does on the row you are on. You review and comment on lines right in the picker (or in nvim, with the comments inline), and read a change by symbol instead of file by file. Claude Code can review an MR, propose fixes, watch production after a deploy, or check that a change actually works. It runs on macOS and Linux.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/booka66/otis/main/install.sh | sh
```

That puts the newest release in `~/.local/share/otis` and runs `otis-setup` from there. `otis-update` brings it up to the next release.

Or clone it and run setup from the clone:

```sh
git clone https://github.com/booka66/otis.git ~/otis && ~/otis/bin/otis-setup
```

Installed through Homebrew before? `brew uninstall otis`, then the line above; `otis-setup` finds the old line in your shell config and says what to put instead.

`otis-setup` checks what's missing and offers to install it, asks a few questions (branch prefix, editor, theme), and adds one line to your shell config. It won't change anything without asking, and you can rerun it whenever you like. Open a new terminal when it's done.

You need zsh installed, though your own shell can be zsh, bash or fish. You also need git 2.41+, jq 1.7+, glab logged in to your GitLab, delta, and a Nerd Font. Setup checks all of these. nvim 0.10+, seam, ast-grep, glow and Claude Code are optional, and each turns on more features: with nvim, a review and the symbol views open inside it, the list on the left and the code enter opens on the right, a review's comments inline; without it, files open in your editor and you comment from the review itself.

The symbol view reads a change with seam by default. `git config --global otis.engine dagger` (or `otis config`) has [dagger](https://github.com/joshmoody24/dagger) read it instead, through language servers (TypeScript 7's `tsc --lsp` for TypeScript: `npm install -g typescript`), and `G` opens dagger's page. seam still scores, splits and glosses what dagger reads, so keep both installed.

A changed function that broke before says so over its diff: the fixes to its lines in the last 18 months, each under the change it fixed when git blame lays it there (a fix within 60 days of the lines it took out), found from git history alone in the background (`git-symbols-past`, `share/past.mjs`). A change here broke this code before, and this one can break it the same way.

## Getting started

Run `otis-tour`. It's a menu of short guided tours, most of them hands-on with a made-up repo: reviewing by symbol, the review loop, Claude's reviews and fixes, verifying a change, shipping to production, committing, branches and worktrees, settings, and a cheat sheet.

After that, run `otis` in a repo and go from there. `gg` lists every command, and any command answers `--help` with what it does and every key it has. Tab completion knows what each one takes: a branch for `gl`, a path for `ga`, a setting for `otis-config`. In any picker, `j`/`k` moves, `/` searches, `q` quits, and `?` shows every key and explains the columns. A few keys mean the same on every screen: `enter` does what the footer says, `space` marks, `y` copies, `w` opens in the browser, `u` refreshes, `d` removes (after asking), `e` edits, `r` runs or retries it again (in `gl` it rewords), and `C`, `V` and `D` start Claude's runs. On the dashboard, `j`/`k` pick a change and `h`/`l` one of its lights, `enter` opens that light (on the first it switches to the branch or goes to its worktree; on a group it opens or folds it), `f` folds in a fix beside it, and a change's own keys work on its row whatever light you are on: `V` verifies it, `c` is its commits, `m` merges, `b` rebases, `a` asks reviewers (`?` lists them all; the footer names the ones for the light you are on). `gm`, `gb`, `ga`, `gd` and `gw` open those commands' lists.

otis keeps a log of the keys you press and the commands you run, in `~/.cache/otis/keys.tsv` on your machine and nowhere else (`OTIS_KEY_LOG=off` stops it). `otis-usage [days]` reads it, the last two weeks unless you say: each screen's keys as a heat bar by how often you pressed them and how long ago you last did, the ones you never have, what came before each `u` (a refresh is a screen that did not show what you expected), and the commands you didn't run.

## Settings

Run `otis-config` to see every setting, where its value comes from, and what it does, and to change it. On the board, `gc` opens it. `F` on the board finds a file with nvim's own fuzzy finder (snacks.nvim's smart picker, else Telescope's or fzf-lua's) and opens it; `git config otis.finder '<leader><leader>'` makes it a mapping of your own instead, or name an Ex command. Settings live in git config under `otis.*`, so a setting can apply to one repo or to all of them.

A team can commit a `.otis` file at the top of its repo, in git config format, with shared settings like its CI's deploy job or its approval gate jobs. Your own git config always wins. A `.otis` can't set anything that runs commands or picks paths on your machine (what Claude may run, lint commands, your editor, worktree location), so cloning a repo can't choose those for you.

`t` on the board starts a thread: Claude working on a branch on your workspace, on your own Claude subscription there. Set `git config otis.remote <ssh host>` (a Coder workspace after `coder config-ssh`) and `otis.remotePath`, its checkout of the repo, as for `F`'s lint. On a branch of yours, Claude works on that branch; anywhere else, on a new one off the base, named from what you asked. Each turn sends the branch there, runs Claude Code in a worktree kept for the thread, in its auto mode (what that blocks is skipped, and Claude is told why), and brings its commits back onto the branch here. The branch's row then says review its diff, or answer Claude when it only talked. Enter opens the change by symbol with the conversation beside it: type a reply (shift-enter starts a new line where your terminal sends it as Claude Code wants, else ctrl-j or alt-enter, and a paste goes in whole), select lines in the diff first to say which ones you mean, and ctrl-f opens the same conversation in Claude Code there. A turn goes on if the laptop sleeps, nothing runs there between turns, so the workspace stops on its own, and `p` in `gb` pushes the branch as it would any other.

Claude's background runs have no shell, so a hostile MR's text cannot get Claude to run a command. A thread's Claude has one, on the workspace, where auto mode blocks what goes beyond what you asked.

## Music

While [cliamp](https://github.com/bjarneo/cliamp) 2 is playing, in its own pane or headless (`cliamp --daemon`), every otis screen shows it: its bars and what is playing along the rule over the footer, and a dim visualizer in the empty rows under the board, the lists and the panes, never behind text. otis reads cliamp's own socket, a process apart from the screen, so the screen only paints those rows as they come and keys answer as fast as they did before. `otis.musicBackground` picks what moves in the empty rows: `hills` (cliamp's ClassicPeak: thin bars green to red as they rise, their caps thrown up and falling), `river` (the beat as a line flowing left), `glow` (a light from below with the bass), `spectrogram` (every band's loudness flowing left, the bass at the bottom) or `off`; `otis.musicColors` their colors, `otis.musicFps` how often they move, and `otis.music off` takes it all off the screens. `M` on any screen opens the music screen (`otis-music`): the title, the bars big, where it is in the track and what plays next; `space` pauses, `n` and `p` skip, the arrows seek, `+` and `-` set the volume, and `/` searches YouTube through yt-dlp, `enter` playing what you pick and `a` adding it to what plays next, in your cliamp, started headless if none is running. Without cliamp nothing changes.

On macOS, cliamp 2.3.0's `--daemon` never tells the system it is the player, so AirPods and media keys go to Apple Music instead. cliamp in its own pane takes them, as its main branch does headless too.

## Uninstall

Remove the line `otis-setup` added to your shell config, and `~/.local/share/otis`. Caches are in `~/.cache/git-alias` and each repo's `.git/git-alias-cache`. Claude's run records are under `.git/gmr-claude`, `gmr-fix`, `gmr-watch`, `otis-verify` and `otis-thread`, and otis's worktrees are under `.claude/worktrees`, a thread's under `~/otis-threads` on its workspace.

## Hacking on it

`bin/otis-test` runs the tests, every area in `test/` at once, each in a throwaway repo of its own, no GitLab needed, including the pickers driven headless through their port; `otis-test symbols` runs one area, the one a change is in. Every screen is drawn by hand in zsh on `share/screen.zsh`: the board, a change by symbol, a run of Claude's, and every picker, which is a call to `git-fzf` (kept by that name; it opens `otis-pick`) with fzf's own `--bind` and `--preview` vocabulary, whose `key=label` list drives the footer, the `?` help and `--help`; a label the footer has one word for (`foot_keys` in `share/screen.zsh`) shows as that word, so `w=open it in the browser` reads `w web` on every screen. Adding a key takes one entry in that list and one `--bind`. A command a key runs (`transform`, `execute-silent`) runs in the background (`share/screen.zsh`'s `spawn`), the rest of its actions once it lands, so the cursor keeps moving and the footer spins with the key's label meanwhile; keys pressed during it wait their turn. A command's name and what it does are written once, in `share/commands.tsv`: `gg` renders it, `otis-help` prints one row of it, and the completions offer the names from it, so a new command is a row there and nothing else. `otis-config` is the only place that reads settings. Colors come from one palette, in `share/rowfmt.awk`, `share/otis.jq` and `share/palette.sh`, where red says a change of yours broke and nothing else (lines removed and untracked files are dim), and a count is written once (`gk_stat`, `gk_counts`: `+1,354 −514`); your shell loads the theme once when it starts, and every command inherits it. What otis brings to seam is in `share/seam`: a lazy references provider over tsgo's callers (git-callers) and what a file is (git-test-files); the shell line puts that directory on `SEAM_PATH`, so `seam --html`, `--score` and `--md` see the callers otis finds without anything written into your config. The gloss is asked for through `seam --gloss` and `symbols.md` is `seam --md`, so both have one owner.
