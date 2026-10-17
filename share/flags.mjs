#!/usr/bin/env node
// flags.mjs <outline.json> [--now]: the design red flags a change brings in, by A Philosophy of Software Design
// and Simple Made Easy, each on the case whose route runs through it. Run behind the screen once a change's
// cases are told (git-sentences); the case list and the case's pane show what it leaves:
//   <key>.flags.json   what was found, for the pane
//   <key>.flags.tsv    a case's words, then its flag, a line each, for the list
// One Claude raises at most five flags it can pin to lines; otis checks each line is there; a second Claude
// tries to throw each one out (the base had it, the neighbours do it so, the smaller design is not smaller).
// Only what that leaves standing is shown, each with the comment a reviewer would leave on its line, which the
// case's pane types in for you when you comment there. Without --now, at most two run at once. otis.flagsModel picks the
// model, off for none.
import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";

const VERSION = 1;
const [file, ...rest] = process.argv.slice(2);
const now = rest.includes("--now");
const dir = dirname(file), key = basename(file, ".json");
const at = (end) => join(dir, `${key}.flags.${end}`);
const MAX = 1 << 30;
const git = (...args) => execFileSync("git", ["-c", "core.quotePath=false", ...args], { encoding: "utf8", maxBuffer: MAX, stdio: ["ignore", "pipe", "ignore"] });
const config = (name) => { try { return git("config", "--get", name).trim(); } catch { return ""; } };

const model = config("otis.flagsModel") || "claude-opus-5-5";
if (model === "off" || !existsSync(file)) process.exit(0);
const outline = JSON.parse(readFileSync(file, "utf8"));
const cases = (outline.sentences ?? []).filter((part) => part.kind === "case" || part.kind === "also");
if (!cases.length || !outline.base || !outline.head) process.exit(0);
const names = new Set(cases.map((part) => part.text));

// Found already for these cases: a flag on a case the change is no longer told with is looked for again.
try {
  const found = JSON.parse(readFileSync(at("json"), "utf8"));
  if (found.version === VERSION && found.flags.every((flag) => names.has(flag.case))) process.exit(0);
} catch { /* not found yet */ }
const alive = (path) => { try { process.kill(Number(readFileSync(path, "utf8")), 0); return true; } catch { return false; } };
if (alive(at("running"))) process.exit(0);
if (!now && readdirSync(dir).filter((name) => name.endsWith(".flags.running") && alive(join(dir, name))).length >= 2) process.exit(0);
writeFileSync(at("running"), String(process.pid));
const done = () => { try { unlinkSync(at("running")); } catch { /* gone */ } };
process.on("exit", done);

const { base, head } = outline;
const root = git("rev-parse", "--show-toplevel").trim();
const words = existsSync(join(dir, `${key}.words`)) ? readFileSync(join(dir, `${key}.words`), "utf8").trim() : "";

const commands = [
  "You can read the repository on both sides of the change with these commands, one per call, with no pipes:",
  `  git -C ${root} grep -n -e <pattern> ${head} -- <paths>      search the code after the change (${base} for before)`,
  `  git -C ${root} grep -n -e '' ${head} -- <path>              a whole file, every line numbered`,
  `  git -C ${root} show ${head}:<path>`,
  `  git -C ${root} log --format=%h%x09%s ${base}..${head}     the change's commits`,
].join("\n");
const authorWords = [
  "# The author's words", "", "## title", outline.title || "(none)", "", "## merge request description", words || "(none)", "",
  git("log", "--reverse", "--no-merges", "--format=## commit %h%n%s%n%n%b", `${base}..${head}`).trim(),
].join("\n");

// The change itself, each changed function whole; tests after, cut when the whole is too big to read.
const code = git("diff", "--no-color", "--no-ext-diff", "-W", base, head, "--", ".", ":(exclude)*test*", ":(exclude)*spec*", ":(exclude)*.snap", ":(exclude)*lock*");
const tests = git("diff", "--no-color", "--no-ext-diff", "-U3", base, head, "--", "*test*", "*spec*");
const ROOM = 400000;
const diff = code.length > ROOM ? code.slice(0, ROOM) + "\n[cut: read the rest with the commands]" : code + (tests ? "\n" + tests.slice(0, ROOM - code.length) : "");

const unmark = (text) => (text ?? "").replace(/`/g, "");
const caseText = (part, i) => [
  `## Case ${i + 1}: ${part.text}  (${part.group ?? ""})`,
  ...(part.setup ? [`setup: ${unmark(part.setup)}`] : []),
  `before: ${part.was || "(nothing ran)"}   now: ${part.now || ""}   (${part.change ?? ""})`,
  ...(part.ends ? [`ends: ${unmark(part.ends)}`] : []),
  "route:",
  ...(part.stops ?? []).flatMap((stop) => [`  ${stop.name}  ${stop.path} (${stop.side}): ${unmark(stop.is)}`,
    ...(stop.lines ?? []).map((line) => `    ${line.n}: ${(line.t ?? "").trim()}${line.value ? `   -- ${unmark(line.value)}` : ""}`)]),
].join("\n");

