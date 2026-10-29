#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- otis-node-modules: a worktree's node_modules mirrored from main's: the
# repo's own packages as the same relative links, so they resolve here, the
# install's content through one link to main's, scopes walked, files linked,
# and a mirror only made where there is none and never over a real install;
# then main's own, kept up with the checkout and, with otis.install, the lockfile.
mkdir -p "$tmp/nm" && ( cd "$tmp/nm" && git init -q -b main . && git config user.email t@t && git config user.name t &&
  mkdir -p pkg/one node_modules/.content/one_1.0/files node_modules/@scope node_modules/.bin &&
  printf 'x\n' > pkg/one/index.ts && printf 'node_modules\n' > .gitignore && git add -A && git commit -qm base &&
  ln -s ../../pkg/one node_modules/@scope/one && ln -s .content/one_1.0/files node_modules/third &&
  ln -s ../.content/one_1.0/files/bin node_modules/.bin/one && printf '{}\n' > node_modules/.state.json &&
  git worktree add -q "$tmp/nm-wt" -b wt >/dev/null 2>&1 ) &&
  otis-node-modules "$tmp/nm-wt"
expect nm/repo-package "$(readlink "$tmp/nm-wt/node_modules/@scope/one")" "../../pkg/one"
expect nm/resolves-here "$(cd "$tmp/nm-wt/node_modules/@scope/one" && pwd -P)" "$(cd "$tmp/nm-wt/pkg/one" && pwd -P)"
expect nm/third-party "$(readlink "$tmp/nm-wt/node_modules/third")" ".content/one_1.0/files"
expect nm/content-is-mains "$(cd "$tmp/nm-wt/node_modules/.content" && pwd -P)" "$(cd "$tmp/nm/node_modules/.content" && pwd -P)"
expect nm/bin "$(readlink "$tmp/nm-wt/node_modules/.bin/one")" "../.content/one_1.0/files/bin"
expect nm/file "$(readlink "$tmp/nm-wt/node_modules/.state.json")" "$tmp/nm/node_modules/.state.json"
expect nm/marked "$([ -f "$tmp/nm-wt/node_modules/.otis-mirror" ] && echo mirror)" "mirror"
rm -rf "$tmp/nm-wt/node_modules" && mkdir "$tmp/nm-wt/node_modules" && printf 'mine\n' > "$tmp/nm-wt/node_modules/real"
otis-node-modules "$tmp/nm-wt"
expect nm/real-install-kept "$(ls "$tmp/nm-wt/node_modules")" "real"
# A link to main's whole node_modules has the repo's packages resolve to
# main's source, so it gives way to a mirror; main's tree is left as it was.
rm -rf "$tmp/nm-wt/node_modules" && ln -s "$tmp/nm/node_modules" "$tmp/nm-wt/node_modules"
otis-node-modules "$tmp/nm-wt"
expect nm/main-link-mirrored "$(cd "$tmp/nm-wt/node_modules/@scope/one" && pwd -P):$(ls -a "$tmp/nm/node_modules" | grep -c otis-mirror)" "$(cd "$tmp/nm-wt/pkg/one" && pwd -P):0"
# A run killed partway leaves nothing behind, so the next one mirrors afresh
# instead of taking half a mirror for an install of your own.
mkdir -p "$tmp/nmkill" && printf '#!/bin/sh\nkill -TERM $PPID; sleep 1\n' > "$tmp/nmkill/cp" && chmod +x "$tmp/nmkill/cp"
rm -rf "$tmp/nm-wt/node_modules"
PATH=$tmp/nmkill:$PATH OTIS_CACHE_ROOT=$tmp/nmk-cache otis-node-modules "$tmp/nm-wt"
expect nm/killed-leaves-none "$(ls -d "$tmp/nm-wt/node_modules" "$tmp/nmk-cache/node-modules/mirror."* 2>/dev/null)" ""
OTIS_CACHE_ROOT=$tmp/nmk-cache otis-node-modules "$tmp/nm-wt"
expect nm/after-kill "$(readlink "$tmp/nm-wt/node_modules/@scope/one"):$(ls "$tmp/nmk-cache/node-modules")" "../../pkg/one:"
# Main's own install: a package of the repo it never saw gets its link, and
# nothing else is touched.
( cd "$tmp/nm" && mkdir -p pkg/two && printf '{ "name": "@scope/two" }\n' > pkg/two/package.json && git add -A && git commit -qm two )
expect nm/main-linked "$(otis-node-modules "$tmp/nm"; ls "$tmp/nm/node_modules" | tr '\n' ' '):$(readlink "$tmp/nm/node_modules/@scope/two")" "@scope third :../../pkg/two"
# A lockfile newer than the install: behind, and nothing run without otis.install.
nmc=$tmp/nm-cache
printf 'lock\n' > "$tmp/nm/yarn.lock" && touch -t 202001010000 "$tmp/nm/node_modules"
expect nm/behind "$(OTIS_CACHE_ROOT=$nmc otis-node-modules --state "$tmp/nm"):$(OTIS_CACHE_ROOT=$nmc otis-node-modules "$tmp/nm"; ls "$nmc" 2>/dev/null)" "behind:"
# With it, the install runs at main in the background; --wait sees it out,
# and what it wrote into node_modules is the mark the lockfile is measured by.
# The links otis made go before it runs, since an installer that makes them
# itself may refuse to link over one; the next run makes any it left again.
git -C "$tmp/nm" config otis.install 'sleep 1; ls node_modules/@scope > .seen; printf "{}" > node_modules/.yarn-state.yml'
OTIS_CACHE_ROOT=$nmc otis-node-modules "$tmp/nm"
expect nm/installing "$(OTIS_CACHE_ROOT=$nmc otis-node-modules --state "$tmp/nm")" "installing"
OTIS_CACHE_ROOT=$nmc otis-node-modules --wait "$tmp/nm"
expect nm/installed "$(cat "$tmp/nm/node_modules/.yarn-state.yml"):$(OTIS_CACHE_ROOT=$nmc otis-node-modules --state "$tmp/nm")" "{}:"
expect nm/unlinked-for-install "$(cat "$tmp/nm/.seen" | tr '\n' ' ')" "one "
expect nm/relinked-after "$(OTIS_CACHE_ROOT=$nmc otis-node-modules "$tmp/nm"; readlink "$tmp/nm/node_modules/@scope/two")" "../../pkg/two"
# Once a day: the lockfile moving again does not run it again today.
touch -t 202001010000 "$tmp/nm/node_modules/.yarn-state.yml" && printf 'lock2\n' > "$tmp/nm/yarn.lock"
OTIS_CACHE_ROOT=$nmc otis-node-modules --wait "$tmp/nm"
expect nm/once-a-day "$(cat "$tmp/nm/node_modules/.yarn-state.yml"):$(OTIS_CACHE_ROOT=$nmc otis-node-modules --state "$tmp/nm")" "{}:behind"
# Not while its tool is busy with a build of yours.
mkdir -p "$tmp/nmbin" && printf '#!/bin/sh\nsleep 4\n' > "$tmp/nmbin/bazel" && chmod +x "$tmp/nmbin/bazel"
"$tmp/nmbin/bazel" build //x & nmbusy=$!
rm -f "$nmc/node-modules/install.at"; git -C "$tmp/nm" config otis.install 'bazel run install'
OTIS_CACHE_ROOT=$nmc otis-node-modules --wait "$tmp/nm"
expect nm/busy "$([ -e "$nmc/node-modules/install.at" ] && echo ran || echo held)" "held"
kill $nmbusy 2>/dev/null; wait $nmbusy 2>/dev/null
# A failed install is said so, with its first error, until the next attempt.
git -C "$tmp/nm" config otis.install 'echo "error: no network"; exit 1'
OTIS_CACHE_ROOT=$nmc otis-node-modules --wait "$tmp/nm"
expect nm/failed "$(OTIS_CACHE_ROOT=$nmc otis-node-modules --state "$tmp/nm")" "failed: error: no network"
# Two runs at once (the symbol picker's and git-callers' both start one): a
# link the other made between this one's look and its ln is not followed into
# the package's own directory, where it would be an untracked file. A mkdir
# that makes the link stands in for the other run. And what a mirror linked
# is its own record, not main's.
OTIS_CACHE_ROOT=$nmc otis-node-modules "$tmp/nm"; nmstamp=$(cat "$tmp/nm/node_modules/.otis-workspace")
( cd "$tmp/nm-wt" && mkdir -p pkg/three && printf '{ "name": "@scope/three" }\n' > pkg/three/package.json && git add -A && git commit -qm three )
mkdir -p "$tmp/nmrace" && printf '#!/bin/sh\n/bin/mkdir "$@"; for a; do :; done\ncase $a in */nm-wt/node_modules/@scope) ln -s ../../pkg/three "$a/three" ;; esac\nexit 0\n' > "$tmp/nmrace/mkdir" && chmod +x "$tmp/nmrace/mkdir"
PATH=$tmp/nmrace:$PATH OTIS_CACHE_ROOT=$nmc otis-node-modules "$tmp/nm-wt"
expect nm/no-link-inside-package "$(ls "$tmp/nm-wt/pkg/three"):$(git -C "$tmp/nm-wt" status --porcelain)" "package.json:"
expect nm/own-record "$([ -f "$tmp/nm-wt/node_modules/.otis-workspace" ] && [ ! -L "$tmp/nm-wt/node_modules/.otis-workspace" ] && echo own):$([ "$(cat "$tmp/nm/node_modules/.otis-workspace")" = "$nmstamp" ] && echo "main's kept")" "own:main's kept"
git -C "$tmp/nm" worktree remove --force "$tmp/nm-wt" >/dev/null 2>&1
