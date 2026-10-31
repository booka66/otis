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


# --- M opens the music from every screen and comes back to it. The stand-in
# plays nothing and says it was opened; back, the screen draws itself again.
printf '#!/bin/sh\necho opened >> "%s"\n' "$tmp/music/opened" > "$tmp/music/otis-music" && chmod +x "$tmp/music/otis-music"
press_M() {
  : > "$tmp/music/opened"
  PATH=$tmp/music:$PATH TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; setopt extendedglob
    zpty -b s "stty rows 30 cols 150; $1"
    upto() { for _ in {1..150}; do while zpty -rt s buf; do out+=$buf; done; [[ ${out//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/} == *$1* ]] && return 0; sleep 0.1; done; return 1 }
    upto $2 || print -r -- "never up"
    zpty -wn s M
    for _ in {1..80}; do [[ -s $3 ]] && break; while zpty -rt s buf; do :; done; sleep 0.1; done
    out=; upto $2 && print -r -- back
    zpty -wn s q; zpty -wn s q; sleep 0.3; zpty -d s 2>/dev/null' - "$1" "$2" "$tmp/music/opened"
}
rows="--bind 'start:reload(printf \"alpha\\\\nbravo\\\\n\")'"
expect music/M-on-the-board "$(press_M otis-dash "? keys")|$(cat "$tmp/music/opened")" "back|opened"
expect music/M-on-a-picker "$(press_M "git-fzf 'x ' '' $rows" alpha)|$(cat "$tmp/music/opened")" "back|opened"
expect music/M-on-symbols "$(press_M "otis-symbols 'x ' '' $rows" "reading the change")|$(cat "$tmp/music/opened")" "back|opened"
run=$tmp/music/run; mkdir -p "$run"; printf 'Verifying m\n' > "$run/title"; printf '{"criteria":[]}\n' > "$run/plan.json"
expect music/M-on-a-run "$(press_M "otis-agent $run" "Verifying m")|$(cat "$tmp/music/opened")" "back|opened"
# Typed in a search it is a letter, and a picker's own M would come first.
if picker_open "PATH=$tmp/music:\$PATH git-fzf 'x ' '' $rows"; then
  picker_rows > /dev/null; : > "$tmp/music/opened"; picker_key /; picker_key M
  expect music/M-in-a-search-is-a-letter "$(picker_state | jq -r .query)|$(cat "$tmp/music/opened")" "M|"
  picker_close
else
  expect music/picker-opens "no picker on port $port" "opened"
fi
# On YouTube's results, opened from the music screen, M goes back to it rather
# than opening another: one q then leaves. yt-dlp and cliamp are stand-ins.
mkdir -p "$tmp/yt" && printf '#!/bin/sh\nexit 0\n' > "$tmp/yt/cliamp"
printf '#!/bin/sh\nprintf "Youtube\\tabc\\t1:00\\tDJ\\tA set\\n"\n' > "$tmp/yt/yt-dlp"; chmod +x "$tmp/yt/"*
expect music/M-on-its-results "$(PATH=$tmp/yt:$PATH TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; setopt extendedglob
  zpty -b s "stty rows 30 cols 150; otis-music"
  upto() { for _ in {1..100}; do while zpty -rt s buf; do out+=$buf; done; [[ ${out//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/} == *$1* ]] && return 0; sleep 0.1; done; return 1 }
  upto "searches YouTube"; sleep 0.3; zpty -wn s /; out=; upto "search YouTube"; sleep 0.3; zpty -wn s $'"'"'set\r'"'"'; out=; upto "A set"; sleep 0.3
  out=; zpty -wn s M; upto "searches YouTube" && print -n back; sleep 0.5; zpty -wn s q
  for _ in {1..30}; do while zpty -rt s buf; do :; done; zpty -t s || { print -n " left"; break }; sleep 0.1; done
  zpty -d s 2>/dev/null')" "back left"

# A pick YouTube refuses says why, where the screen said "starting it…" and went quiet.
# The error is cliamp's own shape around yt-dlp's stderr; the stand-in cliamp plays nothing.
mkdir -p "$tmp/no"
zsh -fc 'zmodload zsh/net/socket; zsocket -l "$1"' - "$tmp/no/cliamp.sock" 2>/dev/null
cat > "$tmp/no/cliamp" <<'EOF'
#!/bin/sh
[ "$1" = remote ] || exit 0
[ -n "$REFUSAL" ] && printf "job failed (internal): internal (yt-dlp: ERROR: [youtube] abc: %s)\n" "$REFUSAL" >&2 ||
  printf "job failed (internal): internal (yt-dlp: WARNING: [youtube] abc: HTTP Error 429\nERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser)\n" >&2
exit 1
EOF
chmod +x "$tmp/no/cliamp"
expect music/refusal-is-a-line "$(PATH=$tmp/no:$PATH CLIAMP_CONFIG_DIR=$tmp/no otis-music --play x 2>&1 >/dev/null; echo "exit $?")" "YouTube asked if this machine is a bot and would not play it. yt-dlp can use your browser's sign-in: put --cookies-from-browser <browser> in ~/.config/yt-dlp/config.
exit 1"
expect music/other-refusal-is-its-reason "$(PATH=$tmp/no:$PATH CLIAMP_CONFIG_DIR=$tmp/no REFUSAL='Video unavailable' otis-music --queue x 2>&1 >/dev/null)" "That would not play: Video unavailable"
printf '#!/bin/sh\nprintf "Youtube\\tabc\\t1:00\\tDJ\\tA set\\n"\n' > "$tmp/no/yt-dlp"; chmod +x "$tmp/no/yt-dlp"
expect music/refused-pick-says-why "$(PATH=$tmp/no:$PATH CLIAMP_CONFIG_DIR=$tmp/no TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; setopt extendedglob
  zpty -b s "stty rows 30 cols 150; otis-music"
  upto() { for _ in {1..100}; do while zpty -rt s buf; do out+=$buf; done; [[ ${out//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/} == *$1* ]] && return 0; sleep 0.1; done; return 1 }
  upto "searches YouTube"; sleep 0.3; zpty -wn s /; out=; upto "search YouTube"; sleep 0.3; zpty -wn s $'"'"'set\r'"'"'; out=; upto "A set"; sleep 0.3
  out=; zpty -wn s $'"'"'\r'"'"'; upto "asked if this machine is a bot" && print -n said; out=
  zpty -wn s s; sleep 0.5; while zpty -rt s buf; do out+=$buf; done; [[ $out == *$'"'"'\e[6;1H\e[0m\e[K'"'"'* ]] && print -n " cleared"
  zpty -wn s q; sleep 0.2; zpty -d s 2>/dev/null')" "said cleared"

# Holding an arrow moves the clock at once and tells the player once, where you stopped: each seek restarts a stream.
mkdir -p "$tmp/seek"; : > "$tmp/seek/calls"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$tmp/seek/calls" > "$tmp/seek/cliamp"
printf '#!/bin/sh\nwhile :; do printf "s\\tpaused\\t100\\t1000\\tA set\\t\\t0\\t1\\t0\\tfalse\\nf\\n"; sleep 0.1; done\n' > "$tmp/seek/otis-music-feed"; chmod +x "$tmp/seek/"*
expect music/seek-once-where-you-stop "$(PATH=$tmp/seek:$PATH TERM=xterm-256color zsh -fc 'zmodload zsh/zpty; setopt extendedglob
  zpty -b s "stty rows 30 cols 150; otis-music"
  upto() { for _ in {1..60}; do while zpty -rt s buf; do out+=$buf; done; [[ ${out//$'"'"'\e'"'"'\[[0-9;?]#[A-Za-z]/} == *$1* ]] && return 0; sleep 0.05; done; return 1 }
  upto "1:40"; out=
  for _ in 1 2 3 4 5; do zpty -wn s l; done
  upto "2:30" && print -n "clock moved, $(wc -l < $1 | tr -d " ") sent; "
  sleep 0.8; while zpty -rt s buf; do :; done; zpty -wn s q; sleep 0.2; zpty -d s 2>/dev/null' - "$tmp/seek/calls")$(grep seek "$tmp/seek/calls")" 'clock moved, 0 sent; remote call seek.absolute --params {"value":150}'
