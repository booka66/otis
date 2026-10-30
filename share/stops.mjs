#!/usr/bin/env node
// stops.mjs <base> <head> --cache <dir> --table <symbols.tsv>: the few places in a change where a person has to decide
// something, written beside its cases and read by the same list and pane:
//   <base>-<head>.stops.json   { stops }, each a question, why it is one, and its code, for the pane (story-pane.mjs)
//   <base>-<head>.stops.tsv    the list's rows, as a case's are (git-symbols)
// Lines moved or renamed are counted here, without Claude, and left out of what Claude reads, so a stop is on code the
// change really brings. A stop is a place to start and never says the rest is fine: on 8 reviews, 5 of 28 people's
// comments landed on one. In a review (GMR_IID) Claude reads its description. otis.stopsModel picks the model, off for none.
import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, renameSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [base, head, ...rest] = process.argv.slice(2);
const opt = (name) => { const at = rest.indexOf(name); return at < 0 ? "" : rest[at + 1]; };
const dir = opt("--cache");
const at = (end) => join(dir, `${base}-${head}.stops.${end}`);
const MAX = 1 << 30, MOST = 5, AROUND = 3;
const git = (...args) => execFileSync("git", ["-c", "core.quotePath=false", ...args], { encoding: "utf8", maxBuffer: MAX, stdio: ["ignore", "pipe", "ignore"] });
const config = (name) => { try { return git("config", "--get", name).trim(); } catch { return ""; } };

const model = config("otis.stopsModel") || config("otis.sentencesModel") || "claude-opus-5-5";
if (model === "off" || existsSync(at("json"))) process.exit(0);
const alive = (path) => { try { process.kill(Number(readFileSync(path, "utf8")), 0); return true; } catch { return false; } };
if (alive(at("running"))) process.exit(0);
writeFileSync(at("running"), String(process.pid));
process.on("exit", () => { try { unlinkSync(at("running")); } catch { /* gone */ } });

// What nobody reads line by line: generated files, translations, lockfiles and build lists.
const SKIP = /(^|\/)i18n\/catalogs\/|BUILD\.bazel$|lock(\.\w+)?$|\.snap$|(^|\/)package\.json$|(^|\/)tsconfig[^/]*\.json$/;
const IDENT = /[A-Za-z_$][A-Za-z0-9_$]*/g;

// Every added line with where it is, every removed line's text: renames off, so a move shows as a delete and an add.
function changes() {
  const added = [], removed = [];
  let path = null, n = 0;
  for (const line of git("diff", "--no-color", "--no-ext-diff", "--no-renames", "-U0", base, head).split("\n")) {
    if (line.startsWith("+++ ")) path = line.slice(6);
    else if (line.startsWith("--- ") || line.startsWith("diff ")) continue;
    else if (line.startsWith("@@")) n = Number(/\+(\d+)/.exec(line)[1]);
    else if (path && !SKIP.test(path) && line.slice(1).trim()) {
      if (line[0] === "+") added.push({ path, n, text: line.slice(1).trim() });
      else if (line[0] === "-") removed.push(line.slice(1).trim());
    }
    if (line[0] === "+" && !line.startsWith("+++ ")) n++;
  }
  return { added, removed };
}
const tally = (texts) => { const seen = new Map(); for (const text of texts) seen.set(text, (seen.get(text) ?? 0) + 1); return seen; };
const take = (pool, key) => { const left = pool.get(key) ?? 0; if (left) pool.set(key, left - 1); return left > 0; };
const wordsOf = (texts) => new Set(texts.flatMap((text) => text.match(IDENT) ?? []));

// The added lines left once those moved (the same text removed elsewhere) and those renamed (the same once the words
// found on one side alone are blanked) are taken out.
function leftover({ added, removed }) {
  const pool = tally(removed);
  const unmoved = added.filter((one) => !take(pool, one.text));
  const gone = [...pool].flatMap(([text, count]) => Array(count).fill(text));
  const newWords = wordsOf(unmoved.map((one) => one.text)), oldWords = wordsOf(gone);
  const blank = (text, keep) => text.replace(IDENT, (word) => (keep.has(word) ? word : "_"));
  const renamed = tally(gone.map((text) => blank(text, newWords)));
  return unmoved.filter((one) => !take(renamed, blank(one.text, oldWords)));
}

// The table is the screen's, and gone if you leave before Claude answers.
const table = (() => { try { return readFileSync(opt("--table"), "utf8").split("\n").map((row) => row.split("\t")); } catch { return []; } })();
const change = changes();
const fresh = leftover(change);
const isNew = new Set(fresh.map((one) => `${one.path}\t${one.n}`));

