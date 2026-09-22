# screen.zsh: what the screens drawn by hand share (otis-dash, otis-symbols,
# otis-agent): the terminal taken and given back, keys read, text measured
# and cut, and a selection in a pane copied. Sourced by a zsh -f script
# after it has made its state directory ($st) and loaded the theme; it
# calls screen_start once, then screen_on.
#
# A script may define at_quit, run as it leaves with the screen given back
# (otis-symbols prints what an accept hands back there).
zmodload zsh/system zsh/datetime zsh/zselect zsh/stat zsh/files zsh/mathfunc

# The palette, as the bytes the screen is drawn with.
e=$'\e'
R=$e'[0m' B=$e'[1m' UB=$e'[22m' IT=$e'[3m' UIT=$e'[23m'
A=$e"[${OTIS_T_ATTENTION}m" G=$e"[${OTIS_T_GOOD}m" X=$e"[${OTIS_T_BAD}m"
EL=$e"[${OTIS_T_ELSEWHERE}m" Y=$e"[${OTIS_T_YOURS}m" T=$e"[${OTIS_T_TEXT}m"
C=$e"[${OTIS_T_CONTEXT}m" F=$e"[${OTIS_T_FAINT}m"
BG=$e"[${OTIS_T_CODEBG:-48;5;236}m"
CODEBG=$e"[${OTIS_T_CODEBG}m"

# --- the terminal ------------------------------------------------------------------
# screen_start: the terminal by name for keys and frames ($tty); what a
# background job says goes to a file ($st/err), never over the screen, and
# none of them reads the terminal. Whatever ends it, the terminal comes back
# as it was: the traps are set here, at the file's level, since a trap on
# EXIT set inside a function fires when that function returns.
integer screen=0
trap 'quit 1' TERM INT
# A hangup is the terminal gone: nothing is written to it, since a write to a
# terminal that has gone can block for good, holding the port open with it.
trap 'screen=0; rm -rf -- $st; exit 1' HUP
trap '(( screen )) && screen_off; rm -rf -- $st' EXIT
screen_start() {
  exec {tty}<>/dev/tty
  exec 2>>$st/err </dev/null
  saved=$(stty -g <&$tty)
  # A resize wakes the loop at once: perl takes the signal and writes a
  # line to $winch, since a zsh script holds its traps until a loop that
  # never ends ends, so a WINCH trap would never run. perl goes when this
  # does; without perl, the loop asks for the size once a second.
  winch=
  command -v perl >/dev/null 2>&1 &&
    exec {winch}< <(perl -e 'my $p = getppid(); $| = 1; $SIG{WINCH} = sub { print "\n" }; sleep 1 while getppid() == $p' </dev/null 2>/dev/null)
}
# No line wrap while it is up, and the mouse as SGR reports: press, drag and
# release; shift held gives the terminal's own selection back, in most.
# ctrl-c and ctrl-z come in as keys (-isig), not signals: a signal's trap
# would never run (above), and a ctrl-c killed the scripts that opened the
# screen and left it running, raw, under the shell's prompt.
screen_on() { stty -icanon -echo -isig min 1 time 0 <&$tty; print -nu $tty -- $e'[?1049h'$e'[?25l'$e'[?7l'$e'[?1002h'$e'[?1006h'; shown_rows=(); screen=1; }
screen_off() { print -nu $tty -- $e'[?1006l'$e'[?1002l'$e'[?7h'$e'[?25h'$e'[?1049l'; stty $saved <&$tty; screen=0; }
quit() {
  (( screen )) && screen_off
  rm -rf -- $st
  (( $+functions[at_quit] )) && at_quit
  exit ${1:-0}
}
size() { local s; s=$(stty size <&$tty); H=${s% *} W=${s#* }; }
# orphaned: whatever opened this is gone, so it should go too rather than
# read keys under a shell's prompt. Cheap: ask it once a second.
orphaned() { ! kill -0 $PPID 2>/dev/null; }

# --- keys ----------------------------------------------------------------------------
# readkey: one key in REPLY: an escape sequence whole (an arrow, \e[B or
# \eOB; a mouse report, \e[<0;12;7M), a lone escape as esc, a character in
# more than one byte whole.
readkey() {
  local k c seq=
  sysread -s 1 -i $tty k || quit
  if [[ $k == $e ]] && zselect -t 2 -r $tty; then
    sysread -s 1 -i $tty seq
    if [[ $seq == [\[O] ]]; then
      while sysread -s 1 -i $tty c; do seq+=$c; [[ $c == [@-~] ]] && break; done
    fi
  elif [[ $k == [$'\xc0'-$'\xf7'] ]]; then
    # As many bytes after it as its lead byte says (110xxxxx one, 1110xxxx
    # two, 11110xxx three), and no more: reading on until a byte that is not
    # a continuation took the next character's lead byte with it, and a fast
    # paste of "é漢" came out "é�字". Each is waited for a moment, since a
    # paste can arrive split.
    local -i more=1 i
    [[ $k == [$'\xe0'-$'\xef'] ]] && more=2
    [[ $k == [$'\xf0'-$'\xf7'] ]] && more=3
    for (( i = 0; i < more; i++ )); do
      zselect -t 5 -r $tty && sysread -s 1 -i $tty c || break
      k+=$c
    done
  fi
  REPLY=$k$seq
}
# keyname <key>: its name as fzf spells it, for bindings.
keyname() {
  case $1 in
    $'\r'|$'\n') REPLY=enter ;; ' ') REPLY=space ;; $e) REPLY=esc ;;
    $e'[A'|$e'OA') REPLY=up ;; $e'[B'|$e'OB') REPLY=down ;;
    $e'[5~') REPLY=page-up ;; $e'[6~') REPLY=page-down ;;
    $'\x7f'|$'\b') REPLY=bspace ;;
    $'\x03') REPLY=ctrl-c ;; $'\x04') REPLY=ctrl-d ;; $'\x05') REPLY=ctrl-e ;; $'\x0b') REPLY=ctrl-k ;;
    $'\x0e') REPLY=ctrl-n ;; $'\x10') REPLY=ctrl-p ;; $'\x15') REPLY=ctrl-u ;; $'\x19') REPLY=ctrl-y ;;
    *) REPLY=$1 ;;
  esac
}

