# A Cursor Cloud agent's run stream as git-claude-view's progress events.
# Input: {event, data} per SSE event (git-verify-run pairs them up), with -n and
# inputs. Output: {type: text | thinking | tool | output | otis | result, ...}.
#
# What it says and thinks comes a few characters at a time, so a message
# shows once it is whole: when the agent does something else (a tool call,
# a status change, the end). One event a message, so a code block or a
# report inside it can be folded to a row by the view, rather than a line a
# row. Only the events shown here end a message: Cursor sends an
# interaction_update beside every fragment, and heartbeats, which would
# otherwise cut it into words.
# A tool call is announced more than once (first without its arguments), so it
# shows once, when its arguments arrive, and what it returned when it is done.

def rel: if type == "string" then sub("^/workspace/"; "") else . end;

def detail($name):
  if $name == "run_terminal_cmd" then .command
  elif $name == "file_search" then "\(.globPattern // "") in \(.targetDirectory // "." | rel)"
  elif $name == "grep_search" then "\(.pattern // "")\(if .path then " in \(.path | rel)" else "" end)\(if .glob then " \(.glob)" else "" end)"
  elif .path then (.path | rel) + (if .offset then " from line \(.offset)" else "" end)
  else del(.toolCallId, .requestId, .conversationId) | tostring | .[0:160] end;

def returned($name):
  if .error then "failed: " + (.error | if type == "string" then . else tostring end)
  elif .success | type != "object" then (.success // . | tostring)
  else .success as $s
    | if $name == "run_terminal_cmd" then
        ([$s.stdout, $s.stderr] | map(select(. != null and . != "")) | join("\n"))
        + (if $s.exitCode and $s.exitCode != 0 then "\n(exit \($s.exitCode))" else "" end)
      elif $name == "read_file" then "\($s.totalLines // "?") lines"
      elif $name == "file_search" then "\($s.totalFiles // ($s.files | length)) files: \(($s.files // []) | join(", "))"
      elif $name == "grep_search" then
        [$s.workspaceResults[]?.content.matches[]?] as $files
        | "\([$files[].matches[]?] | length) matches in \($files | length) files: \($files | map(.file) | join(", "))"
      else $s.content // $s.output // ($s | tostring) end
  end
  | .[0:600];

def flush: [.buf | to_entries[] | select(.value | test("\\S")) | {type: .key, text: (.value | sub("^\\s+"; "") | sub("\\s+$"; ""))}];

foreach (inputs | fromjson? | select(type == "object")) as $e (
  {buf: {text: "", thinking: ""}, shown: {}, out: []};
  .out = []
  | ({assistant: "text", thinking: "thinking"}[$e.event]) as $kind
  | if $kind then .buf[$kind] += ($e.data.text // "")
    elif $e.event | IN("tool_call", "status", "error", "result") then
      .out = flush | .buf = {text: "", thinking: ""}
      | if $e.event == "tool_call" then
          $e.data as $t
          | (if $t.args != null and (.shown[$t.callId] | not) then
               .out += [{type: "tool", name: $t.name, input: {detail: ($t.args | detail($t.name))}}] | .shown[$t.callId] = true
             else . end)
          | (if $t.status != "running" and $t.result != null then
               # Calls run side by side and finish out of order, so each
               # says which it was.
               (($t.args // {}) | .globPattern // .pattern // (.path | if . then split("/")[-1] else null end) // .command // $t.name
                 | tostring | .[0:40]) as $which
               | .out += [{type: "output", error: ($t.status == "error" or $t.result.error != null),
                           text: ($which + ": " + ($t.result | returned($t.name)))}]
             else . end)
        elif $e.event == "status" then .out += [{type: "otis", text: "tester \($e.data.status | ascii_downcase)"}]
        elif $e.event == "error" then
          # The stream falling over is not the tester failing; the run picks it up again.
          .out += [{type: "otis", text: (if ($e.data.message | test("stream is no longer available")) then "tester's stream dropped; picking it up again" else "tester error: \($e.data.message)" end)}]
        else .out += [{type: "result"}] end
    else . end;
  .out[] + {who: "tester"})
