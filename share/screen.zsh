# screen.zsh: what the screens drawn by hand share (otis-dash, otis-symbols,
# otis-agent): the terminal taken and given back, keys read, text measured
# and cut, and a selection in a pane copied. Sourced by a zsh -f script
# after it has made its state directory ($st) and loaded the theme; it
# calls screen_start once, then screen_on.
#
# A script may define at_quit, run as it leaves with the screen given back
# (otis-symbols prints what an accept hands back there), and at_leave, run
# before that while $st is still there (what it showed, kept for next time).
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
# none of them reads the terminal; nor holds its stdout (>/dev/null on each
# job started with &!): a caller reads what a screen hands back with $(...),
# which waits for every process holding it, and a preview still rendering
# kept the caller's screen frozen for seconds after this one had gone.
# Whatever ends it, the terminal comes back
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
#
# Screens hand over without the terminal under them showing between: under
# the otis function (OTIS_ALT, a file it names), a screen that goes back (q,
# esc: quit 130) or hands over (the dashboard's m, b, ...) leaves the
# alternate screen up with its last frame on it, and says so in that file.
# The next screen, the dashboard again or the picker whose execute opened
# this one, takes it over rather than entering it again, and draws over it
# whole. The otis function leaves it when it is done. An accept leaves as
# ever, since what it hands back may print.
#
# screen_on back: after run_tty. A command that left the frame up (it only
# asked, otis-popup) finds it drawn again in place, every line rewritten
# over what is there; a clear first would blink. One that left the alternate
# screen (an editor) finds it entered and drawn whole, as ever.
#
# screen_on over: after a box the screen put up itself (otis-popup), which
# never leaves the alternate screen, so the terminal is not asked: reading
# its answer took any key typed in that moment with it.
screen_on() {
  local alt=$e'[?1049h'
  loader_stop
  [[ -n $OTIS_ALT && -e $OTIS_ALT ]] && { rm -f -- $OTIS_ALT; alt=; }
  stty -icanon -echo -isig min 1 time 0 <&$tty
  shown_rows=()
  if [[ $1 == over ]] || { [[ $1 == back ]] && on_alt }; then
    # A line no frame has, a screen's worth: every line differs, none is
    # skipped, and the screen is not taken as empty (which clears it).
    alt=
    repeat $H shown_rows+=($'\0')
    shown_pane=("${shown_rows[@]}")
  fi
  print -nu $tty -- $alt$e'[?25l'$e'[?7l'$e'[?1002h'$e'[?1006h'; screen=1
}
# on_alt: the terminal says it is still on the alternate screen (DECRQM); one
# that does not answer in a tenth of a second is taken as not.
on_alt() {
  local r= c
  print -nu $tty -- $e'[?1049$p'
  while zselect -t 10 -r $tty && sysread -s 1 -i $tty c; do r+=$c; [[ $c == y ]] && break; done
  [[ $r == *'?1049;1$y' ]]
}
# screen_off [keep]: keep, the alternate screen left up (above).
screen_off() {
  if [[ -n $1 && -n $OTIS_ALT ]]; then
    print -nu $tty -- $e'[?1006l'$e'[?1002l'$e'[?7h'; : > $OTIS_ALT
  else
    print -nu $tty -- $e'[?1006l'$e'[?1002l'$e'[?7h'$e'[?25h'$e'[?1049l'
  fi
  stty $saved <&$tty; screen=0
}
# kitty_split <preview> <file>: a preview that holds a kitty image (kitten
# icat --unicode-placeholder), taken apart for a pane: the image itself into
# <file>.gfx, sent to the terminal when the pane shows it, and the lines it
# shows through into <file>.tmp as they are. icat has cut them to the pane,
# and a wrap would drop the image's escape and count each placeholder's
# marks as letters.
kitty_split() {
  print -rn -- $1 | perl -0777 -ne 'print $& while /\e_G.*?\e\\/sg' > $2.gfx
  # icat also moves the cursor to where it would place the image on the
  # screen (save, CUP, restore): in a pane that is somewhere else entirely,
  # so of the rest only colors and the placeholders are kept. The image's
  # color, which says which image a placeholder is, is set once and left to
  # carry on; the pane draws each line on its own, so each line gets it.
  print -r -- $1 | perl -0777 -pe 's/\e_G.*?\e\\//sg; s/\eP.*?\e\\//sg; s/\e[78]//g; s/\e\[[0-9;]*[A-HJKf]//g; s/\r//g' |
    perl -ne 'if (/(\e\[38[:;][0-9:;]*m)/) { $c = $1 } elsif ($c && /\x{F4}\x{8E}\x{BB}\x{AE}/) { $_ = $c . $_ } print' > $2.tmp
}
# run_tty <command> [<shell>]: a command on the terminal, the screen's frame
# left up under it rather than the terminal's own screen, so what the command
# asks (otis-popup, git-confirm) goes in a box over the frame: the frame is
# drawn whole into a file for it to draw the box over (OTIS_FRAME). Whatever
# else the command prints goes over the frame from its last line, and one
# that takes the whole screen (an editor, a pager, another screen) takes it
# as ever. The screen is back, drawn whole, when it is done. INT is ignored
# meanwhile so ctrl-c belongs to the command: the screen's trap would end the
# whole screen, and a command that signals INT as it starts
# (terminal-browser) would only blip and never take the pane.
#
# Until the command takes the terminal, the footer spins with what it is
# for (loader): the label of the key that ran it (bykey), else the flash
# it left, else "opening".
run_tty() {
  screen_hold $st/frame
  trap '' INT
  loader "${${bykey:-${flash%…}}:-opening}" >/dev/null &!
  local lp=$!
  # less with no way to a shell (LESSSECURE): a stray ! in a pager left a
  # shell under the screen, and whatever was run from it ran inside this
  # screen, over its frame, on its /dev/tty (swoop waited there for a key).
  LESSSECURE=1 OTIS_LOADER=$lp OTIS_FRAME=$st/frame ${=2:-zsh -f} -c "$1" <&$tty >&$tty 2>&1
  kill $lp 2>/dev/null
  trap 'quit 1' INT
  rm -f -- $st/frame
  screen_on back
}
# loader <label>: the footer spinning with the label, under a command that
# is getting going, so a second's start never looks like a screen that has
# stuck. It stops when the command takes the terminal: a screen or a box
# that asks stops it as it does (loader_stop), and anything else that reads
# keys (an editor, a pager, a question) sets the terminal raw, which it
# looks for between frames. run_tty stops it when the command is done.
loader() {
  local was=$(stty -g <&$tty 2>/dev/null)
  integer n=0
  zselect -t 15
  while kill -0 $$ 2>/dev/null && [[ $(stty -g <&$tty 2>/dev/null) == $was ]]; do
    print -nu $tty -- $e'7'$e"[$H;1H"$e'[2K  '$A${spin[n % $#spin + 1]}$R" "$T$1$R$C"…"$R$e'8'
    (( n++ ))
    zselect -t 10
  done
}
loader_stop() { [[ -n $OTIS_LOADER ]] && kill $OTIS_LOADER 2>/dev/null; unset OTIS_LOADER; }
# screen_hold <file>: the frame drawn whole into the file and left up, the
# terminal as the screen found it otherwise, for a command to run over.
screen_hold() {
  local fd=$tty
  exec {tty}>$1
  shown_rows=() shown_pane=(); draw
  exec {tty}>&-; tty=$fd
  print -nu $tty -- $e'[?1006l'$e'[?1002l'$e'[?7h'$e"[$H;1H"
  stty $saved <&$tty; screen=0
}
# A screen that goes back to a command run over another's frame (git-verify
# asking after its run's screen says r) leaves its own frame up in that one's
# place, so what the command asks next goes over what you were looking at.
quit() {
  if (( screen )); then
    if [[ -n $OTIS_FRAME && -e $OTIS_FRAME ]] && (( $#shown_rows )); then screen_hold $OTIS_FRAME
    elif (( ${1:-0} == 130 )); then screen_off keep; else screen_off; fi
  fi
  (( $+functions[at_leave] )) && at_leave
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
# The pane's lines (P) never run past its edge: with no line wrap, the
# terminal writes what is left of a line over its last column, and "pushed"
# came out "pushd".
# panewrap <width>: each line of P in that width, broken at spaces, colors
# kept, what runs on under the line's own text (a key's, under its words;
# the rest, two in from where it starts; a key is the words before the
# first gap of two spaces). For what a screen writes itself,
# its ? keys and glyphs.
panewrap() {
  local -a out words
  local l at wd
  integer w=$1 n ind wl lead first
  for l in "${P[@]}"; do
    vw "$l"; (( REPLY <= w )) && { out+=("$l"); continue; }
    plain "$l"
    if [[ $REPLY == (#b)([[:space:]]#[^[:space:]]##([[:space:]][^[:space:]]##)#[[:space:]][[:space:]]##)[^[:space:]]* ]]; then ind=${#match[1]}; else ind=$(( ${#${REPLY%%[^ ]*}} + 2 )); fi
    lead=${#${REPLY%%[^[:space:]]*}}
    at=${(l:lead:: :)} n=$lead first=1 words=("${(@s: :)${l#${(l:lead:: :)}}}")
    for wd in "${words[@]}"; do
      vw "$wd"; wl=$REPLY
      if (( ! first && n + 1 + wl > w )); then out+=("$at$R"); at=${(l:ind:: :)}$wd; n=$(( ind + wl ))
      else (( first )) || { at+=" "; (( n++ )); }; at+=$wd; (( n += wl )); fi
      first=0
    done
    out+=("$at")
  done
  P=("${out[@]}")
}
# clip <width>: each line of P cut to that width with an ellipsis. For a
# preview drawn at another width (the last screen's, kept), shown until this
# width's lands.
clip() { integer i; for (( i = 1; i <= $#P; i++ )); do cut "$P[i]" $1; P[i]=$REPLY; done; }
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
# whole <text> <width>: the text in lines of at most that width, in reply:
# broken at spaces, a word wider than a line (a long branch name) broken
# where the line ends. Nothing on the board or in a box (otis-popup) is cut
# short: what does not fit on a line goes on under it.
whole() {
  local t s=
  integer w=$2
  reply=()
  (( w < 8 )) && w=8
  for t in ${=1}; do
    while (( ${(m)#t} > w )); do
      [[ -n $s ]] && { reply+=("$s"); s=; }
      reply+=("${t[1,w]}"); t=${t[w+1,-1]}
    done
    if [[ -n $s ]] && (( ${(m)#s} + 1 + ${(m)#t} > w )); then reply+=("$s"); s=; fi
    s+=${s:+ }$t
  done
  [[ -n $s ]] && reply+=("$s")
  (( $#reply )) || reply=("")
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

# --- what it showed last -----------------------------------------------------------
# A screen opens on what it showed when it last closed, rather than empty
# until its list has run: the rows at $memo, their previews in $memo.pv.
# Previews are kept as gen 0, so the pane shows one (the newest of any gen)
# until the first that is drawn from the fresh rows lands.
# memo_keep <preview files...>: those kept, each under its name at gen 0.
memo_keep() {
  local f n
  mkdir -p $memo.pv.new 2>/dev/null || return
  for f; do
    n=${f:t}; n=${n%.*}.0
    print -rn -- "$(<$f)" > $memo.pv.new/$n
    [[ -e $f.cont ]] && print -rn -- "$(<$f.cont)" > $memo.pv.new/$n.cont
    [[ -e $f.gfx ]] && print -rn -- "$(<$f.gfx)" > $memo.pv.new/$n.gfx
  done
  rm -rf -- $memo.pv; mv -f -- $memo.pv.new $memo.pv
  # Every MR reviewed leaves one; a month unopened is gone.
  { find ${memo:h} -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2>/dev/null } >/dev/null &!
}
# memo_restore: the kept previews into $st/pv.
memo_restore() {
  local f
  for f in $memo.pv/*(N); do print -rn -- "$(<$f)" > $st/pv/${f:t}; done
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

# unlisten: a child of this screen lets go of the port, or a screen opened
# after it on the same port (otis-test's) could not bind it.
unlisten() { (( lfd )) && ztcp -c $lfd 2>/dev/null; lfd=0; }

# --- commands out ------------------------------------------------------------------
# A screen that runs fzf's actions (otis-pick, otis-symbols) runs the ones
# that wait on a command here, off its loop. It has run, act, offout and
# offin, and sync_list <file> to take a reload-sync's rows.
# spawn <action> <command> <row> <then...>: the command in the background,
# what it answers taken up when it lands (landed_jobs), and then the actions
# that came after it in its chain. One of each at a time: an every(N) or a
# result firing again while its command is still out lets that one land.
# A key's command (bykey, the key's label) is the one the footer's spinner is
# for, and the keys pressed after it wait for it (act).
integer jn=0
typeset -a jobs uq
typeset -A jname jsrc jrow jrid jcur jkey jthen jt0
bykey=
spawn() {
  local j
  for j in $jobs; do [[ $jsrc[$j] == "$1 $2" ]] && return; done
  (( ++jn )); jobs+=($jn)
  jname[$jn]=$1 jsrc[$jn]="$1 $2" jrow[$jn]=$3 jrid[$jn]=${rid[$3]} jcur[$jn]=${rid[cur]} jkey[$jn]=$bykey jt0[$jn]=$EPOCHREALTIME
  jthen[$jn]=${(pj:\0:)${(@)argv[4,-1]:#}}
  [[ $1 == (execute-silent|transform) ]] && offout
  (( $+functions[tell] )) && tell
  { unlisten; zsh -fc "$2" </dev/null > $st/job.$jn.tmp 2>/dev/null; mv -f $st/job.$jn.tmp $st/job.$jn } >/dev/null &!
}
# landed_jobs: each command out that has finished, its answer taken up on the
# row it was for (found again by its id, should the rows have moved), then
# the rest of its chain; and once a key's is done, the next key waiting.
landed_jobs() {
  local j f row i was=$bykey
  local -a then_
  integer any=0
  for j in $jobs; do
    f=$st/job.$j
    [[ -e $f ]] || continue
    jobs=(${jobs:#$j}); any=1
    row=$jrow[$j]
    if [[ -n $jrid[$j] && $rid[row] != $jrid[$j] ]]; then
      i=${rid[(ie)$jrid[$j]]}; (( i <= $#rid )) && row=$i
    fi
    then_=(${(ps:\0:)jthen[$j]})
    bykey=$jkey[$j]
    # What a command did to the preview's scroll counts only where you still are.
    [[ $jname[$j] == (execute-silent|transform) && $rid[cur] == $jcur[$j] ]] && offin
    case $jname[$j] in
      transform) run "$(<$f)" $row "${then_[@]}" ;;
      reload-sync) sync_list $f; (( $#then_ )) && run "$then_[1]" $row "${then_[@]:1}" ;;
      transform-header) header=$(<$f); (( $#then_ )) && run "$then_[1]" $row "${then_[@]:1}" ;;
      *) (( $#then_ )) && run "$then_[1]" $row "${then_[@]:1}" ;;
    esac
    rm -f $f
    unset "jname[$j]" "jsrc[$j]" "jrow[$j]" "jrid[$j]" "jcur[$j]" "jkey[$j]" "jthen[$j]" "jt0[$j]"
  done
  bykey=$was
  (( any )) || return 1
  if (( $#uq )) && ! busy; then local k=$uq[1]; shift uq; act $k; fi
  return 0
}
# busy: a key's command is still out; in REPLY, what it is, and bt since when.
float bt
busy() {
  local j
  for j in $jobs; do [[ -n $jkey[$j] ]] && { REPLY=$jkey[$j]; bt=$jt0[$j]; return 0; }; done
  return 1
}
# spinning: that command has been out long enough (0.15s) for the footer to
# say so, rather than blink on every key; in REPLY what it is, and in spun
# the spinner's frame now. It turns ten frames a second.
spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
spun=
spinning() {
  busy && (( EPOCHREALTIME - bt >= 0.15 )) || return 1
  spin_frame; spun=$REPLY
}
# spin_frame: the spinner's frame now, in REPLY.
spin_frame() { REPLY=${spin[$(( int(EPOCHREALTIME * 10) % $#spin + 1 ))]}; }
# spin_foot: the footer while it spins, and the keys waiting after it.
spin_foot() { foot+=$A$spun$R" "$T$REPLY$R$C"…"$R; (( $#uq )) && foot+=$C"   then ${(j:, :)uq}"$R; }
# spun_on: the spinner has a new frame to draw.
spun_on() { local was=$spun; spinning && [[ $spun != $was ]]; }
# --- the key log ---------------------------------------------------------------------
# Every key that does something, a line each, in ~/.cache/otis/keys.tsv
# (OTIS_KEY_LOG, or off for none), for otis-usage: which keys you use, and
# which you never do. Movement, scrolling and quitting are not logged; a
# screen logs what its keys are for. A screen says what it is when it opens
# (keys_open), with the keys it offers as its key=label list, so a key never
# pressed still shows, as a nought.
typeset -g _klog=${OTIS_KEY_LOG:-${XDG_CACHE_HOME:-$HOME/.cache}/otis/keys.tsv} _kname=
# keys_open <name> <keys>: this screen, and the keys it offers.
keys_open() {
  [[ $_klog == off ]] && return
  _kname=$1
  [[ -d ${_klog:h} ]] || mkdir -p ${_klog:h} 2>/dev/null
  { print -r -- "$EPOCHSECONDS"$'\t'"$1"$'\t:open\t'"$2" >> $_klog; } 2>/dev/null
}
# keys_used <key> [label]: one of them pressed, and what it is for there.
# A key held down is one press: its repeats, each within 0.3s of the last,
# are not lines of their own.
typeset -gF _kat=0
typeset -g _klast=
keys_used() {
  [[ $_klog == off || -z $_kname ]] && return
  if [[ $1 == $_klast ]] && (( EPOCHREALTIME - _kat < 0.3 )); then _kat=$EPOCHREALTIME; return; fi
  _klast=$1 _kat=$EPOCHREALTIME
  { print -r -- "$EPOCHSECONDS"$'\t'"$_kname"$'\t'"$1"$'\t'"$2" >> $_klog; } 2>/dev/null
}
# keys_caller: the otis command that opened this picker, by name (gb,
# git-mr-lines), from the process that started it: the title a picker shows
# carries an MR's number or a file's path, which would split one picker
# into many. Once, as it opens. A list the board opens is started by the
# board's own process, named otis, so the board says which it is opening
# (OTIS_SCREEN): taken here once, so a picker this one opens in turn is
# named for itself. Without it, gb's keys were logged as the board's.
keys_caller() {
  local w bin=${ZSH_ARGZERO:A:h}
  REPLY=
  if [[ -n $OTIS_SCREEN ]]; then REPLY=$OTIS_SCREEN; unset OTIS_SCREEN; return; fi
  for w in ${(z)"$(ps -o args= -p $PPID 2>/dev/null)"}; do
    [[ $w == */* && -e $bin/${w:t} && ${w:t} != (otis-pick|otis-symbols|git-fzf) ]] && { REPLY=${w:t}; return; }
  done
}
