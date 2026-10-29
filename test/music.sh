#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- otis-music-feed ends with the screen it draws for, though what the screen
# started (a cliamp, a run) can go on reading the feed's output for good.
mkdir -p "$tmp/music" && printf '#!/bin/sh\nexit 0\n' > "$tmp/music/cliamp" && chmod +x "$tmp/music/cliamp" && : > "$tmp/music/places"
PATH=$tmp/music:$PATH zsh -fc 'otis-music-feed 24 "$1" | cat > /dev/null; :' - "$tmp/music/places" &
feedscreen=$!
sleep 0.5; kill $feedscreen; wait $feedscreen 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  pgrep -f "otis-music-feed 24 $tmp/music/places" >/dev/null || break; sleep 0.2
done
expect music/feed-ends-with-its-screen "$(pgrep -f "otis-music-feed 24 $tmp/music/places" | wc -l | tr -d ' ')" "0"

