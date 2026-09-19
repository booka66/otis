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
def bad: c("BAD"; "31");              # failed, deleted, in the way
def elsewhere: c("ELSEWHERE"; "36");  # somewhere other than here: a worktree, a thread
def yours: c("YOURS"; "35");          # waiting on you: drafts, fixes, unresolved
def text: c("TEXT"; "39");            # what the row is about
def context: c("CONTEXT"; "90");      # true, but not why you are looking
def faint: c("FAINT"; "2");           # structure: rules, separators, empty slots
def main: c("MAIN"; "34");            # main, and things that are not yours to move

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
