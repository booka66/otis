# The MR as Claude is given it, shared by Claude's review (git-mr-claude) and
# the conversation beside it (git-symbols-ask): . "$share/mr-context.sh".

# threads_md: git-mr-threads' JSON on stdin as markdown, each thread under
# where it sits.
threads_md() {
  jq -r '.[]
    | .where as $w
    | "## " + (if $w.state == "line" then "\($w.path):\($w.from)-\($w.line)\(if $w.side == "old" then " (removed lines)" else "" end)"
        elif $w.state == "outdated" then "\($w.path), outdated (was line \($w.line))"
        elif $w.state == "file" then "\($w.path), the whole file" else "the MR" end)
      + (if .draft then " · unsubmitted draft" elif .resolved then " · resolved" else "" end),
      (.notes[] | "**\(.author.username)**\(if .draft then " (draft)" else "" end): \(.body)", ""), ""'
}

# callers_md <callers.tsv> <scratch dir>: git-callers' list as markdown, with
# the errors the change brings each caller and Sonnet's proposed fix under
# them (git-callers-fix) where it has landed, not waited for.
callers_md() {
  fx=$(git-callers-fix --file "$1")
  if [ -n "$fx" ]; then jq -r '.fixes[] | [.caller, "\(.where): \(.fix)"] | @tsv' "$fx" > "$2/fixes.tsv"; else : > "$2/fixes.tsv"; fi
  # Past two hundred importing packages git-callers finds the callers and
  # checks none of them.
  unchecked=$(cat "${1%.tsv}.unchecked" 2>/dev/null)
  # And the packages the finding's budget never reached, whose callers are
  # missing from the list rather than absent from the change's reach.
  left=$(cat "${1%.tsv}.partial" 2>/dev/null)
  awk -F'\t' -v unchecked="$unchecked" -v left="$left" '
    FILENAME == ARGV[1] { fix[$1] = $2; next }
    BEGIN { if (unchecked != "") { print "# Callers elsewhere\n\nCode this change did not touch that uses a changed exported symbol, found by tsgo. " unchecked " packages import the changed files, too many to type check, so none of these callers was: whether the change breaks them is for you to judge, reading the ones that matter." } else
      print "# Callers elsewhere\n\nCode this change did not touch that uses a changed exported symbol, found by tsgo. Each caller was type checked with the changed files as the base has them, then as the change leaves them: ✗ is an error the change brings. An error the caller had already is not listed. A caller with no ✗ still type checks, which is not the same as still being right. Under a ✗, what the reviewer is shown as the fix, from another model, when it has one: where it belongs (the caller or the change) and what it is." }
    $1 != last { printf "\n## %s\n", ($1 == "-" ? "Errors the change brings outside any caller" : $1); last = $1 }
    { printf "- %s (%s), lines %s-%s%s\n    %s\n", $4, $11, $6, $7, ($1 == "-" ? "" : ", " $8 " call" ($8 == 1 ? "" : "s") " from line " $3), $5
      if ($9 > 0) { k = split($12, e, "\036"); for (i = 1; i <= k; i++) print "  ✗ " $2 ":" e[i]; if ($4 in fix) print "  proposed fix, in " fix[$4] } }
    END { if (left != "") print "\nThe finding ran out of time with " left " packages left, so their callers are missing from this list: it is what was found, not all there is. The packages that import the most of the change were looked in first." }' "$2/fixes.tsv" "$1"
}