const root = git("rev-parse", "--show-toplevel").trim();
const mr = (() => {
  try { return JSON.parse(execFileSync("git-forge", ["api", `projects/:fullpath/merge_requests/${process.env.GMR_IID}`], { encoding: "utf8", maxBuffer: MAX, stdio: ["ignore", "pipe", "ignore"] })); } catch { return {}; }
})();
const authorWords = [
  "# The author's words", "", "## title", mr.title || "(none)", "", "## merge request description", mr.description || "(none)", "",
  git("log", "--reverse", "--no-merges", "--format=## commit %h%n%s%n%n%b", `${base}..${head}`).trim(),
].join("\n");
const byFile = new Map();
for (const one of fresh) byFile.set(one.path, [...(byFile.get(one.path) ?? []), one]);
const ROOM = 300000;
const shown = [...byFile].map(([path, lines]) => [`## ${path}`, ...lines.map((one) => `${one.n}: ${one.text}`)].join("\n")).join("\n\n");

const object = (properties) => ({ type: "object", additionalProperties: false, required: Object.keys(properties), properties });
const text = { type: "string" };
const schema = object({ stops: { type: "array", items: object({
  question: text, why: text, path: text, line: { type: "integer" }, to: { type: "integer" }, code: text, note: text, noteLine: { type: "integer" }, comment: text,
}) } });

function ask(prompt) {
  return new Promise((resolve) => {
    const empty = mkdtempSync(join(tmpdir(), "otis-stops-"));
    execFile(process.env.SEAM_CLAUDE || "claude", [
      "-p", "--model", model, "--restricted", "--tools", "Bash", "--add-dir", root,
      "--allowedTools", `Bash(git -C ${root} grep:*)`, `Bash(git -C ${root} show:*)`, `Bash(git -C ${root} log:*)`,
      "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--permission-prompts", "none",
      "--max-budget-usd", "5", "--output-format", "json", "--json-schema", JSON.stringify(schema),
    ], { cwd: empty, encoding: "utf8", maxBuffer: MAX, timeout: 900000 }, (error, out) => {
      rmSync(empty, { recursive: true, force: true });
      try { resolve(JSON.parse(out).structured_output ?? null); } catch { resolve(null); }
    }).stdin.end(prompt);
  });
}

const answer = !fresh.length ? { stops: [] } : await ask([
  "A reviewer can't read every line of this change. Tests, CI and bots already look for bugs. Your job is to find the few places where a person has to decide something, and hand them over as questions, most important first.",
  "",
  `Ask at most ${MOST}, and fewer is better: a small change may need one, and a change with nothing to decide needs none. Empty is a good answer.`,
  "",
  "What is worth a stop:",
  "- a shape someone will live with: a new layer, interface, schema or shared helper, and whether it should exist or be this big (who else calls it? does a second caller exist yet?)",
  "- a choice with consequences the code can't show: what's stored, what's sent, what's hard to undo, what merchants or shoppers will see",
  "- something that goes further than, or differently from, what the author says",
  "",
  "What is not: style, naming, a missing test, a guess at a bug, or anything you could settle by reading the code. If you can answer the question yourself, read the code and answer it instead of asking. Check who calls what before you say so.",
  "",
  "You can read the repository on both sides of the change, one command per call, no pipes:",
  `  git -C ${root} grep -n -e <pattern> ${head} -- <paths>      search after the change (${base} for before)`,
  `  git -C ${root} grep -n -e '' ${head} -- <path>              a whole file, every line numbered`,
  `  git -C ${root} show ${head}:<path>`,
  "",
  "For each stop:",
  "- question: the decision, in under 10 plain words, as a question a teammate would ask",
  "- why: one or two plain sentences with the fact that makes it a question, from the code (\"nine inputs and one caller\")",
  "- path, line, to: the smallest stretch of the file after the change that the reader needs to answer it, at most 60 lines",
  "- code: the text of the first of those lines, copied exactly",
  "- noteLine and note: the line in that stretch that matters most, and what to look at there, under 12 words",
  "- comment: what the reviewer would leave on that line if the answer is no, as a teammate texts: one short question, under 20 words",
  "",
  "Put each name from the code in backticks, and nothing else in markdown.",
  "",
  authorWords,
  "",
  `# The change, without the ${change.added.length - fresh.length} of ${change.added.length} added lines that only moved or were renamed. Each is its line number after the change.`,
  "",
  shown.length > ROOM ? shown.slice(0, ROOM) + "\n[cut: read the rest with the commands]" : shown,
].join("\n"));