const object = (properties) => ({ type: "object", additionalProperties: false, required: Object.keys(properties), properties });
const list = (items) => ({ type: "array", items });
const text = { type: "string" };
const lineRef = object({ path: text, side: { enum: ["new", "old"] }, line: { type: "integer" }, code: text });
const KINDS = {
  shallow: "a function, class, module or layer the change adds whose interface is about as much to learn as what it does: a pass-through that hands its arguments on, a wrapper that only renames, a class of small methods each a line long",
  leak: "one piece of knowledge (a format, a rule, a magic value, which order things must happen in, how a key is built) written in two or more places, so the next change to it must find and change every one",
  "special case": "a particular case (one customer, one channel, one mode) handled by an if inside code that is otherwise general, where a different contract would make the case disappear",
  "two jobs": "one function or type doing two things chosen by a boolean or mode argument; state braided with the decisions made about it; policy mixed with mechanism; what tangled with how",
  exposure: "callers made to know or pass something they should not need (a setting every caller passes the same, an internal step they must call first, a field only one of them uses)",
  defensive: "checks, fallbacks or try/catch for cases this code's own types or callers already rule out, which hide where the real guarantee lives",
  "wrong layer": "a fix or feature placed where the symptom shows instead of where the cause is, so the design is worse than before and the next case needs the same patch",
  bespoke: "a new type, class, registry or indirection where plain data and a function or two would do",
  "unlike its neighbours": "does what nearby code already does, in a different way, so a reader must learn two",
};

const ask = (prompt, schema) => new Promise((resolve) => {
  const empty = mkdtempSync(join(tmpdir(), "otis-flags-"));
  execFile(process.env.SEAM_CLAUDE || "claude", [
    "-p", "--model", model, "--restricted", "--tools", "Bash", "--add-dir", root,
    "--allowedTools", `Bash(git -C ${root} grep:*)`, `Bash(git -C ${root} show:*)`, `Bash(git -C ${root} log:*)`,
    "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--permission-prompts", "none",
    "--max-budget-usd", "8", "--output-format", "json", "--json-schema", JSON.stringify(schema),
  ], { cwd: empty, encoding: "utf8", maxBuffer: MAX, timeout: 1800000 }, (error, out) => {
    rmSync(empty, { recursive: true, force: true });
    try { resolve(JSON.parse(out).structured_output ?? null); } catch { resolve(null); }
  }).stdin.end(prompt);
});

const raised = await ask([
  "You are reviewing the design of a code change, by the standards of John Ousterhout's A Philosophy of Software Design and Rich Hickey's Simple Made Easy. Not bugs: design. Raise the design red flags this change brings in, at most five, worst first. A second reviewer will try to throw each one out before anyone sees it, so raise what you can pin to lines even when you are not sure; leave out what you cannot.",
  "",
  "The change has already been told as cases below: concrete situations its code meets, each followed through the code. Use them to learn what each piece is for. Its diff is at the bottom, each changed function whole.",
  "",
  commands,
  "",
  "The red flags:",
  ...Object.entries(KINDS).map(([name, what]) => `- ${name}: ${what}`),
  "",
  "The bar: it will cost real effort the next time someone changes this code, or it makes the code harder to understand than it has to be, and a smaller design exists that you can name concretely. Not a red flag: style, naming, formatting, missing tests, missing comments; anything the code before the change already had (this change must add it or make it worse); a choice the codebase makes the same way everywhere (git grep the neighbours: when nearby code does it this way too, it is the codebase's convention, not this change's flag).",
  "",
  "How to look: read the diff whole. For each new function, type or layer, ask what a caller must learn to use it against what it hides. For each value, rule or format the change writes down, git grep for the same knowledge elsewhere. For each new if, ask whether it is a special case a different contract would remove. Read the neighbouring code the change sits in, and how nearby code does the same job. Use the commands: 10 to 40 of them.",
  "",
  "For each flag:",
  "- case: the number of the case it belongs to: the one whose route runs through it, or else the one closest to it",
  "- flag: which red flag",
  "- claim: one or two plain sentences: what is wrong, concretely, in this code",
  "- cost: what the next person to change this code has to do because of it, concretely (\"adding a new channel means editing these three switches\")",
  "- line: the line in code this change adds where it is (path, side \"new\", line number, code copied exactly)",
  "- caller: the other line it involves: the second copy of the knowledge, the caller that must know, the function a wrapper hands on to (path, side, line number, code copied exactly)",
  "- smaller: the smaller design, concretely: which function goes, what moves where, what the interface becomes",
  "- comment: what a reviewer would leave on that line for the author, as a teammate texts: one short question that suggests the smaller design, under 20 words, plain words, no red flag's name (\"Could `sendReminder` take the channel, rather than each caller switching on it?\")",
  "",
  "In claim, cost, smaller and comment, put each name from the code in backticks, like `needsJudgment`, and nothing else in markdown.",
  "",
  authorWords,
  "",
  "# The cases",
  "",
  ...cases.map(caseText).flatMap((one) => [one, ""]),
  "# The change's diff, base to head",
  "",
  diff,
].join("\n"), object({
  flags: list(object({ case: { type: "integer" }, flag: { enum: Object.keys(KINDS) }, claim: text, cost: text, line: lineRef, caller: lineRef, smaller: text, comment: text })),
}));

