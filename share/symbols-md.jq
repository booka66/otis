# symbols-md.jq: seam's graph as markdown, for a reader that is not a person with
# the page open: an agent reviewing the change, a merge request description. Every
# definition in reading order with what happened to it, what it uses and what uses
# it, and, when otis-seam has them, Claude's few words on it and the callers
# outside the change.
def kindword: if . == "tests" then " · test" elif . == "gen" then " · generated" elif . == "cfg" then " · config" else "" end;
def change: if . == "signature" then "~ signature changed" elif . == "body" then "body only" else . end;

. as $g
| ($g.gloss // null) as $G
| ($g.edges | map(select(.from != .to))) as $E
| (reduce $E[] as $e ({}; .[$e.from] += [$e])) as $out
| (reduce $E[] as $e ({}; .[$e.to] += [$e])) as $into
| (reduce (($g.callers // [])[]) as $c ({}; .[$c.to] += [$c])) as $calls
| ([$g.reading.threads[][]] | to_entries | map({key: .value, value: .key}) | from_entries) as $at
| "# \($g.rev // "The change"), by definition\n",
  (if $G and ($G.spine // "") != "" then "\($G.spine)\n" else empty end),
  (if $G and (($G.order // []) | length) > 0 then
     "Read first: " + ([$G.order[] | "\(.id) (\(.why))"] | join("; ")) + "\n" else empty end),
  "Every definition the change touches, in reading order. ~ is a changed signature: what names it may break. Body only: nothing outside it can. An entry point is one nothing else in the change mentions, where a reader starts. A newly used one (⇢) is a mention this change adds: rewiring, as against behaviour.\n",
  "Read this way, at most \($g.reading.loose) mentions at once lead to a definition not yet read, with \($g.reading.hops) moves between files\(if ($g.reading.unmet | length) > 0 then "; read before anything that mentions them, where a circle left no way in: " + ($g.reading.unmet | join(", ")) else "" end).\n",
  ($g.definitions | sort_by([$at[if .class then "\(.path)#\(.class)" else .id end], .class != null]) | .[]
   | . as $d
   | (($G.defs // {})[.id] // {}) as $q
   | "## \(.id)",
     (.change | change) + (.box.kind | kindword) + (if .exported then " · exported" else "" end)
       + (if .root and .class == null and .box.kind == "source" then " · entry point" else "" end)
       + " · +\(.added // 0) -\(.removed // 0)"
       + (if .start then " · lines \(.start)-\(.end) of the \(if .side == "old" then "base" else "head" end)" else "" end)
       + (if .open then ", the signature on line \(.open)" else "" end),
     (if (.head // "") != "" then "    \(.head)" else empty end),
     (if ($q.does // "") != "" then "does: \($q.does)" else empty end),
     (if ($q.gloss // "") != "" then "the change: \($q.gloss)" else empty end),
     (($out[.id] // []) | if length > 0 then "uses: " + (map(.to + (if .facet == "iface" then ", in its signature" else "" end)) | join("; ")) else empty end),
     (($out[.id] // []) | map(select(.new)) | if length > 0 then "newly uses ⇢: " + (map(.to) | join(", ")) else empty end),
     (($into[.id] // []) | if length > 0 then "used by: " + (map(.from) | join(", ")) else empty end),
     (($calls[.id] // []) | if length > 0 then
        "callers outside the change: \(length), \(map(select(.breaks)) | length) broken",
        (.[] | "  \(if .breaks then "✗" else "·" end) \(.from | sub("^[^#]*#"; "")) (\(.from | sub("#.*$"; ""))\(if .line then ":\(.line)" else "" end))\(if .note then " — \(.note)" else "" end)")
      else empty end),
     ""),
  (($calls["-"] // []) | if length > 0 then
     "## Broken outside the change, calling nothing it touched",
     (.[] | "  ✗ \(.from | sub("^[^#]*#"; "")) (\(.from | sub("#.*$"; ""))\(if .line then ":\(.line)" else "" end))\(if .note then " — \(.note)" else "" end)"), ""
   else empty end),
  ($g.files | if length > 0 then
     "## Changed outside any definition (imports, top-level statements) or in files seam has no language for",
     (.[] | "- \(.path) · \(.change) · +\(.added // 0) -\(.removed // 0)"), ""
   else empty end)