// A run that answered nothing is asked again the next time, never kept as a change with nothing to decide.
if (!answer) { writeFileSync(at("err"), "stops: Claude gave no answer\n"); process.exit(1); }

const textOf = new Map();
const fileLines = (path) => {
  if (!textOf.has(path)) { try { textOf.set(path, git("show", `${head}:${path}`).split("\n")); } catch { textOf.set(path, null); } }
  return textOf.get(path);
};
// otis's check: the first line is where Claude says, or near it (a number counted off a hunk drifts); a stop on code
// that isn't there is dropped. A stop on one line is no use without the lines around it, so each comes with a few.
const squash = (s) => (s ?? "").replace(/\s+/g, "");
function placed(stop) {
  const lines = fileLines(stop.path);
  if (!lines || !squash(stop.code)) return null;
  for (let d = 0; d <= 25; d++) for (const n of [stop.line - d, stop.line + d]) {
    if (n >= 1 && lines[n - 1] != null && squash(lines[n - 1]).includes(squash(stop.code))) {
      const shift = n - stop.line, to = Math.max(n, stop.to + shift);
      return { ...stop, line: Math.max(1, n - AROUND), to: Math.min(lines.length, to + AROUND), noteLine: stop.noteLine + shift };
    }
  }
  return null;
}
const stops = answer.stops.slice(0, MOST).map(placed).filter(Boolean).map(({ code, ...stop }) => stop);

// Each line colored as its whole file colors it (bat, the theme's), as a case's are.
const theme = process.env.OTIS_T_BAT;
function painted(path) {
  try {
    return execFileSync("bat", ["--color=always", "--style=plain", "--paging=never", "--wrap=never", ...(theme ? [`--theme=${theme}`] : []), `--file-name=${path}`],
      { encoding: "utf8", maxBuffer: MAX, input: fileLines(path).join("\n") + "\n", stdio: ["pipe", "pipe", "ignore"] }).split("\n");
  } catch { return []; }
}
const paints = new Map(stops.map((stop) => stop.path).filter((path, i, all) => all.indexOf(path) === i).map((path) => [path, painted(path)]));
const told = stops.map(({ line, to, ...stop }) => ({ ...stop, line, to, code: Array.from({ length: to - line + 1 }, (_, i) => line + i).map((n) => ({
  n, t: fileLines(stop.path)[n - 1], paint: paints.get(stop.path)[n - 1] ?? null, new: isNew.has(`${stop.path}\t${n}`),
})) }));

// What's under a stop in the symbol table, so its row opens to them and v takes them, as a case's do.
function under(stop) {
  const symbols = table.filter((row) => row[0] === stop.path && row[1] !== "file" && row[6] === "new" && Number(row[7]) <= stop.to && Number(row[8]) >= stop.line);
  if (symbols.length) return symbols.map((row) => ["symbol", row[0], row[6], row[7]]);
  return table.some((row) => row[0] === stop.path && row[1] === "file") ? [["file", stop.path, "", ""]] : [];
}

// The list's rows, in the shape it reads a case's: a stop is numbered past any case, stop k as 1000 + k.
const clean = (s) => s.replace(/`/g, "").replace(/[\t\n]/g, " ");
const name = (path) => path.slice(path.lastIndexOf("/") + 1);
const lineCount = told.reduce((sum, stop) => sum + stop.code.length, 0);
const moved = change.added.length - fresh.length;
const said = [told.length ? "" : "no stops", moved ? `${moved.toLocaleString("en-US")} of ${change.added.length.toLocaleString("en-US")} added lines only moved` : ""].filter(Boolean).join(" · ");
const rows = [
  ["H", `${told.length} stop${told.length === 1 ? "" : "s"}, ${lineCount} lines`, said],
  ...told.flatMap((stop, k) => [
    ["S", 1001 + k, "stop", k + 1, 0, 0, clean(stop.question), 0, "", `${stop.code.length} lines in ${name(stop.path)}`, "", "", ""],
    ...under(stop).map((unit) => ["R", 1001 + k, ...unit]),
  ]),
];
const write = (path, body) => { writeFileSync(path + ".new", body); renameSync(path + ".new", path); };
write(at("tsv"), rows.map((row) => row.join("\t") + "\n").join(""));
write(at("json"), JSON.stringify({ version: 1, model, base, head, stops: told }));
