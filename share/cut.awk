# cut.awk: the lines of one hunk that fall inside [s, e] on `side`, with a
# header for what is left, so delta numbers them as the file does and git
# apply takes them as a patch. The input is a -U999999 diff: the file as one
# hunk with every line in it. A change from the other side belongs to the
# symbol when it sits between two of its lines, not after its last: what
# follows a removed symbol is usually the next symbol, whole.
# awk -v side=new|old -v s=<first> -v e=<last> [-v note=<header text>] -f cut.awk
  !inhunk && /^@@/ { inhunk = 1; split($2, a, ","); o = substr(a[1], 2) + 0; split($3, b, ","); n = substr(b[1], 2) + 0; next }
  !inhunk { print; next }
  /^\\/ { if (last) line[++kept] = $0; next }
  {
    c = substr($0, 1, 1)
    keep = 0
    if (c == " ")      { keep = (side == "new") ? (n >= s && n <= e) : (o >= s && o <= e); lo = o; ln = n; o++; n++ }
    else if (c == "-") { keep = (side == "new") ? (n > s && n <= e) : (o >= s && o <= e); lo = o; ln = n; o++ }
    else if (c == "+") { keep = (side == "new") ? (n >= s && n <= e) : (o > s && o <= e); lo = o; ln = n; n++ }
    else next
    last = keep
    if (!keep) next
    if (!kept) { O = lo; N = ln; oc = 0; nc = 0 }
    line[++kept] = $0
    if (c != "+") oc++
    if (c != "-") nc++
  }
  END {
    if (!kept) exit
    # A side with nothing kept names the line before, as git does; 0 for none.
    # The note rides on the header, where delta draws a function name, in
    # quotes: delta highlights the header as code, and a string is one color
    # where bare words would light up as keywords.
    printf "@@ -%d,%d +%d,%d @@%s\n", (oc ? O : (O > 1 ? O - 1 : 0)), oc, (nc ? N : (N > 1 ? N - 1 : 0)), nc, (note != "" ? " \"" note "\"" : "")
    for (i = 1; i <= kept; i++) print line[i]
  }