# --- text ----------------------------------------------------------------------------
# plain <text>: its colors, links and titles out.
plain() {
  REPLY=$1
  [[ $REPLY == *$e* ]] || return 0
  REPLY=${(S)REPLY//$e\[[0-9;:?]#[a-zA-Z]/}
  [[ $REPLY == *$e\]* ]] && REPLY=${(S)REPLY//$e\][^$'\a'$e]#($'\a'|$e\\)/}
  return 0
}
# vw <text>: its width on the screen, its colors aside.
vw() { plain "$1"; REPLY=${(m)#REPLY}; }
# fit <text> <width>: plain text cut to that many columns with an ellipsis.
fit() {
  local s=$1 w=$2
  (( w <= 0 )) && { REPLY=; return }
  if (( ${(m)#s} <= w )); then REPLY=$s; return; fi
  s=${s[1,w-1]}
  while (( ${(m)#s} > w - 1 )); do s=${s[1,-2]}; done
  REPLY=$s…
}
# cut <text> <width>: colored text cut to that many columns with an ellipsis,
# its colors kept, a character at a time; only a line too wide is.
cut() {
  local s=$1 out= run
  integer w=$2 n=0 k
  vw "$s"; (( REPLY <= w )) && { REPLY=$s; return }
  # A run of text and the escape after it at a time: whole while it fits,
  # then the part of it that does. A character at a time was most of what
  # drawing a long list cost.
  while [[ -n $s ]]; do
    if [[ $s == (#b)($e\[[0-9\;:?]#[a-zA-Z])* ]]; then out+=$match[1]; s=${s:${#match[1]}}; continue; fi
    run=${s%%$e*}; s=${s:${#run}}
    if (( n + ${(m)#run} <= w - 1 )); then out+=$run; (( n += ${(m)#run} )); continue; fi
    (( k = w - 1 - n ))
    (( k > 0 )) || break
    run=${run[1,k]}
    while (( ${(m)#run} > w - 1 - n )); do run=${run[1,-2]}; done
    out+=$run
    break
  done
  REPLY=$out$R…
}
# A line is built from pieces whose widths are known, so it can be padded to
# a column exactly: put <color> <text>, pad <column>.
line= used=0
put() { line+=$1$2; (( used += ${(m)#2} )); }
pad() { (( used < $1 )) && line+=${(l:$1-used:: :)} && used=$1; }
# wrap <text> <width>: plain text in lines of at most that width, broken at
# spaces, in reply.
wrap() {
  local s t
  reply=()
  for t in ${=1}; do
    if [[ -n $s ]] && (( ${(m)#s} + 1 + ${(m)#t} > $2 )); then reply+=("$s"); s=; fi
    s+=${s:+ }$t
  done
  [[ -n $s ]] && reply+=("$s")
}

# --- a selection in a pane --------------------------------------------------------------
# From line sa, column ca to line sb, column cb of the pane's lines ($P), and
# s1..s2 the same in reading order; sel 2 while the button is down, 1 once
# it is up.
integer sel=0 sa=0 ca=0 sb=0 cb=0 s1=0 c1=0 s2=0 c2=0
typeset -a P
ends() {
  if (( sa < sb || (sa == sb && ca <= cb) )); then s1=$sa c1=$ca s2=$sb c2=$cb
  else s1=$sb c1=$cb s2=$sa c2=$ca; fi
}
# gut <plain line>: where a diff's line has its code, after delta's gutter
# ("old ⋮ new │"), in REPLY; 0 for a line that is not one, -1 for a row on
# the gutter with no number (a peek's note, a thread), lit with the lines
# around it and copied with none of them.
gut() {
  local g=${1%%│*}
  if [[ $1 != *│* || $g != [[:space:]0-9⋮]# ]]; then REPLY=0
  elif [[ $g == *[0-9]* ]]; then REPLY=$(( ${#g} + 2 ))
  else REPLY=-1; fi
}
# selected <line>: the line with what is selected on it lit, its colors
# dropped for the moment it is; a diff's line whole, gutter and all.
selected() {
  local from=1 to t
  plain "$P[$1]"; t=$REPLY
  to=$#t
  gut "$t"
  if (( ! REPLY )); then
    (( $1 == s1 )) && from=$c1
    (( $1 == s2 )) && to=$c2
  fi
  REPLY=${t[1,from-1]}$e'[7m'${t[from,to]}$e'[27m'${t[to+1,-1]}
}
# copy <cont file> <offset>: the selection onto the clipboard, a flash saying
# so. A line the pane broke (the wrap's .cont, numbered as P less offset)
# goes back onto the one it came from; a diff's line is its code, whole,
# without the gutter.
copy() {
  local -A piece
  local l n out= t
  [[ -s $1 ]] && for l in ${(f)"$(<$1)"}; do piece[${l% *}]=${l#* }; done
  for (( n = s1; n <= s2; n++ )); do
    plain "$P[n]"; t=$REPLY
    gut "$t"
    (( REPLY < 0 )) && continue
    if (( REPLY )); then t=${t[REPLY,-1]}
    else
      (( n == s2 )) && t=${t[1,c2]}
      (( n == s1 )) && t=${t[c1,-1]}
    fi
    t=${t%%[[:space:]]#}
    if (( n > s1 )) && [[ -n ${piece[$(( n - $2 ))]} ]]; then out+=" "${t[piece[$(( n - $2 ))]+1,-1]}
    else out+=${out:+$'\n'}$t; fi
  done
  [[ -n $out ]] || return 1
  local -a got=("${(@f)out}")
  if printf '%s' "$out" | otis-copy 2>/dev/null; then flash="copied ${#got} line${${#got:#1}:+s}"
  else flash="no clipboard tool (pbcopy, wl-copy, xclip or xsel)"; fi
}

# --- a port ------------------------------------------------------------------------
# What fzf listened on, kept: anything that reaches it can send actions, so
# each screen has a key of its own that every request must carry (FZF_PORT
# and FZF_API_KEY, exported for what the screen runs: git-fzf-bg reloads a
# picker with rows built behind it, git-fzf-later hands it what GitLab
# said, git-cached-json says what it is waiting on). otis-test names the
# port and the key (OTIS_FZF_LISTEN, OTIS_FZF_API_KEY); nothing else should.
# port_open listens ($lfd, 0 when it could not); port_serve answers one
# request, which fzf hung up after: GET with what port_state puts in REPLY,
# as JSON; POST by handing port_post the body.
zmodload zsh/net/tcp
integer lfd=0
port_open() {
  local bytes c
  sysread -s 16 bytes </dev/urandom
  FZF_API_KEY=
  for c in ${(s::)bytes}; do FZF_API_KEY+=${(l:2::0:)$(( [##16] #c ))}; done
  [[ -n $OTIS_FZF_API_KEY ]] && FZF_API_KEY=$OTIS_FZF_API_KEY
  export FZF_API_KEY
  if [[ -n $OTIS_FZF_LISTEN ]]; then
    ztcp -l $OTIS_FZF_LISTEN 2>/dev/null && lfd=$REPLY FZF_PORT=$OTIS_FZF_LISTEN
  else
    repeat 20; do
      FZF_PORT=$(( 40000 + RANDOM % 20000 ))
      ztcp -l $FZF_PORT 2>/dev/null && { lfd=$REPLY; break }
    done
  fi
  if (( lfd )); then export FZF_PORT; else unset FZF_PORT; fi
}
# json <text>: as a JSON string's inside.
json() {
  local s=$1 c
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$e/\\u001b}
  for c in $'\x01' $'\x02' $'\x03' $'\x04' $'\x05' $'\x06' $'\x07' $'\x08' $'\x0b' $'\x0c' $'\x0e' $'\x0f' $'\x10' $'\x11' $'\x12' $'\x13' $'\x14' $'\x15' $'\x16' $'\x17' $'\x18' $'\x19' $'\x1a' $'\x1c' $'\x1d' $'\x1e' $'\x1f'; do
    [[ $s == *$c* ]] && s=${s//$c/\\u00${(l:2::0:)$(( [##16] #c ))}}
  done
  REPLY=$s
}
port_serve() {
  setopt localoptions nomultibyte
  local cfd req= chunk hdr= body= answer='200 OK' out=
  integer len=-1 told=0
  float till
  ztcp -a -t $lfd 2>/dev/null || return; cfd=$REPLY
  (( till = EPOCHREALTIME + 2 ))
  while (( EPOCHREALTIME < till )); do
    zselect -t 20 -r $cfd || continue
    sysread -s 65536 -i $cfd chunk || break
    req+=$chunk
    [[ $req == *$'\r\n\r\n'* ]] || continue
    hdr=${req%%$'\r\n\r\n'*} body=${req#*$'\r\n\r\n'}
    (( len < 0 )) && { len=0; [[ $hdr == (#bi)*content-length:[[:space:]]#([0-9]##)* ]] && len=$match[1]; }
    (( ! told )) && [[ $hdr == (#i)*expect:[[:space:]]#100-continue* ]] && { print -rnu $cfd -- $'HTTP/1.1 100 Continue\r\n\r\n'; told=1; }
    (( ${#body} >= len )) && break
  done
  if [[ -z $hdr ]]; then answer='400 Bad Request'
  elif [[ $hdr != (#i)*x-api-key:[[:space:]]#$FZF_API_KEY* ]]; then answer='401 Unauthorized'
  elif [[ ${hdr%% *} == GET ]]; then port_state; out=$REPLY
  fi
  print -rnu $cfd -- "HTTP/1.1 $answer"$'\r\n'"Content-Type: application/json"$'\r\n'"Connection: close"$'\r\n'"Content-Length: ${#out}"$'\r\n\r\n'"$out"
  # The client hangs up first, so its end of the connection is the one left
  # waiting out TCP's TIME_WAIT: ztcp cannot reuse a port that has one, and
  # a screen opened next on the same port (otis-test's) could not listen.
  (( till = EPOCHREALTIME + 0.3 ))
  while (( EPOCHREALTIME < till )) && zselect -t 5 -r $cfd; do sysread -s 4096 -i $cfd chunk || break; done
  ztcp -c $cfd 2>/dev/null
  # A POST's actions after its answer: an abort ends the screen, and with it
  # a connection still open on this end.
  if [[ $answer == 200* && ${hdr%% *} == POST ]]; then
    setopt localoptions multibyte
    port_post "$body"
  fi
}
