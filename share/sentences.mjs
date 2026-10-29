#!/usr/bin/env node
// sentences.mjs <base> <head> [--words f] [--title t] [--label l] [--model m] [--cache dir] [--json|--html out]
// A change as the author's own sentences, each with the symbols behind it and each symbol's lines.
import { execFile, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const started = Date.now();
const argv = process.argv.slice(2);
const flag = (name) => { const at = argv.indexOf(name); return at < 0 ? null : argv.splice(at, 2)[1]; };
const has = (name) => { const at = argv.indexOf(name); if (at < 0) return false; argv.splice(at, 1); return true; };
const wordsFile = flag("--words"), titleArg = flag("--title"), labelArg = flag("--label"), htmlOut = flag("--html");
const cacheDir = flag("--cache"), modelArg = flag("--model"), outlineOut = flag("--outline"), asJson = has("--json");
const [baseArg, headArg] = argv;
if (!baseArg || !headArg) { console.error("sentences.mjs <base> <head> [--words <file>] [--json | --html <out>]"); process.exit(2); }

const MAX = 1 << 30;
const git = (...args) => execFileSync("git", ["-c", "core.quotePath=false", ...args], { encoding: "utf8", maxBuffer: MAX, stdio: ["ignore", "pipe", "ignore"] });
const later = (command, args) => new Promise((done) => {
  execFile(command, args, { encoding: "utf8", maxBuffer: MAX }, (error, out) => done(error ? null : out)).stdin.end();
});
const base = git("rev-parse", baseArg).trim(), head = git("rev-parse", headArg).trim();
const root = git("rev-parse", "--show-toplevel").trim();
const short = (sha) => sha.slice(0, 11);

// The author's words: every commit's message, and the merge request's description when there is one.
const commits = git("log", "--reverse", "--no-merges", "--format=%H\x1f%s\x1f%b\x1e", `${base}..${head}`)
  .split("\x1e").map((entry) => entry.replace(/^\n/, "")).filter(Boolean)
  .map((entry) => { const [sha, subject, body] = entry.split("\x1f"); return { sha, subject, body: (body || "").trim() }; });
const description = wordsFile && existsSync(wordsFile) ? readFileSync(wordsFile, "utf8").trim() : "";

/** The two trees' diff with each file whole, as lines that know both of their numbers. */
function parseDiff(text) {
  const files = new Map();
  let file = null, oldAt = 0, newAt = 0, oldLeft = 0, newLeft = 0;
  for (const line of text.split("\n")) {
    if (oldLeft > 0 || newLeft > 0) {
      const sign = line[0], body = line.slice(1);
      if (sign === "+") { file.lines.push({ s: "+", n: newAt++, t: body }); newLeft--; }
      else if (sign === "-") { file.lines.push({ s: "-", o: oldAt++, t: body }); oldLeft--; }
      else if (sign === "\\") continue;
      else { file.lines.push({ s: " ", o: oldAt++, n: newAt++, t: body }); oldLeft--; newLeft--; }
      continue;
    }
    if (line.startsWith("diff --git ")) {
      const both = line.slice("diff --git a/".length);
      file = { path: both.slice(0, (both.length - 3) / 2), lines: [], binary: false, added: false, deleted: false };
      files.set(file.path, file);
    } else if (!file) continue;
    else if (line.startsWith("new file mode")) file.added = true;
    else if (line.startsWith("deleted file mode")) file.deleted = true;
    else if (line.startsWith("Binary files ")) file.binary = true;
    else if (line.startsWith("@@ ")) {
      const m = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
      oldAt = Number(m[1]); oldLeft = m[2] == null ? 1 : Number(m[2]);
      newAt = Number(m[3]); newLeft = m[4] == null ? 1 : Number(m[4]);
    }
  }
  return files;
}

const seamOf = (range) => later("seam", [range, "--json"]).then((out) => { try { return JSON.parse(out); } catch { return null; } });
const perCommit = commits.length > 1 && commits.length <= 24;
const [graph, ...commitGraphs] = await Promise.all([
  seamOf(`${base}..${head}`),
  ...(perCommit ? commits.map((commit) => seamOf(`${commit.sha}~..${commit.sha}`)) : []),
]);
const files = parseDiff(git("diff", "--no-color", "--no-ext-diff", "--no-renames", "-U1000000", base, head));
const commitFiles = commits.map((commit) => new Set(git("diff-tree", "--no-commit-id", "--name-only", "-r", commit.sha).split("\n").filter(Boolean)));

const TESTISH = /(^|[\/._-])(tests?|specs?|e2e|pe2e|__tests__)([\/._-]|$)/i;
// What seam says each changed file is (tests, gen, cfg or source): on its definitions, or the file's own row.
const kinds = new Map([...(graph?.definitions ?? []), ...(graph?.files ?? [])].map((one) => [one.path, one.box?.kind]));
const testFiles = new Set([...kinds].filter(([, kind]) => kind === "tests").map(([path]) => path));
for (const path of files.keys()) if (TESTISH.test(path)) testFiles.add(path);
// Cases run through the meat of the change: never its tests, generated files or build wiring, which the files
// tab keeps under headings of their own.
const wiring = (path) => kinds.get(path) === "gen" || kinds.get(path) === "cfg";
const meat = (path) => !testFiles.has(path) && !TESTISH.test(path) && !wiring(path);

const COMMENT = /^\s*(\/\/|\/\*|\*|#(?![!\[])|--\s|"""|''')/;
const KIND = { fn: "fn", constfn: "fn", method: "fn", const: "const", var: "const", interface: "type", type: "type", enum: "type", class: "class" };
const MARK = { added: "new", removed: "removed" };
const indent = (text) => { let width = 0; for (const ch of text) { if (ch === " ") width++; else if (ch === "\t") width += 2; else break; } return width; };

/** Every row the outline can show: a symbol, a test, or what a file changed outside both. */
const units = [];
const unitsByFile = new Map();
const addUnit = (unit) => {
  units.push(unit);
  if (!unitsByFile.has(unit.path)) unitsByFile.set(unit.path, []);
  unitsByFile.get(unit.path).push(unit);
  return unit;
};
for (const def of graph?.definitions ?? []) {
  if (!files.has(def.path)) continue;
  const old = def.side === "old";
  addUnit({
    id: def.id, path: def.path, name: def.class ? `${def.class}.${def.name}` : def.name, kind: KIND[def.kind] ?? def.kind,
    mark: MARK[def.change] ?? "changed", signature: def.change === "signature", symbol: true, test: testFiles.has(def.path),
    now: old ? null : [def.start, def.end], was: def.base ? [def.base.start, def.base.end] : old ? [def.start, def.end] : null,
  });
}

/** A test file's tests, each as the lines from its opening call to its close, found by indentation. */
const OPENER = /^\s*(it|test|describe|context|specify|scenario)\b((?:\.\w+)*)\s*[(`"']/;
function testBlocks(headLines) {
  const blocks = [];
  for (let i = 0; i < headLines.length; i++) {
    const text = headLines[i].t;
    let title = null, cases = null, suite = false;
    const js = OPENER.exec(text);
    if (js) {
      const joined = headLines.slice(i, i + 12).map((line) => line.t.trim()).join(" ");
      let rest = joined.slice(joined.indexOf(js[1]) + js[1].length + js[2].length).trimStart();
      if (js[2].includes(".each") && rest[0] === "(") {
        let depth = 0, at = 0;
        for (; at < rest.length; at++) { if (rest[at] === "(") depth++; else if (rest[at] === ")" && --depth === 0) break; }
        const inner = rest.slice(1, at);
        const each = /^\s*\[\s*\[/.test(inner) ? /\[\s*(["'`])((?:(?!\1).)*)\1/g : /(["'`])((?:(?!\1).)*)\1/g;
        const literals = [...inner.matchAll(each)].map((m) => m[2]);
        if (literals.length && literals.join(", ").length <= 48) cases = literals.join(", ");
        rest = rest.slice(at + 1).trimStart();
      } else if (js[2].includes(".each") && rest[0] === "`") {
        rest = rest.slice(rest.indexOf("`", 1) + 1).trimStart();
      }
      const named = /^\(?\s*(["'`])((?:\\.|(?!\1).)*)\1/.exec(rest);
      if (!named) continue;
      title = named[2];
      suite = /^(describe|context)$/.test(js[1]);
    } else {
      const other = /^\s*(?:async\s+)?def\s+(test\w*)|^func\s+(Test\w+)\s*\(|^\s*class\s+(Test\w+)/.exec(text)
        ?? (/^\s*(?:pub\s+)?(?:async\s+)?fn\s+\w+/.test(text) && /#\[(\w+::)*test/.test(headLines[i - 1]?.t ?? "") ? /fn\s+(\w+)/.exec(text) : null);
      if (!other) continue;
      title = other[1] ?? other[2] ?? other[3];
      suite = Boolean(other[3]);
    }
    const depth = indent(text);
    let end = headLines.length - 1;
    for (let j = i + 1; j < headLines.length; j++) {
      const next = headLines[j].t, trimmed = next.trim();
      if (!trimmed) continue;
      const at = indent(next);
      if (at > depth) continue;
      if (at === depth && /^([\])}]|end\b)/.test(trimmed)) {
        if (/[({[,]$|=>$/.test(trimmed)) continue;
        end = j;
      } else end = j - 1;
      break;
    }
    while (end > i && !headLines[end].t.trim()) end--;
    let first = i;
    while (first > 0 && COMMENT.test(headLines[first - 1].t) && indent(headLines[first - 1].t) >= depth) first--;
    blocks.push({ title, cases, suite, from: headLines[first].n, to: headLines[end].n, first, last: end });
  }
  return blocks;
}

for (const [path, file] of files) {
  if (file.binary || !testFiles.has(path)) continue;
  const headLines = file.lines.filter((line) => line.n != null);
  const blocks = testBlocks(headLines);
  // Each test its own row, so each goes with the part of the change it checks; a suite keeps only what
  // is its own (its setup, its helpers), none of its tests' lines.
  for (const block of blocks) {
    const allNew = headLines.slice(block.first, block.last + 1).every((line) => line.s === "+");
    addUnit({
      id: `${path}#test:${block.from}:${block.title}`, path, name: block.title, cases: block.cases, prose: true, test: true, block: true,
      kind: block.suite ? "suite setup" : "test", mark: allNew ? "new" : "changed", now: [block.from, block.to], was: null, container: block.suite,
    });
  }
}

// Each changed line belongs to the smallest row around it, and to the file's own row when none is.
const span = (range) => (range ? range[1] - range[0] : Infinity);
const holds = (unit, line) => (line.s === "+" ? unit.now && line.n >= unit.now[0] && line.n <= unit.now[1]
  : unit.block ? line.near != null && line.near >= unit.now[0] && line.near <= unit.now[1]
  : unit.was && line.o >= unit.was[0] && line.o <= unit.was[1]);
for (const [path, file] of files) {
  const here = [...(unitsByFile.get(path) ?? [])];
  const state = file.added ? "new" : file.deleted ? "removed" : "changed";
  const restOf = (kind) => ({ id: `${path}#rest`, path, name: basename(path), prose: true, rest: true, test: testFiles.has(path), kind, mark: state });
  if (file.binary) { addUnit({ ...restOf("binary file"), binary: true }); continue; }
  let position = null;
  for (let i = file.lines.length - 1; i >= 0; i--) {
    if (file.lines[i].n != null) position = file.lines[i].n;
    else file.lines[i].near = position;
  }
  let rest = null;
  for (const line of file.lines) {
    if (line.s === " ") continue;
    let owner = null;
    for (const unit of here) if (holds(unit, line) && (!owner || span(unit.now ?? unit.was) < span(owner.now ?? owner.was))) owner = unit;
    if (!line.t.trim() && (!owner || owner.container)) continue;
    line.owner = owner ?? (rest ??= addUnit(restOf(here.length ? "outside any symbol" : "whole file")));
  }
}

/** A row's lines: its own changes, a little around each, and a count where the rest was; each line's number on its side. */
function fold(entries, context = 3) {
  const keep = entries.map((entry) => Boolean(entry.own || entry.pin));
  entries.forEach((entry, i) => {
    if (!entry.own) return;
    for (let k = Math.max(0, i - context); k <= Math.min(entries.length - 1, i + context); k++) if (!entries[k].foreign) keep[k] = true;
  });
  const lines = [], nums = [];
  const put = (line, at) => { lines.push(line); nums.push(at ?? 0); };
  for (let i = 0; i < entries.length; ) {
    if (keep[i]) { put((entries[i].own ? entries[i].s : " ") + entries[i].t, entries[i].at); i++; continue; }
    let j = i, foreign = 0;
    while (j < entries.length && !keep[j]) { if (entries[j].foreign) foreign++; j++; }
    const run = j - i;
    if (run <= 2 && !foreign) for (let k = i; k < j; k++) put(" " + entries[k].t, entries[k].at);
    else if (foreign) put(`~${run} lines, ${foreign} of them changed and read under another row`);
    else put(`~${run} unchanged line${run === 1 ? "" : "s"}`);
    i = j;
  }
  return { lines, nums };
}

const IMPORT = /^\s*(import\b|from\s+\S+\s+import\b|export\s+\*|export\s+(type\s+)?\{[^}]*\}\s+from\b|(const|let|var)\s+.*=\s*require\(|use\s+\w|#include\b|require\b|\}\s*from\s+["']|[{}]\s*$|(type\s+)?[\w$]+(\s+as\s+[\w$]+)?,?\s*$)/;

function linesOf(unit) {
  const file = files.get(unit.path);
  if (unit.binary || !file) return { lines: [], nums: [] };
  const entry = (line) => ({ s: line.s, t: line.t, at: line.s === "-" ? line.o : line.n, own: line.owner === unit, foreign: Boolean(line.owner) && line.owner !== unit });
  if (unit.rest) {
    const { lines, nums } = fold(file.lines.map(entry), 1);
    const shown = lines.map((line, at) => [line[0] === "~" ? "~" : line, line[0] === "~" ? 0 : nums[at]]);
    while (shown[0]?.[0] === "~") shown.shift();
    while (shown.at(-1)?.[0] === "~") shown.pop();
    return { lines: shown.map((one) => one[0]), nums: shown.map((one) => one[1]) };
  }
  const entries = file.lines.filter((line) => (line.s === "-" ? holds(unit, line)
    : unit.now ? line.n >= unit.now[0] && line.n <= unit.now[1]
    : line.o != null && line.o >= unit.was[0] && line.o <= unit.was[1])).map(entry);
  const opens = entries.find((one) => !COMMENT.test(one.t) && one.t.trim());
  if (opens && !opens.foreign) opens.pin = true;
  return fold(entries);
}

/** The comment a symbol carries, as the sentence it is. */
function docOf(unit) {
  if (!unit.symbol) return "";
  const [from, to] = unit.now ?? unit.was;
  const said = [];
  for (const line of files.get(unit.path).lines) {
    const at = unit.now ? line.n : line.o;
    if (at == null || at < from || at > to) continue;
    if (!COMMENT.test(line.t)) { if (!line.t.trim() && !said.length) continue; break; }
    const text = line.t.replace(/^\s*(\/\*\*?|\*\/|\*|\/\/+|#+|--)\s?/, "").replace(/\*\/\s*$/, "").trim();
    if (text.startsWith("@")) break;
    if (text) said.push(text);
  }
  const doc = said.join(" ").replace(/\s+/g, " ");
  return /eslint-|@ts-|prettier-|istanbul|c8 ignore/.test(doc) ? "" : doc;
}

function lineDiff(before, after) {
  const n = before.length, m = after.length;
  if (n * m > 4e6) return [...before.map((t) => "-" + t), ...after.map((t) => "+" + t)];
  const table = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) table[i][j] = before[i] === after[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
  const out = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (before[i] === after[j]) { out.push(" " + before[i]); i++; j++; }
    else if (table[i + 1][j] >= table[i][j + 1]) out.push("-" + before[i++]);
    else out.push("+" + after[j++]);
  }
  while (i < n) out.push("-" + before[i++]);
  while (j < m) out.push("+" + after[j++]);
  return out;
}

// A symbol taken out of one file and put in another under the same name is one row: what moving it changed.
const gone = units.filter((unit) => unit.symbol && unit.mark === "removed");
for (const from of gone) {
  const same = (unit) => unit.name === from.name && unit.kind === from.kind;
  const twins = units.filter((unit) => unit.symbol && unit.mark === "new" && same(unit) && unit.path !== from.path && !unit.movedFrom);
  if (twins.length !== 1 || gone.filter(same).length !== 1) continue;
  const [to] = twins;
  const text = (unit, side, range) => files.get(unit.path).lines.filter((line) => line[side] != null && line[side] >= range[0] && line[side] <= range[1]).map((line) => line.t);
  to.movedFrom = from;
  to.mark = "moved";
  to.moved = lineDiff(text(from, "o", from.was), text(to, "n", to.now));
  from.dropped = true;
}

const fileNames = new Map();
for (const path of files.keys()) fileNames.set(basename(path), (fileNames.get(basename(path)) ?? 0) + 1);
const where = (path) => (fileNames.get(basename(path)) > 1 ? join(basename(dirname(path)), basename(path)) : basename(path));
const commitOf = (unit) => {
  if (perCommit && unit.symbol) {
    const at = commitGraphs.findIndex((one) => one?.definitions?.some((def) => def.id === unit.id));
    if (at >= 0) return at;
  }
  return Math.max(0, commitFiles.findIndex((set) => set.has(unit.path)));
};
const reading = new Map((graph?.reading?.threads ?? []).flat().map((id, at) => [id, at]));

const rows = [];
for (const unit of units) {
  if (unit.dropped) continue;
  let was = unit.movedFrom?.was?.[0], now = unit.now?.[0];
  const { lines, nums } = unit.moved
    ? fold(unit.moved.map((line) => ({ s: line[0], t: line.slice(1), own: line[0] !== " ", at: line[0] === "-" ? was++ : (line[0] === " " && was++, now++) })))
    : linesOf(unit);
  const changed = lines.filter((line) => line[0] === "+" || line[0] === "-");
  if (!changed.length && !unit.binary && !unit.moved) continue;
  const quiet = (pattern) => changed.length > 0 && changed.every((line) => pattern.test(line.slice(1)) || !line.slice(1).trim());
  const tags = [];
  if (unit.signature) tags.push("signature");
  if (unit.moved && !changed.length) tags.push("unchanged");
  if (unit.symbol && unit.mark === "changed" && quiet(COMMENT)) tags.push("comment only");
  const imports = Boolean(unit.rest && !unit.binary && quiet(IMPORT));
  rows.push({
    id: unit.id, name: unit.name, mark: unit.mark, kind: imports ? "imports" : unit.kind, path: unit.path,
    where: unit.movedFrom ? `${where(unit.movedFrom.path)} → ${where(unit.path)}` : where(unit.path),
    doc: docOf(unit), tag: tags.join(", "), prose: Boolean(unit.prose), cases: unit.cases ?? null, lines, nums,
    add: changed.filter((line) => line[0] === "+").length, del: changed.filter((line) => line[0] === "-").length,
    test: unit.test, block: Boolean(unit.block), symbol: Boolean(unit.symbol), rest: Boolean(unit.rest), imports, commit: commitOf(unit),
    oldPath: unit.movedFrom?.path ?? unit.path, unit,
    at: [unit, unit.movedFrom].filter(Boolean).map((one) => (one.symbol ? ["sym", one.path, one.now ? "new" : "old", (one.now ?? one.was)[0]] : ["file", one.path, "new", 0])),
    order: (unit.rest ? 3e6 : unit.mark === "removed" ? 2e6 : 0) + (reading.get(unit.id) ?? 1e5 + rows.length),
  });
}

/** The change as its cases: situations the code meets, each followed through the code as it runs, before
 * and after. Claude reads the repository at both commits (git grep and git show, nothing else) to follow a
 * case past the changed lines to where its ending is decided; otis checks every line it cites. */
async function tellCases(only = null, told = null) {
  const model = modelArg ?? "claude-sonnet-5-5";
  const sources = [
    ...(description ? [{ from: "description", text: (titleArg ? titleArg + "\n\n" : "") + description }] : []),
    ...commits.map((commit) => ({ from: short(commit.sha), text: commit.subject + (commit.body ? "\n\n" + commit.body : "") })),
  ];
  if (model === "off" || !rows.length) return null;
  const said = sources.map((source) => source.text).join("\n\n");
  const key = createHash("sha1").update(JSON.stringify([said, rows.map((row) => [row.id, row.add, row.del]), model, 18])).digest("hex").slice(0, 16);
  const cached = cacheDir && join(cacheDir, `${base}-${head}.${key}.json`);
  if (!only && cached && existsSync(cached)) { try { return { ...JSON.parse(readFileSync(cached, "utf8")), sources, cached: true }; } catch { /* asked again */ } }

  // What the reader knows and is learning (otis-words): not in the key, so a word marked changes the cases
  // told after it, not the ones already told.
  let reader = "";
  try { reader = execFileSync("otis-words", ["--reader"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { reader = ""; }
  // Code whole, as the reader will see it; a test, its first lines, for its name and what it sets up.
  const shown = (row) => row.lines.slice(0, row.block ? 12 : 400).map((line, at) =>
    (line[0] === "~" ? "        ..." : `${String(row.nums[at] || "").padStart(6)} ${line[0] === " " ? " " : line[0]} ${line.slice(1)}`));
  const prompt = [
    "A reviewer wants to understand this code change by its cases: the concrete situations the code meets (an input, an answer from another system, a timing), each followed through the code in the order it runs, so they can see how that situation ended before the change, how it ends now, and which lines decide it.",
    "",
    "You can read the repository on both sides of the change with these commands, one per call, with no pipes:",
    `  git -C ${root} grep -n -e <pattern> ${head} -- <paths>      search the code after the change (${base} for before)`,
    `  git -C ${root} grep -n -e '' ${head} -- <path>              a whole file, every line numbered`,
    `  git -C ${root} show ${head}:<path>`,
    "Follow each case past the changed lines until you reach where its ending is decided: what a person or another system sees, whether it is tried again, what is stored. That is often in code this change never touched: who calls the changed code, who catches what it throws, who reads the flag or value it returns (git grep for the field's name). Going that deep on the main cases matters more than listing many. Stop when following further would not change the ending. Use up to about 150 commands: a large change needs them, since its cases have to run through all of its code.",
    "",
    "cases: the situations whose ending this change moves, as many as it takes for every changed row of code to be on some case's route: usually 6 to 16, more for a large change. In the order to read them: a reader goes through them one by one, top to bottom, and after the last one understands the whole change. The first case is the change's main path, told so that a teammate who has never seen this code learns what the change does and why; each case after it builds on the ones before it and says what is different. Cases that come in the same way stay together. Add a few a reader would expect to have changed that end the same (\"the same\"), and ones where only a label moved: a value only logs, metrics or a stored field read (\"only a label\"). For each condition the change adds, take a case on each side of it, and when it reads a list (some, every, a filter), one with a mix. Each situation is told once: never two cases a reader would call the same one, told from another function along its route.",
    "Code the change removes is told by what a person or another system could do with it: one case for each (a button they clicked, a call another system made), what it did before and what happens now. How the removed code failed, what it stored and the helpers only it used are stops on that case, never cases of their own. Removed code that nothing could reach (a path no caller took) is one case for all of it, which says nothing reached it.",
    "- group: where the case comes in, 2 to 6 everyday words, like \"we send Apple a message\". Cases that come in the same way use the same words.",
    "- name: the situation, at most 10 everyday words a newcomer understands without reading anything else, like \"Apple never answers a message we send\". Never a setting, option or value from the code, even put in English (\"a caller leaves off the defer option\"): say what someone does or what happens, like \"a caller wants the reply written on the spot\".",
    "- setup: one or two sentences that make it concrete for someone who has never seen this code. The first time a thing comes up in a case, say what it is in everyday words: never a bare word from the code's own world like \"a provider\", but \"the AI service the judge sends the question to, like OpenAI\". Name who does what as the code has it: before you say a person sets or triggers something, check who the code lets do it (a permission check, an admin gate).",
    "- was, now: how it ended before and how it ends now, at most 8 words each, each a plain clause with its subject, the same words where they agree, like \"it is tried again\" and \"it fails, and may have been sent\".",
    "- change: \"ends differently\", \"only a label\" or \"the same\". Before you say a case ends differently because a value changed (a flag like retryable, an error's type), find what reads that value: when nothing acts on it, only logs, metrics or a stored field read it, the case is \"only a label\", and its was and now say what a person or system actually sees. A check, a guard or a path the change removes is never only a label.",
    "- described: true when the author's words below describe this case, false when they never mention it.",
    "- said: the author's own sentence about this case, copied exactly from their words below, or \"\".",
    "- facts: at most 5 things a reviewer would compare, each about one thing (when a count and a list move differently, they are two facts): what (a question a newcomer would ask about this case, at most 6 words, like \"Is the model called?\" or \"What does the shopper see?\"), before and after (its answer before and after the change, at most 8 words each, plain enough to read alone, never a label only this code uses), and test (the one line of a test in this change that asserts this answer: path, its line number after the change, its code copied exactly; or path \"\", line 0 and code \"\" when no test asserts it). In everyday words a teammate from outside this code would use; a code value only when it is what a person or another system sees, like a 400 status or a reason \"delivery_unknown\". before is what the code before the change does with this same situation: when the situation needs something this change adds (a setting, a field), say what the old code does without it, never what it would have done with it. When nothing ran for this case before the change, before is \"\".",
    "- stops: the route, in the order it runs. Each is a place in the code: name (the function's or symbol's own name, nothing else), is (what that function or place is for, at most 12 everyday words, like \"reads one page of the window's orders from the database\"), path (from the repository's root), side (\"new\" for the code after the change, \"old\" only for code the change removed), lines (the 1 to 5 lines there that decide this case, each with its line number on that side, its code copied exactly, and value: what holds on that line for this case, a short phrase that says what it is about, like \"the window has a rate, so go on\" or \"paid through Gale, so 2%\", never a bare true or false; or \"\"; check each value against its line: a comparison's edge as the code has it (>= is \"at least\", > is \"over\"), and arithmetic done with the case's own numbers). Take unchanged code in when it decides the ending, and take in the function that calls the others when that is what holds the route together.",
    "- tests: the names of tests in this change that run this case, copied exactly from the rows below.",
    "- data: the paths of changed files that hold data this case runs on: a test case or fixture it reads, a migration that adds what its code reads; or none.",
    "",
    "summary: the whole change in one or two sentences, read before any case: what it does and why, in plain words for a teammate who has never seen this code, the way you would say it aloud. Not a list of what changed: what is different now, and for whom.",
    "",
    "groups: for each group your cases use (its words exactly as the cases give them), where: two to four sentences for a teammate who has never seen this part of the code: what this part of the system is for and why it exists; what it does; each word it gives its own meaning, defined in plain words (an eval's case, label and passing; a billing window; a gateway); and the main steps a case passes through, naming their functions in the order they run.",
    "",
    "Every changed row of code below must be on some case's route: some case's stops cite lines inside it. A type, a constant, a schema or a logger is on the route of any case whose stops use it, and needs no case of its own. Before you answer, go through the rows one by one; for a row none of your cases runs yet, put it on the route of the case it belongs to, and make it a case of its own only when no case you have runs it. A test is never a stop: it is on a case when that case names it in tests.",
    "",
    ...(reader ? [reader, ""] : []),
    "Write for a teammate who has never seen this code. Every phrase has its subject and its verb, the way you would say it aloud: \"the model is asked one question\", never \"asked once\". Never use a value, label or flag from the code as a word (NO, OPT_OUT, retryable): say what it means, like \"the expected answer is no\". Never coin a name for one either (\"the marker\", \"the defer option\"): say what the code does with it, like \"the caller runs the other agent itself\". A word this part of the code gives its own meaning is defined in its group's where, and every other field uses it only that way.",
    "",
    "Plain words in every sentence, nothing a teammate would have to ask about, and no markdown, with one exception: in setup, where, is, value and facts, put each name from the code in backticks, like `needsJudgment` or `orderValue`, so a reader can tell it from an English word. Nowhere else.",
    "",
    ...(only ? [
      "# Cases already told",
      ...told.cases.flatMap((one, at) => [`${at + 1}. ${one.group}: ${one.name}`, `   ${one.setup}`, `   route: ${one.stops.map((stop) => `${stop.name} (${stop.path})`).join(", ")}`]),
      "",
      "The changed rows of code below are on none of those cases' routes yet. Most belong on one: the situation that runs a row, or that the row serves (a check it makes, a value it reads, a step it logs), is usually a case above. adds: for each such case, its number, the stops to add to its route, and the tests and data that come with them. cases: only for a row no case above runs, a new case, a situation no case above tells, to read after those already told; it uses the words of the group it comes in by, and gives where only for a new group. summary is \"\".",
      "",
    ] : []),
    "# The author's words",
    ...(sources.length ? sources.flatMap((source) => ["", `## ${source.from === "description" ? "merge request description" : `commit ${source.from}`}`, source.text]) : ["", "(none)"]),
    "",
    "# The changed rows: each line's number on its side, + added, - removed",
    ...(only ?? rows.filter((row) => !wiring(row.path))).flatMap((row) => [
      "",
      `## ${row.name}${row.cases ? ` [${row.cases}]` : ""}`,
      `${row.test ? "test code" : "code"}, ${row.kind}, ${row.mark}${row.tag ? `, ${row.tag}` : ""}, +${row.add} -${row.del}, ${row.path}`,
      ...shown(row),
    ]),
  ].join("\n");
  const object = (properties) => ({ type: "object", additionalProperties: false, required: Object.keys(properties), properties });
  const list = (items) => ({ type: "array", items });
  const text = { type: "string" };
  const stop = object({ name: text, is: text, path: text, side: { enum: ["new", "old"] }, lines: list(object({ line: { type: "integer" }, code: text, value: text })) });
  const schema = object({
    cases: list(object({
      group: text, name: text, setup: text, was: text, now: text,
      change: { enum: ["ends differently", "only a label", "the same"] }, described: { type: "boolean" }, said: text,
      facts: list(object({ what: text, before: text, after: text, test: object({ path: text, line: { type: "integer" }, code: text }) })),
      stops: list(stop), tests: list(text), data: list(text),
    })),
    ...(only ? { adds: list(object({ case: { enum: told.cases.map((_, at) => at + 1) }, stops: list(stop), tests: list(text), data: list(text) })) } : {}),
    groups: list(object({ group: text, where: text })),
    summary: text,
  });
  const empty = mkdtempSync(join(tmpdir(), "otis-sentences-"));
  const budget = String(Number(git("config", "--default", "10", "--get", "otis.sentencesBudget").trim()) || 10);
  const answer = await new Promise((done) => {
    execFile(process.env.SEAM_CLAUDE || "claude", [
      "-p", "--model", model, "--restricted", "--tools", "Bash", "--add-dir", root,
      "--allowedTools", `Bash(git -C ${root} grep:*)`, `Bash(git -C ${root} show:*)`,
      "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--permission-prompts", "none",
      "--max-budget-usd", budget, "--output-format", "json", "--json-schema", JSON.stringify(schema),
    ], { cwd: empty, encoding: "utf8", maxBuffer: MAX, timeout: 1800000 }, (error, out, err) => done({ out, error, err })).stdin.end(prompt);
  });
  rmSync(empty, { recursive: true, force: true });
  let spent;
  try { spent = JSON.parse(answer.out); } catch { spent = null; }
  const answered = spent?.is_error ? null : spent?.structured_output;
  // Claude gave no answer (its usage limit, its budget): no cases rather than the commits passed off as them, and
  // why, which git-sentences keeps until r asks again.
  if (!answered) {
    if (only) return null;
    const why = spent?.subtype === "error_max_budget_usd" ? `it spent its $${budget} (git config otis.sentencesBudget)`
      : answer.error?.killed ? "it ran past 30 minutes"
      : [spent?.result, answer.err].join("\n").split("\n").find((line) => line.trim()) ?? "claude ended without a word";
    console.error(`sentences: Claude could not tell its cases: ${why}`);
    process.exit(1);
  }
  if (only) return { cases: answered.cases, adds: answered.adds, groups: answered.groups, turns: spent.num_turns, cost: spent.total_cost_usd };
  if (!answered.cases?.length) {
    console.error(`sentences: ${model} found no cases, so it is one part a commit`);
    return null;
  }
  // The reader's words it was told with, so the pane knows which words a case already tells your way.
  const result = { model, cases: answered.cases, groups: answered.groups ?? [], summary: coded(answered.summary), turns: spent.num_turns, cost: spent.total_cost_usd, reader };
  if (cached) { mkdirSync(cacheDir, { recursive: true }); writeFileSync(cached + ".new", JSON.stringify(result)); renameSync(cached + ".new", cached); }
  return { ...result, sources, kept: cached };
}

/** A file's lines on one side: from the diff when the change has the file, else from git. */
const texts = new Map();
function textAt(side, path) {
  const key = `${side}\t${path}`;
  if (texts.has(key)) return texts.get(key);
  const file = files.get(path);
  let lines = null;
  if (file) {
    if (!file.binary && !(side === "old" ? file.added : file.deleted)) lines = file.lines.filter((line) => line[side === "old" ? "o" : "n"] != null).map((line) => line.t);
  } else {
    try { lines = git("show", `${side === "old" ? base : head}:${path}`).split("\n"); if (lines.at(-1) === "") lines.pop(); } catch { lines = null; }
  }
  texts.set(key, lines);
  return lines;
}

/** Each line colored as its whole file colors it (bat, the theme's), so a line in a comment or a string is read as one. */
const painted = new Map();
async function paint(keys) {
  const theme = process.env.OTIS_T_BAT;
  await Promise.all([...new Set(keys)].filter((key) => !painted.has(key)).map(async (key) => {
    painted.set(key, null);
    const [side, path] = key.split("\t");
    const lines = textAt(side, path);
    if (!lines || lines.length > 20000) return;
    const out = await new Promise((done) => {
      const child = execFile("bat", ["--color=always", "--style=plain", "--paging=never", "--wrap=never", ...(theme ? [`--theme=${theme}`] : []), `--file-name=${path}`],
        { encoding: "utf8", maxBuffer: MAX }, (error, stdout) => done(error ? null : stdout));
      child.on("error", () => done(null));
      child.stdin.on("error", () => {});
      child.stdin.end(lines.join("\n") + "\n");
    });
    if (out) painted.set(key, out.split("\n"));
  }));
}
const colored = (side, path, n) => painted.get(`${side}\t${path}`)?.[n - 1] ?? null;
const sideOf = (row, line) => (line[0] === "-" ? ["old", row.oldPath] : ["new", row.path]);
const shownAt = (row, at) => Boolean(row.nums[at]) && " +-".includes(row.lines[at][0]);

const plain = (text) => text.replace(/[`*_>#]/g, "").replace(/^\s*[-•]\s+/gm, "").replace(/\s+/g, " ").trim().toLowerCase();
const unmark = (text) => (text ?? "").replace(/\*\*|__|`/g, "").replace(/\s+/g, " ").trim();
const bare = (text) => unmark(text).replace(/\.$/, "");
/** Claude's words with the code names in them still in backticks, for the pane to draw as code. */
const coded = (text) => (text ?? "").replace(/\*\*|__/g, "").replace(/\s+/g, " ").trim();
const squash = (text) => (text ?? "").replace(/\s+/g, " ").trim();

const [told] = await Promise.all([
  tellCases(),
  paint(rows.flatMap((row) => row.lines.flatMap((line, at) => (shownAt(row, at) ? [sideOf(row, line).join("\t")] : [])))),
]);
for (const row of rows) row.paint = row.lines.map((line, at) => (shownAt(row, at) ? colored(...sideOf(row, line), row.nums[at]) : null));

/** Where a line of a changed file sits in its diff: its run of changes, and which row owns it. */
const indexes = new Map();
function entryAt(path, side, n) {
  const file = files.get(path);
  if (!file) return null;
  if (!indexes.has(path)) {
    const index = { new: new Map(), old: new Map() };
    file.lines.forEach((line, i) => { if (line.n != null) index.new.set(line.n, i); if (line.o != null) index.old.set(line.o, i); });
    indexes.set(path, index);
  }
  const i = indexes.get(path)[side].get(n);
  return i == null ? null : { file, i, line: file.lines[i] };
}
const tokens = (text) => new Set(text.match(/[\w$]+|[^\s\w]/g) ?? []);
function likeness(a, b) {
  const x = tokens(a), y = tokens(b);
  let both = 0;
  for (const token of x) if (y.has(token)) both++;
  return both / Math.max(1, new Set([...x, ...y]).size);
}
/** The line a changed line replaced (on the old side, the one that replaced it): the closest in its run of changes. */
function counterpart({ file, i, line }) {
  if (line.s === " ") return null;
  let best = null, score = 0.34;
  for (const step of [-1, 1]) {
    for (let j = i + step; j >= 0 && j < file.lines.length && file.lines[j].s !== " "; j += step) {
      const other = file.lines[j];
      if (other.s === line.s) continue;
      const alike = likeness(line.t, other.t);
      if (alike > score) { best = other; score = alike; }
    }
  }
  return best;
}
/** Whether the change touches lines first to last on one side of a file: adds or removes a line among them. */
function touched(path, side, [first, last]) {
  const from = entryAt(path, side, first), to = entryAt(path, side, last);
  return Boolean(from && to) && from.file.lines.slice(from.i, to.i + 1).some((line) => line.s !== " ");
}
function smallestUnit(path, side, n) {
  let best = null;
  for (const unit of unitsByFile.get(path) ?? []) {
    const range = side === "old" ? unit.was : unit.now;
    if (!range || n < range[0] || n > range[1]) continue;
    if (!best || span(range) < span(side === "old" ? best.was : best.now)) best = unit;
  }
  return best;
}
const rowByUnit = new Map(rows.map((row) => [row.unit, row]));
// What each changed row's code mentions among the others (seam's edges): the type, constant or logger a case's
// function uses is read with that case, never given one of its own.
const rowById = new Map(rows.map((row) => [row.id, row]));
const uses = new Map(rows.map((row) => [row, new Set()]));
for (const edge of graph?.edges ?? []) { const from = rowById.get(edge.from), to = rowById.get(edge.to); if (from && to && from !== to) uses.get(from).add(to); }

/** The names in some lines worth matching on: long or camel-cased, and not the language's own words. */
const COMMON = new Set(["function", "readonly", "constructor", "undefined", "instanceof", "Response", "response", "Promise", "continue", "toString", "stringify", "default"]);
const identifiers = (lines) => new Set(lines.flatMap((line) => line.t.match(/[A-Za-z_$][\w$]*/g) ?? []).filter((word) => (word.length >= 8 || /[a-z][A-Z]/.test(word)) && !COMMON.has(word)));
/** Changed definitions by the name a line would use for them: a member by its own name, a constructor by its class's. */
const named = new Map();
for (const row of rows) {
  if (!row.symbol || !meat(row.path)) continue;
  const [owner, own] = row.name.includes(".") ? row.name.split(".") : [null, row.name];
  const word = own === "constructor" ? owner : own;
  if (word.length < 6 && !/[a-z][A-Z]/.test(word)) continue;
  if (!named.has(word)) named.set(word, []);
  named.get(word).push(row);
}

/** Where a cited line is: within a few lines of where Claude said, or 0. */
function findLine(text, line, code) {
  const want = squash(code);
  if (!want) return 0;
  const fits = (k) => { const have = squash(text[k - 1]); return have === want || (want.length >= 8 && have.includes(want)); };
  let n = fits(line) ? line : 0;
  for (let d = 1; d <= 25 && !n; d++) n = [line - d, line + d].find((k) => k >= 1 && fits(k)) ?? 0;
  return n;
}

/** A line of code without its strings and its comment, for counting its brackets. */
const bareCode = (line) => (line ?? "").replace(/(["'`])(?:\\.|(?!\1)[^\\])*\1/g, '""').replace(/\/\/.*$/, "");
const net = (line, opens, closes) => { let depth = 0; for (const ch of bareCode(line)) { if (opens.includes(ch)) depth++; else if (closes.includes(ch)) depth--; } return depth; };

/** The line where a definition starting at line i (0-based) ends: where its brackets close, past an arrow or an
 * operator that carries it on. 1-based, or 0. */
function closing(text, i) {
  let depth = 0, opened = false;
  for (let k = i; k < Math.min(text.length, i + 1500); k++) {
    for (const ch of bareCode(text[k])) { if ("({[".includes(ch)) { depth++; opened = true; } else if (")}]".includes(ch)) depth--; }
    const goesOn = /(=>|[=(,?:&|+\-*/[{.])\s*$/.test(bareCode(text[k])) || /^\s*[.?:]/.test(text[k + 1] ?? "");
    if (depth <= 0 && !goesOn && (opened || k > i || /[;)}\]]\s*$/.test(text[k]))) return k + 1;
    if (!opened && k > i + 3) return 0;
  }
  return 0;
}

/** Whether the parameters after name on line i (0-based) close into a body: `) {`, or `): Type {`. */
function opensBody(text, i, name) {
  const first = bareCode(text[i]);
  let col = first.indexOf("(", first.indexOf(name) + name.length), depth = 0;
  if (col < 0) return false;
  for (let k = i; k < Math.min(text.length, i + 15); k++, col = 0) {
    const line = k === i ? first : bareCode(text[k]);
    for (let c = col; c < line.length; c++) {
      if (line[c] === "(") depth++;
      else if (line[c] === ")" && --depth === 0) { const rest = line.slice(c + 1); return /^\s*(:.*)?\{\s*$/.test(rest) && !rest.includes("=>"); }
    }
  }
  return false;
}

/** The definitions in a file, as far as its text shows: each function, method and class, and each constant at
 * the top of the file or holding a function, from the line it starts on to the line it ends on. */
const KEYWORDS = new Set(["if", "for", "while", "switch", "catch", "return", "function", "await", "typeof", "new", "else", "do", "try", "with", "super", "this", "void", "delete", "yield", "throw", "case", "in", "of"]);
const defined = new Map();
function definitions(side, path) {
  const key = `${side}\t${path}`;
  if (defined.has(key)) return defined.get(key);
  const text = textAt(side, path) ?? [];
  const defs = [];
  for (let i = 0; i < text.length; i++) {
    const line = text[i];
    if (COMMENT.test(line)) continue;
    let m, name = null;
    if ((m = /^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/.exec(line))) name = m[1];
    else if ((m = /^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/.exec(line))) name = m[1];
    else if ((m = /^(\s*)(?:export\s+)?(?:declare\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\b/.exec(line))) {
      const ahead = text.slice(i, i + 15).map(bareCode).join(" ");
      if (!m[1] || /=\s*(?:async\s+)?(?:function\b|\([^]*?\)\s*(?::[^=]*?)?=>|[A-Za-z_$][\w$]*\s*=>)/.test(ahead)) name = m[2];
    } else if ((m = /^\s*(?:(?:public|private|protected|static|async|readonly|override|get|set)\s+)*\*?([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\(/.exec(line))
      && !KEYWORDS.has(m[1]) && opensBody(text, i, m[1])) name = m[1];
    if (!name) continue;
    const end = closing(text, i);
    // Its doc comment is part of it, as seam's rows have it: a line of the comment is the function's own.
    let start = i;
    while (start > 0 && COMMENT.test(text[start - 1])) start--;
    if (end) defs.push({ name, start: start + 1, end });
  }
  defined.set(key, defs);
  return defs;
}
const reach = (def) => def.end - def.start;
/** The smallest definition holding line n, and the one around that. */
function ownOf(side, path, n) {
  const around = definitions(side, path).filter((def) => def.start <= n && n <= def.end).sort((a, b) => reach(a) - reach(b));
  return around[0] ? { ...around[0], inside: around.find((def) => def.start < around[0].start || def.end > around[0].end)?.name ?? "" } : null;
}

/** A case's stops, as otis finds them in the code: each cited line where its code is (within a few lines of where
 * Claude said; a line otis can't find is dropped), what it replaced, and which changed rows it runs through. Each
 * line goes under the function it is in, as the code has it: a function inside another is a stop of its own, and
 * a stop Claude named for a function its lines are not in takes the name of the one they are in. A stop in a test,
 * a generated file or build wiring is dropped. What holds on a line is its note, of no case until a route says. */
function placeStops(stop) {
  const path = stop.path.trim().replace(/^(\.\/|[ab]\/)/, "");
  const side = stop.side === "old" ? "old" : "new";
  if (!meat(path)) return [];
  const text = textAt(side, path);
  if (!text) return [];
  const lines = [];
  for (const cited of stop.lines ?? []) {
    const n = findLine(text, cited.line, cited.code);
    const value = coded(cited.value).replace(/\.$/, "");
    if (n && !lines.some((one) => one.n === n)) lines.push({ n, t: text[n - 1], notes: value ? [{ of: [], value }] : [] });
  }
  if (!lines.length) return [];
  lines.sort((a, b) => a.n - b.n);
  const unitOf = new Map();
  for (const line of lines) {
    const found = entryAt(path, side, line.n);
    line.sign = found ? found.line.s : " ";
    const other = found && counterpart(found);
    if (other) line.other = { n: side === "old" ? other.n : other.o, t: other.t };
    unitOf.set(line, found?.line.owner ?? smallestUnit(path, side, line.n));
  }
  // Code the change kept or replaced is read where it runs now: old lines that each have a place in the new code
  // (the same line, or the one put in its place) are a stop on those, each replaced one paired with the old line
  // Claude cited, still on the old rows' route. Its readings and what it is for told the old code, so the new lines
  // are lit without them, and the old lines drawn under them (codeOf) say what was there. One cited line the change
  // took out with nothing in its place makes it the code the change removed, read as it was.
  const now = (line) => line.other?.n ?? (line.sign === " " ? entryAt(path, "old", line.n)?.line.n ?? line.n : null);
  if (side === "old" && textAt("new", path) && lines.every(now)) {
    const placed = placeStops({ ...stop, side: "new", is: "", lines: lines.map((line) => ({ line: now(line), code: textAt("new", path)[now(line) - 1], value: "" })) });
    for (const one of placed) {
      for (const line of one.lines) { const was = lines.find((old) => now(old) === line.n); if (was.other) line.other = { n: was.n, t: was.t }; }
      for (const line of lines) if (rowByUnit.has(unitOf.get(line))) one.covers.add(rowByUnit.get(unitOf.get(line)));
    }
    return placed;
  }
  const claimed = bare(stop.name), is = coded(stop.is).replace(/\.$/, "");
  const groups = new Map();
  for (const line of lines) {
    const def = ownOf(side, path, line.n);
    const key = def ? def.start : 0;
    if (!groups.has(key)) groups.set(key, { def, lines: [] });
    groups.get(key).lines.push(line);
  }
  const all = [...groups.values()];
  const mine = all.find((group) => group.def?.name === callee({ name: claimed })) ?? all.reduce((a, b) => (b.lines.length > a.lines.length ? b : a));
  return all.map((group) => {
    const covers = new Set();
    // New code: every line it cites is in a file or definition that did not exist before the change.
    let fresh = side === "new";
    for (const line of group.lines) {
      const unit = unitOf.get(line);
      if (rowByUnit.has(unit)) covers.add(rowByUnit.get(unit));
      if (!(files.get(path)?.added || unit?.mark === "new")) fresh = false;
    }
    // A changed definition its lines name is on the route too: the error it throws, the constant it checks.
    for (const word of identifiers(group.lines)) for (const row of named.get(word) ?? []) covers.add(row);
    const { def } = group;
    const name = !def || callee({ name: claimed }) === def.name ? claimed : def.name;
    return {
      name, is: group === mine ? is : "", path, side, where: files.has(path) ? where(path) : basename(path), inChange: files.has(path),
      range: def ? [def.start, def.end] : enclosing({ path, side, lines: group.lines }), inside: def?.inside ?? "",
      mark: group.lines.some((line) => line.sign !== " ") ? "◆" : covers.size ? "●" : "○", fresh, lines: group.lines, covers,
    };
  });
}

/** The changed definition a stop's lines all sit in, when the change has it: the smallest that holds them all. */
function enclosing(stop) {
  const first = stop.lines[0].n, last = stop.lines.at(-1).n;
  let best = null;
  for (const unit of unitsByFile.get(stop.path) ?? []) {
    const range = stop.side === "old" ? unit.was : unit.now;
    if (!unit.symbol || !range || range[0] > first || range[1] < last) continue;
    if (!best || span(range) < span(best)) best = range;
  }
  return best;
}
const callee = (stop) => {
  const words = stop.name.match(/[A-Za-z_$][\w$]*/g) ?? [];
  const word = words.at(-1) === "constructor" ? words.at(-2) : words.at(-1);
  return word && word.length >= 4 ? word : null;
};
const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
/** A line that defines name: a declaration, or a method whose parameters close on the line it opens its body. */
const definition = (name) => new RegExp(`(function\\*?|class|const|let|var|type|interface|get|set)\\s+${escape(name)}\\b|^\\s*(export\\s+)?(async\\s+|static\\s+|public\\s+|private\\s+)*\\*?${escape(name)}\\s*[(<].*\\)\\s*(:\\s*[^{]+)?\\{\\s*$`);

/** The line in a's function that calls b (or reads it: an object's member, an index, a tag), the nearest to a's
 * cited lines: never b's own definition, and never a name a's function declares for itself from there on. */
function callIn(a, b) {
  const name = callee(b);
  if (!name) return null;
  const text = textAt(a.side, a.path);
  const range = a.range ?? [Math.max(1, a.lines[0].n - 80), Math.min(text.length, a.lines.at(-1).n + 80)];
  const own = a.path === b.path && a.side === b.side ? b.range ?? [b.lines[0].n, b.lines.at(-1).n] : null;
  const N = escape(name);
  const calls = new RegExp(`(^|[^\\w$.])(new\\s+)?${N}\\s*(<[^>]*>)?\\s*\\(|\\.${N}\\s*(<[^>]*>)?\\s*\\(`);
  const reads = new RegExp(`(^|[^\\w$.])${N}\\s*[.[]|<${N}(?=[\\s/>]|$)`);
  // Handed to another function to call: `errors.some(name)`, or a callback on a line of its own.
  const passes = new RegExp(`(^|[(,])\\s*${N}\\s*[,)]`);
  const local = new RegExp(`\\b(const|let|var)\\s+${N}\\b|\\b(const|let|var)\\s*\\{[^}]*\\b${N}\\b[^}]*\\}\\s*=`);
  let shadowed = false, best = null;
  for (let n = range[0]; n <= range[1]; n++) {
    const line = text[n - 1] ?? "";
    if (own && n >= own[0] && n <= own[1]) continue;
    if (local.test(line)) { shadowed = true; continue; }
    if (shadowed || COMMENT.test(line) || /^\s*import\b/.test(line)) continue;
    const verb = calls.test(line) ? "calls" : passes.test(line) ? "passes" : reads.test(line) ? "uses" : "";
    if (!verb) continue;
    // A call in a block that leaves (a return, a continue) before a line the case is cited at further on is one
    // the case went past, not through.
    const distance = (a.lines.length ? Math.min(...a.lines.map((one) => Math.abs(one.n - n))) : 0) + (passedBy(text, n, range, a.lines) ? 1e4 : 0);
    if (!best || distance < best.distance) best = { n, distance, verb };
  }
  return best && { n: best.n, t: text[best.n - 1], verb: best.verb };
}
function passedBy(text, n, range, cited) {
  let open = 0, sum = 0;
  for (let k = n - 1; k >= range[0]; k--) { sum += net(text[k - 1], "{", "}"); if (sum > 0) { open = k; break; } }
  if (!open) return false;
  let depth = 0;
  for (let k = open; k <= range[1]; k++) {
    depth += net(text[k - 1], "{", "}");
    if (k > n && /^\s*(return|throw|continue|break)\b/.test(text[k - 1]) && depth >= 1) return cited.some((line) => line.n > k && !blockHas(text, open, line.n));
    if (k > open && depth <= 0) return false;
  }
  return false;
}
const blockHas = (text, open, n) => { let depth = 0; for (let k = open; k < n; k++) { depth += net(text[k - 1], "{", "}"); if (k > open && depth <= 0) return false; } return true; };

/** What in the code calls a stop nothing on the route calls (or uses it: hands it on, reads it), so the reader
 * sees how the case gets there: the first such line in the change's code, else in the stop's own folder, with
 * the function it is in. Only the meat of the change is a way in. null when there is none. */
function caller(stop) {
  const name = callee(stop);
  if (!name) return null;
  const N = escape(name);
  const calls = new RegExp(`(^|[^\\w$.])(new\\s+)?${N}\\s*(<[^>]*>)?\\s*\\(|\\.${N}\\s*(<[^>]*>)?\\s*\\(`);
  const uses = new RegExp(`(^|[^\\w$])${N}([^\\w$]|$)`);
  const defines = definition(name);
  const verbOf = (path, n, t) => {
    if (path === stop.path && stop.range && n >= stop.range[0] && n <= stop.range[1]) return "";
    if (COMMENT.test(t) || /^\s*(import|export\s*(\{|\*))\b/.test(t) || defines.test(t)) return "";
    return calls.test(t) ? "calls" : uses.test(t) ? "uses" : "";
  };
  const code = (path) => /\.(m?[jt]sx?|cjs|py|go|rs|rb|java|kt|swift|c|cc|cpp|h|hpp|cs|php|scala|sh|zsh)$/.test(path) && meat(path);
  const found = (path, n, verb) => ({ fn: ownOf("new", path, n)?.name ?? "", path, where: where(path), n, verb });
  // A function of the same name (a wrapper, a re-export) is no way in: it says the name again and nothing more.
  const fresh = (hit) => hit.fn !== name;
  let use = null;
  for (const path of files.keys()) {
    if (!code(path)) continue;
    const text = textAt("new", path);
    if (!text) continue;
    for (let n = 1; n <= text.length; n++) {
      const verb = verbOf(path, n, text[n - 1]);
      const hit = verb && found(path, n, verb);
      if (!hit || !fresh(hit)) continue;
      if (verb === "calls") return hit;
      use ??= hit;
    }
  }
  if (use) return use;
  let out = "";
  try { out = git("grep", "-n", "-w", "-e", name, head, "--", dirname(stop.path)); } catch { return null; }
  for (const line of out.split("\n")) {
    const m = /^[^:]+:(.+?):(\d+):(.*)$/.exec(line);
    if (!m || !code(m[1])) continue;
    const verb = verbOf(m[1], Number(m[2]), m[3]);
    const hit = verb && found(m[1], Number(m[2]), verb);
    if (hit && fresh(hit)) return hit;
  }
  return null;
}

/** Who calls whom on a route, from the code: each stop under the stop whose function calls it (the innermost
 * one, when a function inside another holds the call; one before it first), with the line that calls it. A stop
 * nothing on the route calls stays at the top. */
function nest(stops) {
  stops.forEach((stop) => { stop.parent = -1; stop.call = null; });
  const above = (x, y) => { for (let k = stops[y].parent; k >= 0; k = stops[k].parent) if (k === x) return true; return false; };
  const hang = (b, i, found) => {
    b.parent = i;
    const a = stops[i], entry = entryAt(a.path, a.side, found.n);
    b.call = { n: found.n, t: found.t, sign: entry ? entry.line.s : " ", verb: found.verb };
    const unit = entry?.line.owner ?? smallestUnit(a.path, a.side, found.n);
    if (rowByUnit.has(unit)) a.covers.add(rowByUnit.get(unit));
  };
  const count = stops.length;
  for (let j = 0; j < count; j++) {
    const b = stops[j];
    const found = stops.map((a, i) => (i === j ? null : { i, found: callIn(a, b) })).filter((one) => one?.found);
    const callers = found.filter((x) => !found.some((y) => y !== x && y.found.n === x.found.n && stops[y.i].path === stops[x.i].path && span(stops[y.i].range) < span(stops[x.i].range)))
      .sort((x, y) => (x.i < j ? 0 : 1) - (y.i < j ? 0 : 1) || Math.abs(x.i - j) - Math.abs(y.i - j));
    const pick = callers.find(({ i }) => !above(j, i));
    if (!pick) continue;
    // A call made inside a function the caller defines for itself (a callback, a helper it keeps) runs when the
    // caller calls that function: that function is a step of its own, under the line the caller calls it from.
    const a = stops[pick.i];
    const inner = a.range && definitions(a.side, a.path)
      .filter((def) => def.start > a.range[0] && def.end <= a.range[1] && def.start <= pick.found.n && pick.found.n <= def.end && !(b.path === a.path && b.range?.[0] === def.start))
      .sort((x, y) => reach(y) - reach(x))[0];
    if (!inner) { hang(b, pick.i, pick.found); continue; }
    let at = stops.findIndex((one) => one.path === a.path && one.side === a.side && one.range?.[0] === inner.start);
    if (at < 0) {
      stops.push({ name: inner.name, is: "", path: a.path, side: a.side, where: a.where, inChange: a.inChange, range: [inner.start, inner.end], inside: a.name,
        mark: touched(a.path, a.side, [inner.start, inner.end]) ? "◆" : "○",
        fresh: a.fresh, lines: [], covers: new Set(), parent: -1, call: null });
      at = stops.length - 1;
      const into = callIn(a, stops[at]);
      if (into) hang(stops[at], pick.i, into);
    }
    hang(b, at, pick.found);
  }
}

/** The statement around line n: up to the bracket it sits in and down to where that closes, and on through an
 * operator that carries it over a line (`??`, `&&`, a ternary, an assignment), a few lines each way. */
const CARRIES = /(\?\?|\|\||&&|[=+\-*/%?:]|=>)\s*$/, CARRIED = /^\s*(\?\?|\|\||&&|[?:.]|=>)/;
function statement(text, n, lo, hi) {
  let start = n, sum = 0;
  for (let k = n - 1; k >= Math.max(lo, n - 8); k--) { sum += net(text[k - 1], "([", ")]"); if (sum > 0) { start = k; break; } }
  for (let k = 0; k < 4 && start > lo && (CARRIES.test(bareCode(text[start - 2])) || CARRIED.test(text[start - 1])); k++) start--;
  let end = n, depth = 0;
  for (let k = start; k <= n; k++) depth += net(text[k - 1], "([", ")]");
  for (let k = n + 1; depth > 0 && k <= Math.min(hi, n + 6); k++) { depth += net(text[k - 1], "([", ")]"); end = k; }
  for (let k = 0; k < 4 && end < hi && (CARRIES.test(bareCode(text[end - 1])) || CARRIED.test(text[end] ?? "")); k++) {
    end++;
    for (let d = net(text[end - 1], "([", ")]"); d > 0 && end < Math.min(hi, n + 12); ) { end++; d += net(text[end - 1], "([", ")]"); }
  }
  return [start, end];
}

/** The lines an if turns on, from its header at line i: each else of it, and the brace that closes it. */
const BRANCH = /^\s*(\}\s*)?(else\s+)?if\s*\(|^\s*\}?\s*else\b/;
function chainOf(text, i, hi) {
  const out = [];
  let depth = 0, opened = false;
  for (let k = i; k <= Math.min(hi, i + 300); k++) {
    const line = bareCode(text[k - 1]);
    for (let c = 0; c < line.length; c++) {
      if (line[c] === "{") { depth++; opened = true; }
      else if (line[c] === "}" && --depth === 0 && opened) {
        out.push(k);
        if (!/^\s*else\b/.test(line.slice(c + 1))) return out;
      }
    }
    if (!opened && k > i + 5) return out;
  }
  return out;
}

// What a cited line took the place of, as many lines of it as a reader takes in at a glance.
const TURN = 8;
/** The code a stop shows, in the order of the diff. A function the change touches: all of it, every line, as the
 * symbols tab shows it. One the change leaves alone: what the route uses of it, its name, the statement around each
 * line it cites or calls the next stop from, and the line that closes it. A stop otis finds no function around:
 * the statement around each of those lines, the elses of an if it shows, the exits (a return, a throw, a continue)
 * between the lines it shows and the ifs they sit in, and every line between them. A run of changes reads as the
 * stop's own side: the other side's lines in it are a gap with their sign after it, but for what a cited line
 * took the place of, TURN lines of it at most, which go under the run with that gap after them. A skip is a gap. */
function codeOf(stop, calls) {
  const text = textAt(stop.side, stop.path);
  const keep = [...new Set([...stop.lines.map((line) => line.n), ...calls])].sort((a, b) => a - b);
  const range = stop.range;
  const shown = new Set();
  let head = null;
  if (range && touched(stop.path, stop.side, range)) for (let n = range[0]; n <= range[1]; n++) shown.add(n);
  else {
    const [lo, hi] = range ?? [1, text.length];
    if (range) {
      // Its name and parameters, after its doc comment, up to the line that opens its body.
      let from = lo, to = lo, depth = 0;
      while (from < hi && COMMENT.test(text[from - 1])) from++;
      for (to = from; to < Math.min(hi, from + 20); to++) {
        depth += net(text[to - 1], "([", ")]");
        if (depth <= 0 && /([{;]|=>)\s*$/.test(bareCode(text[to - 1]))) break;
      }
      head = [from, to];
      for (let k = from; k <= to; k++) shown.add(k);
      shown.add(hi);
    }
    for (const n of keep) { const [a, b] = statement(text, n, lo, hi); for (let k = a; k <= b; k++) shown.add(k); }
    // Outside any function, an if shows its elses, and the exits between the lines it shows show with the ifs they
    // sit in: the doors a case can leave by.
    if (!range) {
      for (const k of [...shown]) if (BRANCH.test(text[k - 1])) for (const c of chainOf(text, k, hi)) shown.add(c);
      if (keep.length) for (let k = keep[0]; k <= keep.at(-1); k++) {
        if (shown.has(k) || !/^\s*(return|throw|continue|break)\b/.test(text[k - 1])) continue;
        shown.add(k);
        for (let u = k - 1; u >= Math.max(lo, k - 6); u--) if (BRANCH.test(text[u - 1])) { shown.add(u); for (const c of chainOf(text, u, hi)) shown.add(c); break; }
      }
      const sorted = [...shown].sort((a, b) => a - b);
      for (let i = 1; i < sorted.length; i++) for (let k = sorted[i - 1] + 1; k < sorted[i]; k++) shown.add(k);
    }
    // A head of three lines or more goes on one line when it is short enough to read as one, else only its
    // first line shows (the name), and what the case needs of the rest is in the lines it cites.
    if (head && head[1] - head[0] >= 2) {
      const joined = text.slice(head[0] - 1, head[1]).map((line) => line.trim()).join(" ");
      if (joined.length > 110 || keep.some((n) => n > head[0] && n <= head[1])) {
        for (let k = head[0] + 1; k <= head[1]; k++) if (!keep.includes(k)) shown.delete(k);
        head = null;
      }
    } else head = null;
  }
  const key = stop.side === "old" ? "o" : "n", otherKey = key === "n" ? "o" : "n";
  const cited = new Map(stop.lines.map((line) => [line.n, line]));
  let lines = [];
  const file = files.get(stop.path);
  if (file) {
    // What a cited line took the place of goes under its run, past the lines after it that only close brackets,
    // so it doesn't split the statement the run ends in.
    const under = new Map();
    const put = (line) => lines.push(line, ...(under.get(line[key]) ?? []));
    let run = [], before = false;
    const close = (next) => {
      const own = run.filter((line) => line[key] != null && shown.has(line[key]));
      const theirs = run.filter((line) => line[key] == null);
      // A run the stop shows a line of, or sits between two lines it shows.
      const inside = theirs.length > 0 && (own.length > 0 || (before && next && shown.has(next[key])));
      const took = inside ? own.map((line) => cited.get(line[key])).filter((line) => line?.other) : [];
      const from = Math.min(...took.map((line) => theirs.findIndex((one) => one[otherKey] === line.other.n)));
      const turn = took.length ? theirs.slice(from, from + TURN) : [];
      // The rest of the other side is a gap with its sign, which a pane older than it draws as lines skipped.
      const rest = inside && theirs.length > turn.length ? [{ s: theirs[0].s, gap: theirs.length - turn.length }] : [];
      if (turn.length) {
        let at = own.at(-1)[key];
        while (shown.has(at + 1) && /^\s*[)\]}][\s)\]};,]*$/.test(bareCode(text[at]))) at++;
        under.set(at, [...turn, ...rest]);
      }
      own.forEach(put);
      if (!turn.length) lines.push(...rest);
      run = [];
    };
    for (const line of file.lines) {
      if (line.s !== " ") { run.push(line); continue; }
      close(line);
      before = shown.has(line[key]);
      if (before) put(line);
    }
    close(null);
  } else lines = [...shown].sort((a, b) => a - b).map((n) => ({ s: " ", [key]: n, t: text[n - 1] }));
  const code = [];
  let last = null;
  for (const line of lines) {
    const n = line[key];
    // Only a line of the stop's own side has a gap before it: the other side's go with the run above them.
    if (n != null && last != null && n > last + 1) code.push({ gap: n - last - 1 });
    if (n != null) last = n;
    if (line.gap) { code.push({ gap: line.gap, sign: line.s, mine: false }); continue; }
    const mine = n != null ? cited.get(n) : null;
    code.push({ n: n ?? line[otherKey], sign: line.s, t: line.t, mine: n != null, cited: Boolean(mine), notes: mine?.notes ?? [] });
  }
  // A long head (name, parameters, return type) on one line, when nothing the change removed sits in it.
  if (head) {
    const at = code.findIndex((line) => line.mine && line.n === head[0]);
    const run = at < 0 ? [] : code.slice(at, at + head[1] - head[0] + 1);
    if (run.length === head[1] - head[0] + 1 && run.every((line, k) => line.mine && line.n === head[0] + k && !line.cited)) {
      const sign = run.every((line) => line.sign === run[0].sign) ? run[0].sign : " ";
      code.splice(at, run.length, { n: head[0], to: head[1], sign, t: run.map((line) => line.t.trim()).join(" "), mine: true, cited: false, notes: [], joined: run.map((line) => line.n) });
    }
  }
  return code;
}

/** The tests in the change a case names, matched to their rows; a name that matches none is dropped. */
const testRows = rows.filter((row) => row.block && row.kind === "test");
function testsNamed(names) {
  const found = [];
  for (const name of names ?? []) {
    const want = squash(name).toLowerCase().replace(/^["'`]|["'`]$/g, "");
    const row = testRows.find((one) => {
      const have = squash(one.name).toLowerCase();
      if (have === want || want.endsWith(" " + have)) return true;
      if (!/%[sdifjo#]/.test(have)) return false;
      const pattern = have.split(/%[sdifjo#]/).map((piece) => piece.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".+");
      return new RegExp(`(^| )${pattern}$`).test(want);
    });
    if (row && !found.includes(row)) found.push(row);
  }
  return found;
}

/** The test line Claude says asserts a fact's answer, where otis finds it in a test file of the change; or null. */
function pinOf(test) {
  const path = (test?.path ?? "").trim().replace(/^(\.\/|[ab]\/)/, "");
  if (!path || !testFiles.has(path)) return null;
  const text = textAt("new", path);
  const n = text ? findLine(text, test.line, test.code) : 0;
  return n ? { path, n, t: text[n - 1].trim(), where: `${basename(path)}:${n}` } : null;
}
/** Painted code without the spaces it starts with. */
const trimPainted = (painted) => {
  let started = false;
  return (painted ?? "").split(/(\x1b\[[0-9;]*m)/).map((token) => {
    if (started || token.startsWith("\x1b[")) return token;
    const rest = token.replace(/^\s+/, "");
    if (rest) started = true;
    return rest;
  }).join("");
};

// What the cases leave out: every changed row of code no case's route runs through, asked for again in the same
// build, so the cases come all at once and cover the change. Kept with the first answer.
if (told && !told.cached) {
  const covered = new Set();
  for (const one of told.cases) for (const stop of (one.stops ?? []).flatMap(placeStops)) for (const row of stop.covers) covered.add(row);
  for (const row of [...covered]) for (const used of uses.get(row)) covered.add(used);
  const left = rows.filter((row) => meat(row.path) && !row.imports && !covered.has(row));
  if (left.reduce((n, row) => n + row.add + row.del, 0) >= 20) {
    const more = await tellCases(left, told);
    if (more) {
      // Most of what was left belongs on a case already told: its stops go on that case's route, and only the
      // rest are cases of their own.
      for (const add of more.adds) {
        const to = told.cases[add.case - 1];
        to.stops.push(...add.stops);
        to.tests = [...new Set([...to.tests, ...add.tests])];
        to.data = [...new Set([...to.data, ...add.data])];
      }
      told.cases.push(...more.cases);
      for (const group of more.groups) if (!told.groups.some((one) => bare(one.group).toLowerCase() === bare(group.group).toLowerCase())) told.groups.push(group);
      told.cost += more.cost;
      told.turns += more.turns;
      if (told.kept) { const { sources, kept, ...result } = told; writeFileSync(told.kept + ".new", JSON.stringify(result)); renameSync(told.kept + ".new", told.kept); }
    }
  }
}

const parts = [];
if (told) {
  const RANK = { "ends differently": 0, "only a label": 1, "the same": 2 };
  // A case the author describes is one whose own sentence about it otis finds in their words.
  const saidOf = (one) => {
    const quote = unmark(one.said);
    const source = quote && told.sources.find((s) => plain(s.text).includes(plain(quote)));
    return source ? { quote, from: source.from } : null;
  };
  // In the order Claude gave them, which is the order to read them in; a group's cases together, the first
  // spelling of a group naming it.
  const groups = [];
  for (const one of told.cases) { const group = bare(one.group); if (!groups.some((g) => g.toLowerCase() === group.toLowerCase())) groups.push(group); }
  const groupAt = (one) => groups.findIndex((g) => g.toLowerCase() === bare(one.group).toLowerCase());
  const order = told.cases.map((one, at) => ({ one, at, said: saidOf(one) })).sort((a, b) => groupAt(a.one) - groupAt(b.one) || a.at - b.at);
  const whereOf = new Map((told.groups ?? []).map((one) => [bare(one.group).toLowerCase(), coded(one.where)]));
  const keys = [];
  // One function cited twice is one stop, with both sets of lines. A line cited twice keeps each case's reading
  // of it, one a case, the cases that read it alike sharing it; a stop on lines the change replaced brings none.
  const merge = (stops, placed) => {
    for (const stop of placed) {
      const same = stops.find((x) => x.path === stop.path && x.side === stop.side && x.name === stop.name);
      if (!same) { stops.push(stop); continue; }
      for (const line of stop.lines) {
        const was = same.lines.find((x) => x.n === line.n);
        if (!was) { same.lines.push(line); continue; }
        for (const note of line.notes) {
          if (was.notes.some((one) => one.of.some((k) => note.of.includes(k)))) continue;
          const alike = was.notes.find((one) => one.value === note.value);
          if (alike) alike.of.push(...note.of); else was.notes.push(note);
        }
      }
      same.lines.sort((a, b) => a.n - b.n);
      for (const row of stop.covers) same.covers.add(row);
      same.mark = same.lines.some((line) => line.sign !== " ") ? "◆" : same.covers.size ? "●" : "○";
      same.is ||= stop.is;
      same.fresh &&= stop.fresh;
    }
    return stops;
  };
  // A path: the cases that come in the same way, read as one route with each function on it once, and the cases
  // themselves as the situations that take it, each line saying what holds there for each.
  for (const [g, group] of groups.entries()) {
    const stops = [], inputs = [];
    order.filter(({ one }) => groupAt(one) === g).forEach(({ one, said }, k) => {
      const own = merge([], (one.stops ?? []).flatMap(placeStops));
      for (const stop of own) for (const line of stop.lines) for (const note of line.notes) note.of = [k];
      nest(own);
      const change = RANK[one.change] == null ? "ends differently" : one.change;
      inputs.push({
        title: bare(one.name), kind: said ? "case" : "also", setup: coded(one.setup), was: bare(one.was), now: bare(one.now), change,
        // New code: the route starts in code the change adds, so the case has no before; one that ends the same had one.
        fresh: change !== "the same" && own.length > 0 && own.filter((stop) => stop.parent < 0).every((stop) => stop.fresh),
        quote: said?.quote ?? "",
        facts: (one.facts ?? []).slice(0, 5).map((fact) => ({ what: coded(fact.what), before: coded(fact.before), after: coded(fact.after), pinned: pinOf(fact.test) })),
        tests: one.tests ?? [], data: one.data ?? [],
      });
      merge(stops, own);
    });
    nest(stops);
    // A route whose first stop the change's own code calls: that function goes above it, with the line that calls
    // it, so the path shows where it comes from and what happens around it.
    const first = stops.findIndex((stop) => stop.parent < 0);
    const up = first < 0 ? null : caller(stops[first]);
    if (up && up.verb === "calls" && up.fn && files.has(up.path) && !stops.some((stop) => stop.path === up.path && stop.name === up.fn)) {
      const def = ownOf("new", up.path, up.n);
      const entry = entryAt(up.path, "new", up.n);
      const covers = new Set();
      const unit = entry?.line.owner ?? smallestUnit(up.path, "new", up.n);
      if (rowByUnit.has(unit)) covers.add(rowByUnit.get(unit));
      stops.unshift({ name: def.name, is: "", path: up.path, side: "new", where: where(up.path), inChange: true, range: [def.start, def.end], inside: def.inside,
        mark: touched(up.path, "new", [def.start, def.end]) ? "◆" : covers.size ? "●" : "○", fresh: Boolean(files.get(up.path)?.added || unit?.mark === "new"), lines: [], covers, parent: -1, call: null });
      for (const stop of stops.slice(1)) if (stop.parent >= 0) stop.parent++;
      stops[first + 1].parent = 0;
      stops[first + 1].call = { n: up.n, t: textAt("new", up.path)[up.n - 1], sign: entry ? entry.line.s : " ", verb: "calls" };
    }
    // A stop after the first that nothing on the route calls: what in the code calls it, to show how the path gets there.
    stops.forEach((stop, i) => { if (stop.parent < 0 && stops.findIndex((one) => one.parent < 0) !== i) stop.from = caller(stop); });
    stops.forEach((stop, i) => { stop.code = codeOf(stop, stops.filter((kid) => kid.parent === i).map((kid) => kid.call.n)); });
    const runs = testsNamed(inputs.flatMap((input) => input.tests));
    for (const stop of stops) {
      keys.push(`${stop.side}\t${stop.path}`);
      if (stop.code.some((line) => line.n && !line.mine)) keys.push(`${stop.side === "old" ? "new" : "old"}\t${stop.path}`);
    }
    // The changed files that hold the data it runs on: a case file, a migration.
    const data = [...new Set(inputs.flatMap((input) => input.data).map((path) => path.trim().replace(/^(\.\/|[ab]\/)/, "")).filter((path) => files.has(path) && meat(path)))];
    // A path opens as its first case tells it, the change's main one, and ends as the case it moves most.
    const most = inputs.reduce((a, b) => (RANK[b.change] < RANK[a.change] ? b : a));
    parts.push({
      kind: inputs.some((input) => input.kind === "case") ? "case" : "also", title: group, group, where: whereOf.get(group.toLowerCase()) ?? "",
      setup: inputs[0].setup, was: most.was, now: most.now, change: most.change, fresh: most.fresh,
      inputs: inputs.map(({ setup, tests, data, ...input }, k) => ({ letter: String.fromCharCode(65 + (k % 26)).repeat(Math.floor(k / 26) + 1), ...input })), stops, runs, data,
      // Its tests are named under it, not read in it.
      rows: [...new Set([...stops.flatMap((stop) => [...stop.covers]), ...rows.filter((row) => data.includes(row.path))])],
    });
  }
  await paint(keys);
  for (const part of parts) for (const stop of part.stops) {
    for (const line of stop.lines) {
      line.paint = colored(stop.side, stop.path, line.n);
      if (line.other) line.other.paint = colored(stop.side === "old" ? "new" : "old", stop.path, line.other.n);
    }
    if (stop.call) { const a = part.stops[stop.parent]; stop.call.paint = colored(a.side, a.path, stop.call.n); }
    const other = stop.side === "old" ? "new" : "old";
    for (const line of stop.code) {
      if (line.joined) line.paint = line.joined.map((n) => trimPainted(colored(stop.side, stop.path, n))).join(" ");
      else if (line.n) line.paint = colored(line.mine ? stop.side : other, stop.path, line.n);
    }
  }
} else {
  commits.forEach((commit, at) => parts.push({ kind: "story", title: commit.subject, quote: "", origin: short(commit.sha), rows: rows.filter((row) => row.commit === at) }));
}
const onRoute = new Set(parts.flatMap((part) => part.rows));
// A file's lines outside any symbol (its imports, say) go under the first case with a stop in that file.
if (told) for (const part of parts) for (const stop of part.stops) for (const row of rows) if (row.rest && row.path === stop.path && !onRoute.has(row)) { part.rows.push(row); onRoute.add(row); }
// Told as cases, what no case runs is read elsewhere when it is a test or wiring (the files tab) or what a row on a
// route uses (the list opens it under that row); only the rest of the meat is loose.
const reached = new Set([...onRoute].flatMap((row) => [...uses.get(row)]));
const elsewhere = told ? rows.filter((row) => !onRoute.has(row) && (!meat(row.path) || reached.has(row))) : [];
const loose = rows.filter((row) => !onRoute.has(row) && !elsewhere.includes(row));
if (loose.length) parts.push({ kind: "rest", title: told ? "Changed lines no case runs" : "In the change, and in no part", quote: "", origin: null, rows: loose });
const sentences = parts.filter((part) => part.rows.length || part.stops?.length);
let numbered = 0;
for (const part of sentences) part.num = part.kind === "rest" ? "·" : String(++numbered);

/** Under a part: code in reading order, then tests. Stray imports are one row, and so are a spec's helpers. */
function gather(list, test) {
  const mine = list.filter((row) => row.test === test).sort((a, b) => a.order - b.order);
  const bundle = (pick, least, name, kindOf) => {
    const some = mine.filter(pick);
    if (some.length < least) return;
    const marks = new Set(some.map((row) => row.mark)), places = new Set(some.map((row) => row.where));
    const one = {
      id: some[0].id + "+", name: `${some.length} ${name}`, prose: true, mark: marks.size === 1 ? some[0].mark : "changed", kind: kindOf(some),
      where: places.size === 1 ? some[0].where : `${places.size} files`, doc: "", tag: "", cases: null, symbol: false, block: false, rest: true,
      lines: some.flatMap((row) => ["#" + (row.prose ? row.where : `${row.name}  ${row.where}`), ...row.lines]),
      nums: some.flatMap((row) => [0, ...row.nums]), paint: some.flatMap((row) => [null, ...(row.paint ?? row.lines.map(() => null))]),
      add: some.reduce((sum, row) => sum + row.add, 0), del: some.reduce((sum, row) => sum + row.del, 0),
    };
    mine.splice(mine.indexOf(some[0]), 1, one);
    for (const row of some.slice(1)) mine.splice(mine.indexOf(row), 1);
  };
  bundle((row) => row.imports, 2, "import changes", (some) => `${some.length} files`);
  if (test) bundle((row) => row.symbol, 3, "helpers", (some) => some.map((row) => row.name).join(", "));
  return mine.map(({ id, name, mark, kind, where, doc, tag, prose, cases, add, del, lines, nums, paint, notes, symbol, block, rest }) =>
    ({ id, name, mark, kind, where, doc, tag, prose, cases, add, del, lines, nums, paint: paint ?? null, notes: notes ?? null, symbol, block, rest }));
}

const total = { add: 0, del: 0 };
for (const file of files.values()) for (const line of file.lines) { if (line.s === "+") total.add++; else if (line.s === "-") total.del++; }
const sum = (list, key) => list.reduce((n, row) => n + row[key], 0);
const testName = (row) => (row.cases && row.name.includes("%s") ? row.name.split("%s").join(row.cases) : row.name);
const outline = {
  title: titleArg ?? commits.at(-1)?.subject ?? "", label: labelArg ?? `${short(base)}..${short(head)}`, base, head,
  add: total.add, del: total.del, commits: commits.map((commit) => ({ sha: short(commit.sha), subject: commit.subject })),
  filedBy: told ? told.model : null, described: Boolean(description), reader: told?.reader ?? "",
  // The whole change in a sentence or two, read before its cases.
  summary: told?.summary ?? "",
  // The rows the list leaves out of what no case runs, since they are read elsewhere.
  elsewhere: elsewhere.flatMap((row) => row.at),
  cases: sentences.filter((part) => part.kind === "case" || part.kind === "also").length, stories: numbered,
  sentences: sentences.map((part, at) => ({
    id: `s${at + 1}`, kind: part.kind, num: part.num, text: part.title, group: part.group ?? "",
    setup: part.setup ?? "", where: part.where ?? "", was: part.was ?? "", now: part.now ?? "", change: part.change ?? "",
    ending: part.fresh && part.now ? `new → ${part.now}` : part.was || part.now ? `${part.was || "?"} → ${part.now || "?"}` : "",
    // The first case to say where this runs says it in full; the rest point back to it.
    whereAt: part.where ? sentences.find((one) => one.where === part.where).num : "",
    quote: part.quote ?? "", origin: part.origin ?? null, from: part.kind === "rest" ? "rest" : "author", links: [],
    facts: part.facts ?? [], fresh: part.fresh ?? false, ends: part.ends ?? "", stopped: part.stopped ?? "", data: part.data ?? [],
    // The situations that take a path, in the order to read them: what its lines' notes are of.
    inputs: part.inputs ?? [],
    stops: (part.stops ?? []).map(({ covers, ...stop }) => stop),
    runs: (part.runs ?? []).map((row) => ({ name: testName(row), where: row.where })),
    add: sum(part.rows, "add"), del: sum(part.rows, "del"),
    ntests: part.runs ? part.runs.length : part.rows.filter((row) => row.block && row.kind === "test").length,
    code: gather(part.rows, false), tests: gather(part.rows, true),
    units: [false, true].flatMap((test) => part.rows.filter((row) => row.test === test).sort((a, b) => a.order - b.order).flatMap((row) => row.at)),
  })),
};
outline.ms = Date.now() - started;

// The page draws code in its own palette: each run of bat's colors becomes a class named for its gruvbox color,
// so the page's dark and light themes both color it.
const GRUVBOX = { comment: [146, 131, 116], red: [251, 73, 52], ink: [251, 241, 199], text: [235, 219, 178], soft: [189, 174, 147],
  aqua: [142, 192, 124], green: [184, 187, 38], blue: [131, 165, 152], yellow: [250, 189, 47], purple: [211, 134, 155], orange: [254, 128, 25] };
const xterm = (n) => (n < 16 ? [[0, 0, 0], [205, 0, 0], [0, 205, 0], [205, 205, 0], [0, 0, 238], [205, 0, 205], [0, 205, 205], [229, 229, 229],
  [127, 127, 127], [255, 0, 0], [0, 255, 0], [255, 255, 0], [92, 92, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255]][n]
  : n < 232 ? [Math.floor((n - 16) / 36), Math.floor((n - 16) / 6) % 6, (n - 16) % 6].map((c) => (c ? 55 + c * 40 : 0)) : Array(3).fill(8 + (n - 232) * 10));
const nearest = (rgb) => Object.entries(GRUVBOX).reduce((best, [name, at]) => {
  const far = at.reduce((sum, c, i) => sum + (c - rgb[i]) ** 2, 0);
  return far < best.far ? { name, far } : best;
}, { name: "ink", far: Infinity }).name;
function toHtml(painted) {
  if (painted == null) return null;
  let out = "", name = null;
  for (const token of painted.replace(/\t/g, "    ").split(/(\x1b\[[0-9;]*m)/)) {
    if (token.startsWith("\x1b[")) {
      const p = token.slice(2, -1).split(";").map(Number);
      if (p[0] === 38 && p[1] === 2) name = nearest(p.slice(2, 5));
      else if (p[0] === 38 && p[1] === 5) name = nearest(xterm(p[2]));
      else if (!p[0]) name = null;
      continue;
    }
    if (!token) continue;
    const text = token.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    out += name && name !== "ink" ? `<span class="c-${name}">${text}</span>` : text;
  }
  return out;
}
const forPage = () => JSON.stringify(outline, (key, value) => {
  if (key === "paint") return undefined;
  if (value && typeof value === "object" && !Array.isArray(value) && "paint" in value) return { ...value, html: Array.isArray(value.paint) ? value.paint.map(toHtml) : toHtml(value.paint) };
  return value;
}).replace(/</g, "\\u003c");
if (outlineOut) writeFileSync(outlineOut, JSON.stringify(outline));
if (htmlOut) {
  // A change told as cases reads as a document of its cases; one told by commit, as the outline of its sentences.
  const template = readFileSync(join(dirname(fileURLToPath(import.meta.url)), outline.cases ? "cases.html" : "sentences.html"), "utf8");
  writeFileSync(htmlOut, template.split("/*SENTENCES*/null").join(forPage()));
  console.log(htmlOut);
} else if (outlineOut) {
  console.log(outlineOut);
} else if (asJson) {
  process.stdout.write(JSON.stringify(outline) + "\n");
} else {
  if (outline.summary) console.log(outline.summary);
  for (const part of outline.sentences) {
    if (part.kind === "rest") console.log("\nON NO ROUTE");
    console.log(`\n${part.num}  ${part.text}${part.ending ? `   ${part.ending}` : ""}${part.change && part.change !== "ends differently" ? `  (${part.change})` : ""}`);
    if (part.setup) console.log(`   ${part.setup}`);
    for (const input of part.inputs) {
      console.log(`   ${input.letter}  ${input.title}   ${input.fresh ? "new" : input.was || "?"} → ${input.now || "?"}${input.change !== "ends differently" ? `  (${input.change})` : ""}`);
      if (input.quote) console.log(`      said  ${input.quote}`);
    }
    if (part.quote) console.log(`   said  ${part.quote}`);
    const depth = (stop) => (stop.parent < 0 ? 0 : 1 + depth(part.stops[stop.parent]));
    if (part.where) console.log(`   where: ${part.where}`);
    part.stops.forEach((stop, i) => {
      if (stop.from) console.log(`     ↓ ${stop.from.fn || "code outside any function"} in ${stop.from.where}:${stop.from.n} ${stop.from.verb} it`);
      else if (stop.from === null) console.log("     ↓ next");
      const pad = "  ".repeat(depth(stop));
      if (stop.call) console.log(`   ${pad}called at ${stop.call.n}: ${stop.call.t.trim()}`);
      console.log(`   ${pad}${stop.mark} ${stop.name}  ${stop.where}${stop.inChange ? "" : ", not in this change"}${stop.is ? `: ${stop.is}` : ""}`);
      for (const line of stop.lines) {
        console.log(`       ${String(line.n).padStart(5)} ${line.sign === " " ? " " : line.sign} ${line.t.trim()}${line.notes.map((note) => `      ${note.of.map((k) => part.inputs[k].letter).join(" ")}: ${note.value}`).join("")}`);
        if (line.other) console.log(`       ${String(line.other.n).padStart(5)} ${stop.side === "old" ? "now" : "was"} ${line.other.t.trim()}`);
      }
    });
    for (const run of part.runs) console.log(`   ◦ ${run.name}  ${run.where}`);
    if (part.kind === "rest") for (const row of part.code) console.log(`    ${row.mark.padEnd(8)} ${row.name}  ${row.kind}  +${row.add} -${row.del}  ${row.where}`);
  }
  console.log(`\n${outline.cases} cases, ${rows.length} rows, ${loose.length} on no route, +${total.add} -${total.del}, ${outline.ms} ms${told?.cached ? ", cases cached" : ""}`);
}
