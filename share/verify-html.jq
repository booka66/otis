# A verification's report as one HTML page (bin/git-verify-html says what it
# is for, and passes $plan, $files, $title, $what, $mr, $when, $fix and
# $attempt). Input: verdict.json.

# The judge's prose is loose markdown: paragraphs, "- " lists, `code` and
# **bold**. Escaped first, so nothing in it is ever markup.
def md: (. // "") | @html
  | gsub("`(?<c>[^`\n]+)`"; "<code>\(.c)</code>") | gsub("\\*\\*(?<b>[^*\n]+)\\*\\*"; "<strong>\(.b)</strong>")
  | gsub("(?m)^[-*] (?<l>.*)$"; "<li>\(.l)</li>")
  | gsub("</li>\n<li>"; "</li><li>")
  | gsub("\n*(?<l><li>.*</li>)\n*"; "\n\n<ul>\(.l)</ul>\n\n")
  | split("\n\n") | map(select(test("\\S")) | if startswith("<ul>") then . else "<p>" + gsub("\n"; "<br>") + "</p>" end) | join("");

def size: if . == 0 then "empty" elif . >= 1048576 then "\(. / 1048576 * 10 | floor / 10) MB" elif . >= 1024 then "\(. / 1024 | floor) KB" else "\(.) B" end;

def state: {verified: "pass", failed: "fail"}[.] // "open";
def mark: {verified: "✓", failed: "✗"}[.] // "?";
def said: {verified: "Verified", failed: "Failed"}[.] // "Not verified";

def css: "
:root {
  --ground: #f6f7f8; --surface: #ffffff; --ink: #15181d; --soft: #525a66; --faint: #8a919c; --rule: #e2e5e9; --code: #eef0f3;
  --pass: #17784a; --pass-bg: #e2f3e9; --fail: #bb2d23; --fail-bg: #fbe8e5; --open: #8a5f00; --open-bg: #f9efd6; --link: #1f5fbf;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme=\"light\"]) {
  --ground: #121418; --surface: #1a1d22; --ink: #e8eaee; --soft: #a3aab5; --faint: #6f7682; --rule: #2a2e35; --code: #242830;
  --pass: #5cc98e; --pass-bg: #163326; --fail: #f07b70; --fail-bg: #3a1c19; --open: #e2b24a; --open-bg: #362a10; --link: #86b1f5;
} }
:root[data-theme=\"dark\"] {
  --ground: #121418; --surface: #1a1d22; --ink: #e8eaee; --soft: #a3aab5; --faint: #6f7682; --rule: #2a2e35; --code: #242830;
  --pass: #5cc98e; --pass-bg: #163326; --fail: #f07b70; --fail-bg: #3a1c19; --open: #e2b24a; --open-bg: #362a10; --link: #86b1f5;
}
* { box-sizing: border-box; }
html { background: var(--ground); }
body { margin: 0; background: var(--ground); color: var(--ink); font: 16px/1.6 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
main { max-width: 820px; margin: 0 auto; padding: 56px 20px 96px; }
a { color: var(--link); text-decoration-thickness: 1px; text-underline-offset: 2px; }
p { margin: 0 0 10px; } p:last-child { margin-bottom: 0; }
ul { margin: 6px 0 10px; padding-left: 20px; } li { margin: 3px 0; }
code { font: 0.86em ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }

.meta { color: var(--soft); font-size: 14px; margin: 0 0 8px; }
h1 { font-size: 30px; line-height: 1.2; letter-spacing: -0.015em; margin: 0 0 20px; text-wrap: balance; }
.verdict { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; margin-bottom: 18px; }
.badge { font-weight: 650; font-size: 15px; padding: 3px 12px; border-radius: 6px; }
.badge.pass { color: var(--pass); background: var(--pass-bg); }
.badge.fail { color: var(--fail); background: var(--fail-bg); }
.badge.open { color: var(--open); background: var(--open-bg); }
.tally { color: var(--soft); font-size: 15px; }
.lede { font-size: 17px; }

h2 { font-size: 13px; font-weight: 650; text-transform: uppercase; letter-spacing: 0.08em; color: var(--soft); margin: 48px 0 12px; }
.concerns { color: var(--soft); font-size: 15px; }
.concerns li { margin: 8px 0; }

.claim { padding: 28px 0; border-top: 1px solid var(--rule); scroll-margin-top: 16px; }
.claim:last-child { border-bottom: 1px solid var(--rule); }
.claim-head { display: grid; grid-template-columns: 28px 1fr; gap: 0 12px; }
.dot { width: 28px; height: 28px; border-radius: 50%; display: grid; place-items: center; font-size: 14px; font-weight: 700; margin-top: 2px; }
.pass .dot { color: var(--pass); background: var(--pass-bg); }
.fail .dot { color: var(--fail); background: var(--fail-bg); }
.open .dot { color: var(--open); background: var(--open-bg); }
.cid { font-size: 13px; color: var(--faint); font-variant-numeric: tabular-nums; }
.cid b { font-weight: 600; }
.pass .cid b { color: var(--pass); } .fail .cid b { color: var(--fail); } .open .cid b { color: var(--open); }
.claim-text { font-size: 17px; font-weight: 600; line-height: 1.45; }
.claim-text ul { font-weight: 500; }
.claim-body { margin: 14px 0 0 40px; }
.finding { color: var(--soft); font-size: 15px; }

.shots { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 12px; margin-top: 16px; }
.shots button { all: unset; cursor: zoom-in; display: block; border-radius: 8px; overflow: hidden; border: 1px solid var(--rule); background: var(--surface); }
.shots button:focus-visible { outline: 2px solid var(--link); outline-offset: 2px; }
.shots img { display: block; width: 100%; height: auto; }
.clips { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 220px)); gap: 10px; margin-top: 12px; }
.clips video { display: block; width: 100%; border-radius: 6px; border: 1px solid var(--rule); background: #000; }

details { margin-top: 14px; font-size: 14px; }
summary { cursor: pointer; color: var(--soft); width: fit-content; }
summary:hover { color: var(--ink); }
.file { margin-top: 10px; border: 1px solid var(--rule); border-radius: 6px; background: var(--surface); overflow: hidden; }
.file-name { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 4px 12px; padding: 6px 12px; border-bottom: 1px solid var(--rule); font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; }
.file-name span { color: var(--faint); font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
.file pre { margin: 0; padding: 10px 12px; max-height: 360px; overflow: auto; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
.none { color: var(--fail); font-size: 14px; margin-top: 10px; }

.fix-claim { padding: 22px 0 6px; border-top: 1px solid var(--rule); }
.fix-claim .claim-text { font-size: 15px; margin-top: 2px; }
.pair { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 14px; }
.pair figure { margin: 0; min-width: 0; }
.pair figcaption { font-size: 12px; font-weight: 650; text-transform: uppercase; letter-spacing: 0.06em; margin-bottom: 6px; }
.pair .was { color: var(--fail); } .pair .now { color: var(--pass); }
.pair button { all: unset; cursor: zoom-in; display: block; border-radius: 6px; overflow: hidden; border: 1px solid var(--rule); background: var(--surface); }
.pair button:focus-visible { outline: 2px solid var(--link); outline-offset: 2px; }
.pair img { display: block; width: 100%; height: auto; }
.pair video { display: block; width: 100%; border-radius: 6px; border: 1px solid var(--rule); background: #000; }
.pair.clip { max-width: 460px; }
.pair .file { margin-top: 0; }

dialog { border: 0; padding: 0; background: transparent; max-width: 96vw; max-height: 96vh; }
dialog::backdrop { background: rgb(0 0 0 / 0.86); }
dialog img { display: block; max-width: 96vw; max-height: 96vh; cursor: zoom-out; }

@media (max-width: 560px) {
  main { padding-top: 32px; }
  h1 { font-size: 24px; }
  .claim-body { margin-left: 0; }
}
";

def script: "
const box = document.querySelector('dialog'), big = box.querySelector('img');
document.querySelectorAll('.shots button, .pair button').forEach(b => b.addEventListener('click', () => {
  big.src = b.querySelector('img').src; big.alt = b.title; box.showModal();
}));
box.addEventListener('click', () => box.close());
";

def claim($plan_by; $file):
  . as $c
  | ($c.artifacts // [] | map($file[.] // empty)) as $ev
  | ($ev | map(select(.kind == "image"))) as $shots
  | ($ev | map(select(.kind == "text"))) as $out
  | "<article class=\"claim \($c.result | state)\" id=\"\($c.id | @html)\">
<div class=\"claim-head\"><div class=\"dot\" aria-hidden=\"true\">\($c.result | mark)</div><div>
<div class=\"cid\">\($c.id | @html) · <b>\($c.result | said)</b></div>
<div class=\"claim-text\">\($plan_by[$c.id].claim | md)</div></div></div>
<div class=\"claim-body\">
<div class=\"finding\">\($c.evidence | md)</div>
\(if ($shots | length) > 0 then "<div class=\"shots\">" + ($shots | map("<button type=\"button\" title=\"\(.name | @html)\"><img loading=\"lazy\" src=\"\(.src)\" alt=\"\(.name | @html)\"></button>") | join("")) + "</div>" else "" end)
\($ev | map(select(.kind == "video")) | if length > 0 then "<div class=\"clips\">" + (map("<video controls preload=\"metadata\" src=\"\(.src)\" title=\"\(.name | @html)\"></video>") | join("")) + "</div>" else "" end)
\(if ($out | length) > 0 then "<details><summary>Output · \($out | length) file\(if ($out | length) == 1 then "" else "s" end)</summary>"
  + ($out | map("<div class=\"file\"><div class=\"file-name\">\(.name | @html)<span>\(.size | size)\(if .cut then ", cut to what matters and the end" else "" end)</span></div><pre>\(.text | @html)</pre></div>") | join(""))
  + "</details>" else "" end)
\(if ($ev | length) == 0 then "<p class=\"none\">Nothing the tester saved shows this.</p>" else "" end)
</div></article>";

# fixed: with a fix the judge accepted, what it changed and each failed
# claim's evidence before it, beside the same with it: the screenshot, the
# output, the recording. Then its test's run without the fix and with it, and
# the patch.
def fixed($plan_by; $file):
  if $fix == null then "" else
  ("-fix" + $attempt) as $tag
  | def text: "<div class=\"file\"><div class=\"file-name\">\(.name | @html)<span>\(.size | size)\(if .cut then ", cut" else "" end)</span></div><pre>\(.text | @html)</pre></div>";
    def one($f): if $f.kind == "image" then "<button type=\"button\" title=\"\($f.name | @html)\"><img loading=\"lazy\" src=\"\($f.src)\" alt=\"\($f.name | @html)\"></button>"
      elif $f.kind == "video" then "<video controls preload=\"metadata\" src=\"\($f.src)\" title=\"\($f.name | @html)\"></video>"
      else ($f | text) end;
    def pair($b; $a): "<div class=\"pair\(if $a.kind == "video" then " clip" else "" end)\"><figure><figcaption class=\"was\">Before</figcaption>\(one($b))</figure><figure><figcaption class=\"now\">With the fix</figcaption>\(one($a))</figure></div>";
    def rank: {image: 0, text: 1, video: 2}[.kind];
  [.criteria[] | select(.result == "failed")] as $failed
  | "<h2>With the fix</h2><div class=\"lede\"><p><strong>\($fix.title | @html)</strong></p>\($fix.summary | md)</div>"
  + ($failed | map(. as $c
      | [$file | to_entries[] | select(.key | startswith($c.id + $tag)) | .value
         | {after: ., before: $file[.name | sub($tag; "")]} | select(.before)]
      | sort_by(.after | rank)
      | if length == 0 then "" else
          "<div class=\"fix-claim\"><div class=\"cid\">\($c.id | @html)</div><div class=\"claim-text\">\($plan_by[$c.id].claim | md)</div>"
          + (map(pair(.before; .after)) | join("")) + "</div>"
        end) | join(""))
  + (if $file["fix\($attempt)-test-before.txt"] and $file["fix\($attempt)-test-after.txt"] then
      "<details><summary>The test it added, run without the fix and with it</summary>"
      + pair($file["fix\($attempt)-test-before.txt"]; $file["fix\($attempt)-test-after.txt"]) + "</details>" else "" end)
  + (if $file["fix-\($attempt).patch"] then "<details><summary>The patch</summary>\($file["fix-\($attempt).patch"] | text)</details>" else "" end)
  end;

def page:
  . as $v
  | ($plan[0].criteria | map({(.id): .}) | add // {}) as $plan_by
  | ($files | map({(.name): .}) | add // {}) as $file
  | ($v.criteria | length) as $all
  | ([$v.criteria[] | select(.result == "verified")] | length) as $ok
  | ([$v.criteria[] | select(.result == "failed") | .id] | join(", ")) as $failed
  | "<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>\($title | @html)</title>
<style>\(css)</style></head><body><main>
<header>
<p class=\"meta\">Verification of \(if $mr != "" then "<a href=\"\($mr | @html)\">\($what | @html)</a>" else "<code>\($what | @html)</code>" end)\(if $when != "" then " · " + $when else "" end)</p>
<h1>\($title | @html)</h1>
<div class=\"verdict\"><span class=\"badge \({pass: "pass", fail: "fail"}[$v.verdict] // "open")\">\({pass: "Passed", fail: "Failed"}[$v.verdict] // "Inconclusive")</span>
<span class=\"tally\">\(if $ok == $all then "All \($all) claims verified" else "\($ok) of \($all) claims verified" + (if $failed != "" then " · \($failed) failed" else "" end) end)</span></div>
<div class=\"lede\">\($v.summary | md)</div>
</header>
\(if ($v.concerns | length) > 0 then "<h2>Concerns</h2><ul class=\"concerns\">" + ($v.concerns | map("<li>" + (md | sub("^<p>"; "") | sub("</p>$"; "")) + "</li>") | join("")) + "</ul>" else "" end)
\($v | fixed($plan_by; $file))
<h2>Claims</h2>
<section>\($v.criteria | map(claim($plan_by; $file)) | join("\n"))</section>
</main><dialog><img alt=\"\"></dialog><script>\(script)</script></body></html>";