// otis's check: the cited code is there, at its line or near it (a number counted off a diff's hunk drifts).
const shown = new Map();
function cited(ref) {
  const sha = ref.side === "old" ? base : head;
  if (!shown.has(`${sha}:${ref.path}`)) { try { shown.set(`${sha}:${ref.path}`, git("show", `${sha}:${ref.path}`).split("\n")); } catch { shown.set(`${sha}:${ref.path}`, null); } }
  const lines = shown.get(`${sha}:${ref.path}`), squash = (s) => s.replace(/\s+/g, "");
  if (!lines || !squash(ref.code)) return false;
  for (let d = 0; d <= 25; d++) for (const n of [ref.line - d, ref.line + d]) {
    if (n >= 1 && lines[n - 1] != null && squash(lines[n - 1]).includes(squash(ref.code))) { ref.line = n; return true; }
  }
  return false;
}
// A run that answered nothing is asked again the next time, never kept as a change with no flags.
if (!raised) { writeFileSync(at("err"), "flags: Claude gave no answer\n"); process.exit(1); }
const pinned = raised.flags.filter((flag) => cases[flag.case - 1] && cited(flag.line) && cited(flag.caller));

let standing = [];
if (pinned.length) {
  const judged = await ask([
    "Someone has raised the design red flags below against a code change, by the standards of John Ousterhout's A Philosophy of Software Design and Rich Hickey's Simple Made Easy. Your job is to throw each one out. Most such flags are taste dressed up as principle. For each, read the code yourself at both commits and look for:",
    "- the code before the change already doing the same, so this change did not bring it in",
    "- neighbouring code doing it the same way, so it is the codebase's convention",
    "- the smaller design not being smaller: it moves the complexity somewhere else, loses something the code needs, or would make this change much bigger for little gain",
    "- a reason in the code, a comment or the author's words that makes the choice right here",
    "- the flag misreading what the code does, or naming the wrong red flag",
    "",
    "verdict: disproved when you find any of these (say which, with the line); minor when it is true but cheap: the next change pays a few minutes for it, or it is about naming or style; stands only when you looked for each of these and found none, the smaller design is real and you can see it, and you would bet that Ousterhout reading these lines would ask for the change before it merges; unsure otherwise. why: one or two plain sentences, each name from the code in backticks.",
    "",
    commands,
    "",
    authorWords,
    "",
    "# The flags",
    "",
    ...pinned.flatMap((flag, i) => [
      `## Flag ${i + 1} (${flag.flag})`, flag.claim, `cost: ${flag.cost}`,
      `where: ${flag.line.path}:${flag.line.line} (${flag.line.side}): ${flag.line.code.trim()}`,
      `also: ${flag.caller.path}:${flag.caller.line} (${flag.caller.side}): ${flag.caller.code.trim()}`,
      `smaller: ${flag.smaller}`, "",
    ]),
  ].join("\n"), object({ verdicts: list(object({ flag: { type: "integer" }, verdict: { enum: ["stands", "minor", "disproved", "unsure"] }, why: text })) }));
  standing = (judged?.verdicts ?? []).filter((one) => one.verdict === "stands" && pinned[one.flag - 1])
    .map((one) => ({ ...pinned[one.flag - 1], why: one.why }));
}

const flags = standing.map(({ case: n, ...flag }) => ({ case: cases[n - 1].text, ...flag }));
const write = (path, body) => { writeFileSync(path + ".new", body); renameSync(path + ".new", path); };
write(at("tsv"), flags.map((flag) => `${flag.case.replace(/[\t\n]/g, " ")}\t${flag.flag}\n`).join(""));
write(at("json"), JSON.stringify({ version: VERSION, model, base, head, raised: raised?.flags?.length ?? null, flags }));
