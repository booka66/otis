#!/bin/sh
# install.sh: otis from GitHub, its newest release, into ~/.local/share/otis
# (OTIS_DIR elsewhere; OTIS_VERSION=0.7.1 a release of your choosing), then
# otis-setup, which checks what otis needs, offers to install what is
# missing, and adds the one line your shell needs:
#
#   curl -fsSL https://raw.githubusercontent.com/booka66/otis/main/install.sh | sh
#
# With --update (otis-update) it only brings the files up to date: the line
# in your shell sources them where they are, so there is nothing to set up.
# The release is unpacked beside the one there and swapped in, so a shell
# running otis never finds it half written. VERSION in it says which it is.
set -eu
repo=https://github.com/booka66/otis
dest=${OTIS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/otis}
update=
[ "${1:-}" = --update ] && update=1

die() { printf 'otis: %s\n' "$1" >&2; exit 1; }
for c in curl tar; do command -v "$c" >/dev/null 2>&1 || die "needs $c"; done

# The newest release is the highest vX.Y.Z tag: tags alone, no GitHub
# release to publish. Asked of GitHub's API over curl, since a Mac that has
# never had the Command Line Tools has only a git that offers to install
# them; git only when the API says nothing (60 asks an hour an address).
newest() { sed -n "s|$1|\\1|p" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }
version=${OTIS_VERSION:-$(curl -fsSL "https://api.github.com/repos/booka66/otis/tags?per_page=100" 2>/dev/null |
  newest '.*"name": *"v\([0-9]*\.[0-9]*\.[0-9]*\)".*')}
[ -n "$version" ] || version=$(git ls-remote --tags --refs "$repo" 'v*' 2>/dev/null |
  newest '.*refs/tags/v\([0-9]*\.[0-9]*\.[0-9]*\)$')
[ -n "$version" ] || die "could not find a release at $repo"

have=
if [ -e "$dest" ]; then
  [ -f "$dest/VERSION" ] || die "$dest is there and was not put there by this; move it, or set OTIS_DIR"
  have=$(cat "$dest/VERSION")
fi

if [ "$have" = "$version" ]; then
  printf 'otis %s is the newest, and is in %s\n' "$version" "$dest"
else
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp -d "$(dirname "$dest")/.otis.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$repo/archive/refs/tags/v$version.tar.gz" | tar -xzf - -C "$tmp" ||
    die "could not download otis $version"
  new=$tmp/otis-$version
  [ -x "$new/bin/otis-setup" ] || die "otis $version did not unpack as expected"
  rm -rf "$new/Formula"
  printf '%s\n' "$version" > "$new/VERSION"
  [ -e "$dest" ] && mv "$dest" "$tmp/old"
  mv "$new" "$dest"
  rm -rf "$tmp"
  trap - EXIT
  if [ -n "$have" ]; then printf 'otis %s -> %s, in %s\n' "$have" "$version" "$dest"
  else printf 'otis %s is in %s\n' "$version" "$dest"; fi
fi

[ -n "$update" ] && { [ "$have" = "$version" ] || printf 'Open a new terminal for it.\n'; exit 0; }
printf '\n'
exec "$dest/bin/otis-setup"
