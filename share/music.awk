# music.awk: what cliamp plays, drawn. otis-music-feed hands it a line for
# each frame of cliamp's spectrum (B and the bands, each 0 to 1, lowest
# first), the player's state now and then (S), what plays next (Q), Z while
# nothing plays, and, from a screen, its empty places (A); it hands the
# screen what to paint, ready to paint.
#
#   -v mode=strip   for every screen: w cells of bars a frame for the rule
#                   over its footer, "b<TAB>bars"; and, under look, the
#                   background in its empty places, a line
#                   "p<TAB>row<TAB>column<TAB>width<TAB>text" for each row of
#                   a place that changed; then "f", the frame whole, which is
#                   when the screen paints it, so it never shows half of one
#   -v mode=screen  for the music screen: w columns by h rows of bars, a line
#                   "r<TAB>row<TAB>text" for each row that changed, then "f"
#   -v style=bars|mirror|led   how the music screen draws them
#   -v look=hills|river|glow|spectrogram|off   the background: the spectrum
#                   as hills, the beat as a line flowing left, a light from
#                   below that rises with the bass, or every band's loudness
#                   flowing left, the bass at the bottom
#   -v deep=<rows>  how tall the background is at most; a place has it as
#                   tall as it has rows, less one under what is above it,
#                   and none at all under three
#   -v colors=theme|winamp|rainbow|mono
#
# S, Q and Z go on as s, q and z, for the screen to read. A bare A starts a
# screen's places over, and "A <column> <width> <bottom row> <rows>" is one:
# a stretch of blank rows standing on its bottom row.
#
# The strip's bars are for a screen with no room for the background: while
# the background has a place, the strip is the title alone ("b" and no bars).
#
# A bar's color is how high it is: the theme's colors from cool to warm
# (elsewhere, main, attention, yours), blended where the theme gives them
# as RGB, else stepped. winamp is the old green to red, rainbow moves a hue
# along the bars, mono is the theme's review color alone. Never the theme's
# bad: on otis, red means something broke.
#
# Run with LC_ALL=C: a river's braille is made a byte at a time.
BEGIN {
  e = "\033["
  split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", blk, " ")
  if (colors == "winamp") nst = split("38;2;0;190;60 38;2;150;220;0 38;2;250;220;0 38;2;255;150;0 38;2;255;60;30", st, " ")
  else if (colors == "mono") nst = split(ENVIRON["OTIS_T_REVIEW"], st, " ")
  else nst = split(ENVIRON["OTIS_T_ELSEWHERE"] " " ENVIRON["OTIS_T_MAIN"] " " ENVIRON["OTIS_T_ATTENTION"] " " ENVIRON["OTIS_T_YOURS"], st, " ")
  faint = ENVIRON["OTIS_T_FAINT"]; peakc = ENVIRON["OTIS_T_TEXT"]
  w += 0; h += 0; deep += 0
  if (w < 1) w = 1
  if (h < 1) h = 1
  if (deep < 1) deep = 12
  # The music screen's bars: two columns wide, a column apart, centered.
  nbar = mode == "screen" ? int((w + 1) / 3) : w
  if (nbar < 1) nbar = 1
  lpad = mode == "screen" ? int((w - (nbar * 3 - 1)) / 2) : 0
  pad = lpad > 0 ? sprintf("%" lpad "s", "") : ""
  hu = style == "mirror" ? int((h + 1) / 2) : h
  for (i = 0; i < 9; i++) lvl[i] = ramp(i / 8)
  for (r = 0; r < hu; r++) rowc[r] = ramp(hu > 1 ? r / (hu - 1) : 1)
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
# Peaks: each bar's highest lately, held a moment, then falling faster as
# it goes, as on a hi-fi.
function peaks(   i) {
  for (i = 0; i < nbar; i++) {
    if (v[i] >= pk[i]) { pk[i] = v[i]; pv[i] = 0; hold[i] = 12; continue }
    if (hold[i] > 0) { hold[i]--; continue }
    pv[i] += 0.0018; pk[i] -= pv[i]
    if (pk[i] < v[i]) pk[i] = v[i]
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
# cell <bar> <row from the bottom> <rows>: what a bar shows in that row, in
# cs (its two columns) and cc (its color).
function cell(i, rb, n,   h8, fill, p8, prow) {
  h8 = v[i] * n * 8; fill = h8 - rb * 8
  cc = colors == "rainbow" ? hue(i / nbar * 0.8 + fc * 0.004) : rowc[rb]
  if (style == "led") {
    if (fill >= 4) { cs = "▄▄"; return }
    p8 = pk[i] * n * 8
    if (int(p8 / 8) == rb && p8 > 4) { cs = "▄▄"; cc = peakc; return }
    cs = "▄▄"; cc = faint; return
  }
  if (fill >= 8) { cs = "██"; return }
  if (fill >= 1) { cs = blk[int(fill)] blk[int(fill)]; return }
  if (style == "bars") {
    p8 = pk[i] * n * 8; prow = int(p8 / 8)
    if (prow == rb && p8 - h8 >= 6) { cs = (p8 - prow * 8 >= 4) ? "▔▔" : "▁▁"; cc = peakc; return }
  }
  cs = "  "; cc = ""
}
# A row of the mirror's lower half: the bars hanging down, dim.
function under(i, k,   h8, fill) {
  h8 = v[i] * hu * 8; fill = h8 - k * 8
  cc = colors == "rainbow" ? hue(i / nbar * 0.8 + fc * 0.004) : rowc[k < hu ? k : hu - 1]
  if (fill >= 8) cs = "██"
  else if (fill >= 4) cs = "▀▀"
  else if (fill >= 1) cs = "▔▔"
  else { cs = "  "; cc = "" }
}
function screen(   r, i, s, last, c, dim) {
  for (r = 0; r < h; r++) {
    s = pad; last = ""
    dim = style == "mirror" && r >= hu
    for (i = 0; i < nbar; i++) {
      if (dim) under(i, r - hu)
      else cell(i, (style == "mirror" ? hu : h) - 1 - r, style == "mirror" ? hu : h)
      c = cc == "" ? "" : (dim ? "0;2;" : "0;") cc
      if (c != last && cs != "  ") { s = s e c "m"; last = c }
      s = s cs (i < nbar - 1 ? " " : "")
    }
    s = s e "0m"
    if (s != shown[r]) { shown[r] = s; print "r\t" r "\t" s }
  }
  print "f"
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
  if (alpha == "") alpha = 0.3
  bar += 0; gap += 0; if (bar < 1) bar = 1
  # By how high each column is, as the strip's bars are; a river's line is
  # thin where hills are solid, so it is drawn brighter to be as there.
  for (l = 0; l < 9; l++) bl[l] = dim(ramp(l / 8), look == "river" ? alpha * 1.7 : alpha)
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
  ns++; px[ns] = $2; pw[ns] = $3; pb[ns] = $4; pd[ns] = $5 - 1 > deep ? deep : $5 - 1
  if (px[ns] + pw[ns] - 1 > sw) { sw = px[ns] + pw[ns] - 1; hn = 2 * sw; for (k = 0; k < hn; k++) hist[k] = 0.5; split("", sg); sh = 0 }
}
function back(   k, rb, t, b) {
  if (look == "off" || !ns) return
  if (look == "river") flow()
  else if (look == "spectrogram") { for (b = 0; b < nb; b++) sg[sh, b] = band[b]; sh = (sh + 1) % sw }
  else if (look == "glow") { lit += ((band[0] + band[1]) / 2 - lit) * ((band[0] + band[1]) / 2 > lit ? 0.5 : 0.07); rgb(ramp(0.75)) }
  else spread(int((sw + gap) / (bar + gap)) + 1, bv)
  for (k = 1; k <= ns; k++) {
    if (look == "river") bank(k)
    for (rb = 0; rb < pd[k]; rb++) {
      t = look == "river" ? river(k, rb) : look == "glow" ? glow(k, rb) : look == "spectrogram" ? spec(k, rb) : hills(k, rb)
      if (painted[pb[k] - rb, px[k]] != t) { painted[pb[k] - rb, px[k]] = t; print "p\t" (pb[k] - rb) "\t" px[k] "\t" pw[k] "\t" t }
    }
  }
}
# hills <place> <row from its bottom>: the spectrum filled up from the
# bottom, each column the color of how high it stands.
function hills(k, rb,   c, f, l, t, last, i) {
  t = ""; last = ""
  for (c = px[k]; c < px[k] + pw[k]; c++) {
    if ((c - 1) % (bar + gap) >= bar) { t = t " "; continue }
    i = int((c - 1) / (bar + gap))
    f = bv[i] * pd[k] * 8 * 0.9 - rb * 8
    if (f < 1) { t = t " "; continue }
    l = int(bv[i] * 8 + 0.5); if (l < 1) l = 1
    if (bl[l] != last) { t = t e "0;" bl[l] "m"; last = bl[l] }
    t = t (f >= 8 ? "█" : blk[int(f)])
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
  a = alpha * 0.55 * lit * ((pd[k] - rb) / pd[k]) ^ 2
  if (a < 0.01) return e "0m" sp[pw[k]]
  return sprintf("%s0;48;2;%d;%d;%dm%s%s0m", e, gr + (R - gr) * a, gg + (G - gg) * a, gb + (B - gb) * a, sp[pw[k]], e)
}
$1 == "B" {
  nb = NF - 1
  for (i = 0; i < nb; i++) band[i] = $(i + 2) + 0
  fc++
  spread(nbar, v)
  if (mode == "strip") { strip(); back(); print "f" }
  else { peaks(); screen() }
  fflush()
  next
}
$1 == "A" { place(); next }
$1 == "Z" { print "z"; if (mode == "strip") print "f"; fflush(); next }
{ sub(/^S/, "s"); sub(/^Q/, "q"); print; fflush() }
