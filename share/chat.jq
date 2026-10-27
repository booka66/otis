# The chat file the symbol view's panel draws (otis-symbols' chat_load), as
# claude's output comes: jq -R -j -L "$share" 'include "chat"; stream($ctx; $root)'.
# Claude's words, and lines of otis's own that start with \u0001 and a
# letter: U a question, O where it was asked from, T what Claude is doing,
# E what went wrong, S a note. A question's conversation (git-symbols-ask)
# and a thread's (otis-thread) are both written through these. $ctx is the folder of files the conversation gave
# Claude, $root the checkout Claude is in; a note names a file the way the
# person sees it, not by its path.

# note: a tool Claude uses, as a line of its own.
def note($ctx; $root): "\n\u0001T " + (
    if .name == "Read" then "reading " + (.input.file_path // "" | ltrimstr($ctx + "/")
      | {"about.md": "what it says of itself", "diff.patch": "the diff", "symbols.md": "the symbols",
         "shape.md": "the shape", "callers.md": "the callers", "threads.md": "the threads",
         "review.md": "the review"}[.] // ltrimstr($root + "/"))
    elif .name == "Edit" or .name == "Write" then "editing " + (.input.file_path // "" | ltrimstr($root + "/"))
    elif .name == "Grep" then "searching for " + (.input.pattern // "")
    elif .name == "Glob" then "looking for " + (.input.pattern // "")
    elif .name == "Bash" and (.input.command // "" | startswith("git-symbols-ask --draft")) then "drafting a comment"
    elif .name == "Bash" then "running " + (.input.command // "" | split("\n")[0] | split($ctx + "/") | join("") | split($root + "/") | join("") | .[0:80])
    else .name end) + "\n";

# stream: a line of claude -p --output-format stream-json
# --include-partial-messages: its words as they come, its tools as notes, and
# what went wrong, if anything did, at the end.
def stream($ctx; $root):
  fromjson? |
  if .type == "stream_event" and .event.type == "content_block_delta" and .event.delta.type == "text_delta" then .event.delta.text
  elif .type == "assistant" then .message.content[]? | select(.type == "tool_use") | note($ctx; $root)
  elif .type == "result" then if .is_error or .subtype != "success" then "\n\u0001E " + (.result // .subtype | tostring) + "\n" else "\n" end
  else empty end;

# transcript: a line of Claude Code's own transcript, for what was said in it
# full screen: each question (without the place otis added to it) and what
# Claude said and did.
def transcript($ctx; $root):
  fromjson? | select(.isSidechain != true and .isMeta != true) |
  if .type == "user" then
    [.message.content | if type == "string" then . else (.[]? | select(.type == "text") | .text) end | select(startswith("<") | not)]
    | if length > 0 then "\n\u0001U " + (join(" ") | split("\n\n(I")[0] | gsub("\n"; " ")) + "\n" else empty end
  elif .type == "assistant" then .message.content[]? | if .type == "text" then .text + "\n" elif .type == "tool_use" then note($ctx; $root) else empty end
  else empty end;
