# Shared by every jq program in bin/: jq -L "$share" 'include "otis"; ...'.
# The palette is the one in share/rowfmt.awk and share/palette.sh, named for
# the job each color does, so the same color means the same thing in every
# picker and preview.
# The theme's hues (otis-theme) from the environment the picker set up;
# without one, the terminal's own colors, which is the default theme.
def c(k; dflt): "\u001b[\($ENV["OTIS_T_" + k] // dflt)m";
def r: "\u001b[0m";
def attention: c("ATTENTION"; "33");  # look here: keys, ids, something waiting
def good: c("GOOD"; "32");            # passed, approved, safe to remove
def bad: c("BAD"; "31");              # broke: a change of yours that failed
def elsewhere: c("ELSEWHERE"; "36");  # somewhere other than here: a worktree, a thread
def yours: c("YOURS"; "35");          # waiting on you: drafts, fixes, unresolved
def text: c("TEXT"; "39");            # what the row is about
def context: c("CONTEXT"; "90");      # true, but not why you are looking
def faint: c("FAINT"; "2");           # structure: rules, separators, empty slots
def main: c("MAIN"; "34");            # main, and things that are not yours to move
# What a change took away: lines, a file; context's in a shell older than it.
def removed: c("REMOVED"; $ENV.OTIS_T_CONTEXT // "90");
# An MR's number, its last three digits in $tail and the rest faint: those
# three tell the MRs on a screen apart, and the rest is the same on all of them.
def iid($tail): tostring | faint + "!" + .[:-3] + r + $tail + .[-3:] + r;

# A count as every screen shows it, a comma every three digits: 1,354.
def num: tostring | if length > 3 then (.[:-3] | num) + "," + .[-3:] else . end;

# A GraphQL global id's number: "gid://gitlab/Ci::Pipeline/123" -> "123".
def gid: . // "" | tostring | sub("^gid://gitlab/[A-Za-z:]+/"; "");

# An ISO time, with or without fractional seconds, as seconds since the epoch.
def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
# How long ago, in the fewest characters: "3m", "2h", "5d".
def ago: (now - epoch) as $s |
  if $s < 3600 then "\($s / 60 | floor)m" elif $s < 86400 then "\($s / 3600 | floor)h" else "\($s / 86400 | floor)d" end;
# "Mon 14:02 (3h ago)".
def when: (epoch | localtime | strftime("%a %H:%M")) + " (" + ago + " ago)";

# Pad to $n columns without ever truncating: an id wider than its column
# pushes the row out rather than losing a digit.
def padr($n): tostring | . as $s | $s + (if ($s | length) < $n then "          "[0:$n - ($s | length)] else "" end);
def padl($n): tostring | . as $s | (if ($s | length) < $n then "          "[0:$n - ($s | length)] else "" end) + $s;
def plural($n; $one; $many): if $n == 1 then $one else $many end;
# tally($plan): a verification's verdict as its two answers, for every screen
# that says one. Does the change do what it says: of the plan's own criteria
# (own), how many held (ok) and the ones that did not (unmet). And what it did
# around that, from the breaker's checks (the plan's criteria of kind attack):
# the ones it broke, the ones where it only does more than its description
# says (changed), and how many could not be checked (open).
def tally($plan):
  [$plan.criteria[]? | select(.kind == "attack") | .id] as $b
  | [.criteria[]? | select(.id | IN($b[]) | not)] as $own
  | [.criteria[]? | select(.id | IN($b[]))] as $around
  | {own: ($own | length), ok: ([$own[] | select(.result == "verified")] | length),
     unmet: [$own[] | select(.result != "verified")],
     broke: [$around[] | select(.result == "failed")],
     changed: [$around[] | select(.result == "changed")],
     open: ([$around[] | select(.result == "unverified")] | length)};
# Cut to $n columns, the last an ellipsis when there was more.
def cut($n): if length > $n then .[0:$n - 1] + "…" else . end;
# Seconds as how long that is, in the fewest characters: "45s", "3m", "2h", "5d".
def span: if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m"
  elif . < 86400 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;

# The color an MR's failed pipeline is in: red for a change of yours on its
# way out; a draft's, or one you were asked to review, broke nothing of yours.
def broke($mine): if $mine and (.draft | not) then bad else context end;
# A pipeline's status as it matters: one failing only on approval gates
# (otis-config gateJobs) is waiting, not broken, and reads as APPROVAL.
def effective($gates):
  if . == null then null
  elif .status == "FAILED" and .jobs and
    ([.jobs.nodes[] | select(.status == "FAILED" and (.allowFailure | not))] as $f
      | ($f | length) > 0 and all($f[]; .name | IN($gates[])))
  then "APPROVAL" else .status end;
# One column, one concept, one color, for a GraphQL (upper-case) status.
def pipe_glyph:
  if . == "APPROVAL" then elsewhere + "◈"
  elif . == "FAILED" then bad + "✗"
  elif . == "RUNNING" then attention + "◐"
  elif . == "PENDING" or . == "CREATED" or . == "WAITING_FOR_RESOURCE" or . == "PREPARING" then attention + "○"
  elif . == "SUCCESS" then good + "✓"
  elif . == "CANCELED" or . == "CANCELING" then context + "⊘"
  elif . == "MANUAL" then elsewhere + "▸"
  elif . == null or . == "SKIPPED" then context + "·"
  else context + "?" end;
# A production deploy (git-deploy-list) as one glyph: ✓ live, ✗ failed, ⊘
# failed at once or canceled (a deploy that ran for no time was refused,
# behind production), ◐ running, ○ queued, ↺ a rollback. The strip in a
# deploy's preview (git-deploy-preview) is drawn from this.
def deploy_glyph:
  if .kind == "rollback" then bad + "↺" elif .status == "success" then good + "✓"
  elif .status == "failed" then (if .duration == 0 then context + "⊘" else bad + "✗" end)
  elif .status == "running" then attention + "◐" elif .status == "canceled" then context + "⊘"
  else attention + "○" end;

# wrapl($w; $n): the text word-wrapped to lines at most $w wide, and never
# cut: nothing a preview says ends in an ellipsis. $n is how many lines it
# would like to take. Of a text that takes more, the sentences from its
# start that fit in $n are kept, whole; and the first is kept whole whatever
# it takes, since a sentence that stops halfway says nothing. A word wider
# than a line is broken across lines.
def wrapl($w; $n):
  def wrap:
    (split(" ") | map(select(. != "") | if length > $w then . as $x | [range(0; length; $w) | $x[.:. + $w]] else [.] end) | add // []) as $words |
    reduce $words[] as $x ({lines: [], cur: ""};
      if .cur == "" then .cur = $x
      elif ((.cur | length) + 1 + ($x | length)) <= $w then .cur += " " + $x
      else .lines += [.cur] | .cur = $x end)
    | .lines + (if .cur != "" then [.cur] else [] end);
  (tostring | gsub("[\\s]+"; " ") | ltrimstr(" ") | rtrimstr(" ")) as $t |
  ($t | wrap) as $all |
  if ($all | length) <= $n then $all else
    ($t | split(" ")) as $ws |
    # How many words in, each sentence ends: at a word that closes one.
    ([range(0; $ws | length) | select($ws[.] | test("[.?!][\"\u0027)\\]]*$")) | . + 1] + [$ws | length] | unique) as $ends |
    (last($ends[] | select(($ws[0:.] | join(" ") | wrap | length) <= $n)) // $ends[0]) as $k |
    $ws[0:$k] | join(" ") | wrap
  end;
