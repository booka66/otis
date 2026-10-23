# music.awk: what cliamp plays, drawn for a screen. otis-music-feed hands it
# a line for each frame of cliamp's spectrum (B and the bands, each 0 to 1,
# lowest first), the player's state now and then (S), what plays next (Q), Z
# while nothing plays, and, from the screen, its empty places (A); it hands
# the screen what to paint, a frame at a time:
#
#   b<TAB>bars        w cells of bars for the rule over the footer, for a
#                     screen with no room for the background; empty while it
#                     has room
#   p<TAB>row<TAB>column<TAB>width<TAB>text
#                     a row of a place, where it changed
#   f                 the frame whole, which is when the screen paints it, so
#                     it never shows half of one
#
# S, Q and Z go on as s, q and z. A bare A starts a screen's places over, and
# "A <column> <width> <bottom row> <rows> [<most rows>]" is one: a stretch of
# blank rows standing on its bottom row, as tall as deep at most unless it
# says otherwise.
#
#   -v look=hills|river|glow|spectrogram|off   the background: cliamp's
#                   ClassicPeak, the beat as a line flowing left, a light from
#                   below that rises with the bass, or every band's loudness
#                   flowing left, the bass at the bottom
#   -v deep=<rows>  how tall the background is at most; a place has it as
#                   tall as it has rows, less one under what is above it,
#                   and none at all under three
#   -v colors=theme|winamp|rainbow|mono
#
# The strip's bars and a river's or spectrogram's cells are the color of how
# high they are: the theme's colors from cool to warm (elsewhere, main,
# attention, yours), blended where the theme gives them as RGB, else
# stepped. winamp is the old green to red, rainbow moves a hue along the
# bars, mono is the theme's review color alone.
#
# Run with LC_ALL=C: a river's braille is made a byte at a time.
BEGIN {
  e = "\033["
  split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", blk, " ")
  if (colors == "winamp") nst = split("38;2;0;190;60 38;2;150;220;0 38;2;250;220;0 38;2;255;150;0 38;2;255;60;30", st, " ")
  else if (colors == "mono") nst = split(ENVIRON["OTIS_T_REVIEW"], st, " ")
  else nst = split(ENVIRON["OTIS_T_ELSEWHERE"] " " ENVIRON["OTIS_T_MAIN"] " " ENVIRON["OTIS_T_ATTENTION"] " " ENVIRON["OTIS_T_YOURS"], st, " ")
  faint = ENVIRON["OTIS_T_FAINT"]
  w += 0; deep += 0
  if (w < 1) w = 1
  if (deep < 1) deep = 12
  nbar = w
  for (i = 0; i < 9; i++) lvl[i] = ramp(i / 8)
  back_init()
}
function rgb(s, a) {
  if (split(s, a, ";") != 5 || a[1] != 38 || a[2] != 2) return 0
  R = a[3]; G = a[4]; B = a[5]
  return 1
}
# ramp <0..1>: the SGR color that high up.
function ramp(f,   i, t, r1, g1, b1) {
  if (nst == 1) return st[1]
  t = f * (nst - 1); i = int(t); if (i >= nst - 1) i = nst - 2; t -= i
  if (rgb(st[i + 1])) {
    r1 = R; g1 = G; b1 = B
    if (rgb(st[i + 2])) return sprintf("38;2;%d;%d;%d", r1 + (R - r1) * t, g1 + (G - g1) * t, b1 + (B - b1) * t)
  }
  return st[int(f * (nst - 1) + 0.5) + 1]
}
# hue <0..1>: a bright color on the color wheel, for rainbow.
function hue(x,   i, f, q, t) {
  x = (x - int(x)) * 6; i = int(x); f = x - i
  q = int(255 * (1 - f * 0.75)); t = int(255 * (0.25 + f * 0.75))
  if (i == 0) return "38;2;255;" t ";64"
  if (i == 1) return "38;2;" q ";255;64"
  if (i == 2) return "38;2;64;255;" t
  if (i == 3) return "38;2;64;" q ";255"
  if (i == 4) return "38;2;" t ";64;255"
  return "38;2;255;64;" q
}
# spread <n> <out>: the bands spread over n bars, eased between one band and
# the next rather than in steps, so ten bands make a smooth range of any width.
function spread(n, out,   i, x, j, f, a, b) {
  for (i = 0; i < n; i++) {
    x = n > 1 ? i * (nb - 1) / (n - 1) : 0
    j = int(x); f = x - j
    a = band[j]; b = j + 1 < nb ? band[j + 1] : a
    f = (1 - cos(f * 3.14159265)) / 2
    out[i] = a + (b - a) * f
    if (out[i] > 1) out[i] = 1
    if (out[i] < 0) out[i] = 0
  }
}
function strip(   i, s, l, c, last) {
  if (ns && look != "off") { print "b\t"; return }
  s = ""; last = ""
  for (i = 0; i < nbar; i++) {
    l = int(v[i] * 8 + 0.5)
    c = colors == "rainbow" ? hue(i / nbar * 0.8 + fc * 0.004) : (l ? lvl[l] : faint)
    if (c != last) { s = s e c "m"; last = c }
    s = s blk[l ? l : 1]
  }
  print "b\t" s e "0m"
}
# --- the background ---------------------------------------------------------------
# Under what a screen shows, in its empty places only, standing on their
# bottom rows: one spectrum across the whole screen, so the hills under the
# board and under the pane are one range. A place shallower than the hills
# shows their foot, as if what is above stood in front of them. Dim: each
# color taken most of the way to the screen's ground (the terminal's own
# background where the screen could ask it, else the theme's), there when
# you look and gone when you read. A theme in the terminal's own colors has
# no RGB to blend, so its colors go faint instead, and it has no glow.
function back_init(   g, l) {
  g = ENVIRON["OTIS_MUSIC_GROUND"]; if (g == "") g = ENVIRON["OTIS_T_GROUND"]
  sub(/^#/, "", g)
  if (g ~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) { gr = hex(substr(g, 1, 2)); gg = hex(substr(g, 3, 2)); gb = hex(substr(g, 5, 2)); ground = 1 }
  if (look == "glow" && !(ground && rgb(ramp(0.75)))) look = "hills"
  # hills are cliamp's ClassicPeak: bars a column wide with a column between,
  # each row the color of how high it is (low, mid and high: the theme's
  # good, attention and bad), so a bar's color holds still as it moves.
  if (alpha == "") alpha = 0.6
  if (bar == "") bar = 1
  if (gap == "") gap = 1
  bar += 0; gap += 0; if (bar < 1) bar = 1
  if (colors == "winamp") split("38;2;0;190;60 38;2;250;220;0 38;2;255;60;30", zc, " ")
  else if (colors == "mono") split(ENVIRON["OTIS_T_REVIEW"] " " ENVIRON["OTIS_T_REVIEW"] " " ENVIRON["OTIS_T_REVIEW"], zc, " ")
  else split(ENVIRON["OTIS_T_GOOD"] " " ENVIRON["OTIS_T_ATTENTION"] " " ENVIRON["OTIS_T_BAD"], zc, " ")
  for (l = 1; l <= 3; l++) zc[l] = dim(zc[l], 0.85)
  split("⎺ ⎻ ⎼ ⎽", capg, " ")
  # Each frame is a 30th of a second, or what otis.musicFps makes it.
  if (fps < 1) fps = 30
  dt = 1 / fps; rise = 1 - exp(-34 * dt); fall = 1 - exp(-10 * dt)
  # By how high each column is, as the strip's bars are; a river's line is
  # thin where bars are solid, so it is drawn brighter to be as there.
  for (l = 0; l < 9; l++) bl[l] = dim(ramp(l / 8), look == "river" ? (alpha * 1.4 > 1 ? 1 : alpha * 1.4) : alpha)
}
function hex(s,   d) { d = "0123456789abcdef"; s = tolower(s); return (index(d, substr(s, 1, 1)) - 1) * 16 + index(d, substr(s, 2, 1)) - 1 }
# dim <SGR> <0..1>: the color that far from the ground toward it.
function dim(c, a) {
  if (ground && rgb(c)) return sprintf("38;2;%d;%d;%d", gr + (R - gr) * a, gg + (G - gg) * a, gb + (B - gb) * a)
  return "2;" c
}
function glyph(bits) { return sprintf("%c%c%c", 226, 160 + int(bits / 64), 128 + bits % 64) }
function place(   k) {
  if (NF == 1) { ns = 0; sw = 0; split("", painted); return }
  if ($5 - 1 < 3) return
  ns++; px[ns] = $2; pw[ns] = $3; pb[ns] = $4; pn[ns] = $5; pd[ns] = $5 - 1 > (NF > 5 ? $6 : deep) ? (NF > 5 ? $6 : deep) : $5 - 1
  if (px[ns] + pw[ns] - 1 > sw) { sw = px[ns] + pw[ns] - 1; hn = 2 * sw; for (k = 0; k < hn; k++) hist[k] = 0.5; split("", sg); sh = 0 }
}
function back(   k, rb, t, b) {
  if (look == "off" || !ns) return
  if (look == "river") flow()
  else if (look == "spectrogram") { for (b = 0; b < nb; b++) sg[sh, b] = band[b]; sh = (sh + 1) % sw }
  else if (look == "glow") { lit += ((band[0] + band[1]) / 2 - lit) * ((band[0] + band[1]) / 2 > lit ? 0.5 : 0.07); rgb(ramp(0.75)) }
  else { nbb = int((sw + gap) / (bar + gap)) + 1; spread(nbb, bv); classic(nbb) }
  for (k = 1; k <= ns; k++) {
    if (look == "river") bank(k)
    for (rb = 0; rb < pd[k]; rb++) {
      t = look == "river" ? river(k, rb) : look == "glow" ? glow(k, rb) : look == "spectrogram" ? spec(k, rb) : hills(k, rb)
      if (painted[pb[k] - rb, px[k]] != t) { painted[pb[k] - rb, px[k]] = t; print "p\t" (pb[k] - rb) "\t" px[k] "\t" pw[k] "\t" t }
    }
    # Over the bars, the rest of the place blank: a place that has just got
    # shorter at the top had bars there that nothing else would take away.
    if (!(pw[k] in sp)) sp[pw[k]] = sprintf("%" pw[k] "s", "")
    for (rb = pd[k]; rb < pn[k] && rb <= deep; rb++)
      if (painted[pb[k] - rb, px[k]] != sp[pw[k]]) { painted[pb[k] - rb, px[k]] = sp[pw[k]]; print "p\t" (pb[k] - rb) "\t" px[k] "\t" pw[k] "\t" sp[pw[k]] }
  }
}
# hills <place> <row from its bottom>: the spectrum filled up from the
# bottom, each column the color of how high it stands.
# classic <bars>: each bar eased toward the spectrum, rising fast and falling
# slower, and its cap: thrown up by a rise, held a moment at the top, then
# fallen back onto the bar under gravity. cliamp's ClassicPeak, its numbers.
function classic(n,   i, lv, was) {
  for (i = 0; i < n; i++) {
    lv = bv[i]
    bp[i] += (lv - bp[i]) * (lv > bp[i] ? rise : fall)
    if (cv[i] == 0 && cp[i] <= bp[i] + 0.01 && lv > cp[i]) {
      cv[i] = 0.8 + 1.4 * (lv - cp[i]); if (cv[i] > 1.7) cv[i] = 1.7
      cp[i] = lv; ch[i] = 0
    }
    if (ch[i] > 0) { ch[i] -= dt; if (ch[i] > 0) continue }
    was = cv[i]; cp[i] += cv[i] * dt; cv[i] -= 9.5 * dt
    if (cp[i] > 1) cp[i] = 1
    if (was > 0 && cv[i] <= 0 && cp[i] > bp[i] + 0.01) { cv[i] = 0; ch[i] = 0.08; continue }
    if (cp[i] <= bp[i]) { cp[i] = bp[i]; cv[i] = 0; ch[i] = 0 }
  }
}
# hills <place> <row from its bottom>: the bars, eighths of a row at their
# tops, and each cap a scan line a quarter of a row high where it is, in the
# row's color.
function hills(k, rb,   n, c, f, t, last, i, z, col, g, dy, top) {
  n = pd[k]; t = ""; last = ""
  z = rb / n >= 0.6 ? 3 : rb / n >= 0.3 ? 2 : 1
  top = n - 1 - rb
  for (c = px[k]; c < px[k] + pw[k]; c++) {
    if ((c - 1) % (bar + gap) >= bar) { t = t " "; continue }
    i = int((c - 1) / (bar + gap))
    f = int((bp[i] * n - rb) * 8)
    g = f >= 8 ? "█" : f >= 1 ? blk[f] : ""
    if (g == "" && cp[i] > bp[i] + (0.5 / (n * 4) > 0.01 ? 0.5 / (n * 4) : 0.01)) {
      dy = int((1 - (cp[i] < 1 ? cp[i] : 1)) * (n * 4 - 1) + 0.5)
      if (int(dy / 4) == top) g = capg[dy % 4 + 1]
    }
    if (g == "") { t = t " "; continue }
    col = colors == "rainbow" ? dim(hue(i / nbb * 0.8 + fc * 0.004), 0.85) : zc[z]
    if (col != last) { t = t e "0;" col "m"; last = col }
    t = t g
  }
  return t e "0m"
}
# spec <place> <row from its bottom>: a band's loudness, one band a row from
# the bass up (fewer, in a place with fewer rows than bands), a column a
# frame, the newest on the right, each cell the color of how loud it was,
# short of its top so the bands stay apart; quiet is blank.
function spec(k, rb,   c, l, t, last, b) {
  t = ""; last = ""
  b = pd[k] < nb ? int(rb * nb / pd[k]) : rb
  for (c = px[k] - 1; c < px[k] + pw[k] - 1; c++) {
    l = b < nb ? int(sg[(sh + c) % sw, b] * 8 + 0.5) : 0
    if (!l) { t = t " "; continue }
    if (bl[l] != last) { t = t e "0;" bl[l] "m"; last = bl[l] }
    t = t "▇"
  }
  return t e "0m"
}
# flow: how loud it is now, the bass counting most, pushed onto the right of
# a line two dots a column wide that flows left. The line is how far it is
# from the last second's loudness, against how far it has been lately, so
# the beat rides the middle whether the set is quiet or loud.
function flow(   i, x, n, s, l) {
  s = 0; n = 0
  for (i = 0; i < nb; i++) { x = i < 2 ? 3 : i < 5 ? 2 : 1; s += band[i] * x; n += x }
  s = n ? s / n : 0
  if (!seen++) { avg = s; dev = 0.05 }
  avg += (s - avg) * 0.03; dev += ((s > avg ? s - avg : avg - s) - dev) * 0.03
  l = 0.5 + (s - avg) / (4 * dev + 0.02)
  hist[hp] = l < 0.05 ? 0.05 : l > 0.95 ? 0.95 : l; hp = (hp + 1) % hn
}
# bank <place>: the line over that place's height, as each dot column's
# dots counted up from the bottom (lo to hi), joined to the column before.
function bank(k,   x, y, py) {
  py = -1
  for (x = 2 * px[k] - 3; x < 2 * (px[k] + pw[k] - 1); x++) {
    if (x < 0) continue
    y = int(hist[(hp + x) % hn] * (4 * pd[k] - 1) + 0.5)
    if (py < 0) py = y
    lo[x] = y < py ? y : py; hi[x] = y > py ? y : py
    py = y
  }
}
function river(k, rb,   c, x, j, d, bits, t, last, l) {
  t = ""; last = ""
  for (c = px[k] - 1; c < px[k] + pw[k] - 1; c++) {
    bits = 0
    for (j = 0; j < 2; j++) {
      x = 2 * c + j
      for (d = 0; d < 4; d++)
        if (4 * rb + 3 - d >= lo[x] && 4 * rb + 3 - d <= hi[x]) bits += d < 3 ? (j ? 8 : 1) * 2 ^ d : (j ? 128 : 64)
    }
    if (bits) {
      l = int(hist[(hp + 2 * c) % hn] * 8 + 0.5)
      if (bl[l] != last) { t = t e "0;" bl[l] "m"; last = bl[l] }
    }
    t = t glyph(bits)
  }
  return t e "0m"
}
# glow <place> <row from its bottom>: the row lit from below, as much as the
# bass is loud, rising fast and falling slowly; blank, in a color.
function glow(k, rb,   a) {
  if (!(pw[k] in sp)) sp[pw[k]] = sprintf("%" pw[k] "s", "")
  a = alpha * 0.28 * lit * ((pd[k] - rb) / pd[k]) ^ 2
  if (a < 0.01) return e "0m" sp[pw[k]]
  return sprintf("%s0;48;2;%d;%d;%dm%s%s0m", e, gr + (R - gr) * a, gg + (G - gg) * a, gb + (B - gb) * a, sp[pw[k]], e)
}
$1 == "B" {
  nb = NF - 1
  for (i = 0; i < nb; i++) band[i] = $(i + 2) + 0
  fc++
  spread(nbar, v)
  strip(); back(); print "f"
  fflush()
  next
}
$1 == "A" { place(); next }
$1 == "Z" { print "z"; print "f"; fflush(); next }
{ sub(/^S/, "s"); sub(/^Q/, "q"); print; fflush() }
