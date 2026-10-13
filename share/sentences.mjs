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
const testFiles = new Set((graph?.definitions ?? []).filter((def) => def.box?.kind === "tests").map((def) => def.path));
for (const entry of graph?.files ?? []) if (entry.box?.kind === "tests") testFiles.add(entry.path);
for (const path of files.keys()) if (TESTISH.test(path)) testFiles.add(path);

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
async function tellCases() {
  const model = modelArg ?? "claude-sonnet-5-5";
  const sources = [
    ...(description ? [{ from: "description", text: (titleArg ? titleArg + "\n\n" : "") + description }] : []),
    ...commits.map((commit) => ({ from: short(commit.sha), text: commit.subject + (commit.body ? "\n\n" + commit.body : "") })),
  ];
  if (model === "off" || !rows.length) return null;
  const said = sources.map((source) => source.text).join("\n\n");
  const key = createHash("sha1").update(JSON.stringify([said, rows.map((row) => [row.id, row.add, row.del]), model, 11])).digest("hex").slice(0, 16);
  const cached = cacheDir && join(cacheDir, `${base}-${head}.${key}.json`);
  if (cached && existsSync(cached)) { try { return { ...JSON.parse(readFileSync(cached, "utf8")), sources, cached: true }; } catch { /* asked again */ } }

  const shown = (row) => row.lines.slice(0, row.block ? 12 : 60).map((line, at) =>
    (line[0] === "~" ? "        ..." : `${String(row.nums[at] || "").padStart(6)} ${line[0] === " " ? " " : line[0]} ${line.slice(1)}`));
  const prompt = [
    "A reviewer wants to understand this code change by its cases: the concrete situations the code meets (an input, an answer from another system, a timing), each followed through the code in the order it runs, so they can see how that situation ended before the change, how it ends now, and which lines decide it.",
    "",
    "You can read the repository on both sides of the change with these commands, one per call, with no pipes:",
    `  git -C ${root} grep -n -e <pattern> ${head} -- <paths>      search the code after the change (${base} for before)`,
    `  git -C ${root} grep -n -e '' ${head} -- <path>              a whole file, every line numbered`,
    `  git -C ${root} show ${head}:<path>`,
    "Follow each case past the changed lines until you reach where its ending is decided: what a person or another system sees, whether it is tried again, what is stored. That is often in code this change never touched: who calls the changed code, who catches what it throws, who reads the flag or value it returns (git grep for the field's name). Going that deep on the main cases matters more than listing many. Stop when following further would not change the ending, and say where you stopped. Use up to about 60 commands.",
    "",
    "cases: the situations whose ending this change moves, the main ones first, grouped by where they come in; usually 6 to 16. Add a few a reader would expect to have changed that end the same (\"the same\"), and ones where only a label moved: a value only logs, metrics or a stored field read (\"only a label\").",
    "- group: where the case comes in, 2 to 6 everyday words, like \"we send Apple a message\". Cases that come in the same way use the same words.",
    "- name: the situation, at most 7 everyday words, like \"Apple never answers a send\".",
    "- setup: one sentence that makes it concrete.",
    "- was, now: how it ended before and how it ends now, at most 8 words each, each a plain clause with its subject, the same words where they agree, like \"it is tried again\" and \"it fails, and may have been sent\".",
    "- change: \"ends differently\", \"only a label\" or \"the same\". Before you say a case ends differently because a value changed (a flag like retryable, an error's type), find what reads that value: when nothing acts on it, only logs, metrics or a stored field read it, the case is \"only a label\", and its was and now say what a person or system actually sees.",
    "- described: true when the author's words below describe this case, false when they never mention it.",
    "- said: the author's own sentence about this case, copied exactly from their words below, or \"\".",
    "- facts: at most 5 things a reviewer would compare: what (a question a newcomer would ask about this case, at most 6 words, like \"Is the model called?\" or \"What does the shopper see?\"), before and after (its answer before and after the change, at most 8 words each, plain enough to read alone, never a label only this code uses). In everyday words a teammate from outside this code would use; a code value only when it is what a person or another system sees, like a 400 status or a reason \"delivery_unknown\". When nothing ran for this case before the change, before is \"\".",
    "- stops: the route, in the order it runs. Each is a place in the code: name (the function's or symbol's own name, nothing else), is (what that function or place is for, at most 12 everyday words, like \"reads one page of the window's orders from the database\"), path (from the repository's root), side (\"new\" for the code after the change, \"old\" only for code the change removed), lines (the 1 to 5 lines there that decide this case, each with its line number on that side, its code copied exactly, and value: what holds on that line for this case, a short phrase that says what it is about, like \"the window has a rate, so go on\" or \"paid through Gale, so 2%\", never a bare true or false; or \"\"). Take unchanged code in when it decides the ending, and take in the function that calls the others when that is what holds the route together.",
    "- ends: one or two sentences on how it ends, before and after, that a teammate who has never seen this code can read on their own.",
    "- stopped: where you stopped following and what you left unfollowed, or \"\".",
    "- tests: the names of tests in this change that run this case, copied exactly from the rows below.",
    "",
    "groups: for each group your cases use (its words exactly as the cases give them), where: two to four sentences for a teammate who has never seen this part of the code: what this part of the system does; each word it gives its own meaning, defined in plain words (an eval's case, label and passing; a billing window; a gateway); and the main steps a case passes through, naming their functions in the order they run.",
    "",
    "Every changed row below should be on some case's route. For a row none of your cases runs, find what reads what it changes and make that a case.",
    "",
    "Write for a teammate who has never seen this code. Every phrase has its subject and its verb, the way you would say it aloud: \"the model is asked one question\", never \"asked once\". Never use a value, label or flag from the code as a word (NO, OPT_OUT, retryable): say what it means, like \"the expected answer is no\". A word this part of the code gives its own meaning is defined in its group's where, and every other field uses it only that way.",
    "",
    "Plain words in every sentence, nothing a teammate would have to ask about, and no markdown, with one exception: in setup, where, is, value, facts, ends and stopped, put each name from the code in backticks, like `needsJudgment` or `orderValue`, so a reader can tell it from an English word. Nowhere else.",
    "",
    "# The author's words",
    ...(sources.length ? sources.flatMap((source) => ["", `## ${source.from === "description" ? "merge request description" : `commit ${source.from}`}`, source.text]) : ["", "(none)"]),
    "",
    "# The changed rows: each line's number on its side, + added, - removed",
    ...rows.flatMap((row) => [
      "",
      `## ${row.name}${row.cases ? ` [${row.cases}]` : ""}`,
      `${row.test ? "test code" : "code"}, ${row.kind}, ${row.mark}${row.tag ? `, ${row.tag}` : ""}, +${row.add} -${row.del}, ${row.path}`,
      ...shown(row),
    ]),
  ].join("\n");
  const object = (properties) => ({ type: "object", additionalProperties: false, required: Object.keys(properties), properties });
  const list = (items) => ({ type: "array", items });
  const text = { type: "string" };
  const schema = object({
    cases: list(object({
      group: text, name: text, setup: text, was: text, now: text,
      change: { enum: ["ends differently", "only a label", "the same"] }, described: { type: "boolean" }, said: text,
      facts: list(object({ what: text, before: text, after: text })),
      stops: list(object({ name: text, is: text, path: text, side: { enum: ["new", "old"] }, lines: list(object({ line: { type: "integer" }, code: text, value: text })) })),
      ends: text, stopped: text, tests: list(text),
    })),
    groups: list(object({ group: text, where: text })),
  });
  const empty = mkdtempSync(join(tmpdir(), "otis-sentences-"));
  const budget = String(Number(git("config", "--default", "3", "--get", "otis.sentencesBudget").trim()) || 3);
  const answer = await new Promise((done) => {
    execFile(process.env.SEAM_CLAUDE || "claude", [
      "-p", "--model", model, "--restricted", "--tools", "Bash", "--add-dir", root,
      "--allowedTools", `Bash(git -C ${root} grep:*)`, `Bash(git -C ${root} show:*)`,
      "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--permission-prompts", "none",
      "--max-budget-usd", budget, "--output-format", "json", "--json-schema", JSON.stringify(schema),
    ], { cwd: empty, encoding: "utf8", maxBuffer: MAX, timeout: 600000 }, (error, out) => done(out || null)).stdin.end(prompt);
  });
  rmSync(empty, { recursive: true, force: true });
  let told;
  try { told = JSON.parse(answer).structured_output; } catch { told = null; }
  if (!told?.cases?.length) {
    console.error(`sentences: ${model} found no cases, so it is one part a commit: ${String(answer).slice(0, 300)}`);
    return null;
  }
  const spent = JSON.parse(answer);
  const result = { model, cases: told.cases, groups: told.groups ?? [], turns: spent.num_turns, cost: spent.total_cost_usd };
  if (cached) { mkdirSync(cacheDir, { recursive: true }); writeFileSync(cached + ".new", JSON.stringify(result)); renameSync(cached + ".new", cached); }
  return { ...result, sources };
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

/** The names in some lines worth matching on: long or camel-cased, and not the language's own words. */
const COMMON = new Set(["function", "readonly", "constructor", "undefined", "instanceof", "Response", "response", "Promise", "continue", "toString", "stringify", "default"]);
const identifiers = (lines) => new Set(lines.flatMap((line) => line.t.match(/[A-Za-z_$][\w$]*/g) ?? []).filter((word) => (word.length >= 8 || /[a-z][A-Z]/.test(word)) && !COMMON.has(word)));
/** Changed definitions by the name a line would use for them: a member by its own name, a constructor by its class's. */
const named = new Map();
for (const row of rows) {
  if (!row.symbol) continue;
  const [owner, own] = row.name.includes(".") ? row.name.split(".") : [null, row.name];
  const word = own === "constructor" ? owner : own;
  if (word.length < 6 && !/[a-z][A-Z]/.test(word)) continue;
  if (!named.has(word)) named.set(word, []);
  named.get(word).push(row);
}

/** A stop on a case's route, as otis finds it: each cited line where its code is (within a few lines of where
 * Claude said), what it replaced, and which changed rows it runs through. A line otis can't find is dropped. */
function placeStop(stop) {
  const path = stop.path.trim().replace(/^(\.\/|[ab]\/)/, "");
  const side = stop.side === "old" ? "old" : "new";
  const text = textAt(side, path);
  if (!text) return null;
  const lines = [];
  for (const cited of stop.lines ?? []) {
    const want = squash(cited.code);
    if (!want) continue;
    const fits = (k) => { const have = squash(text[k - 1]); return have === want || (want.length >= 8 && have.includes(want)); };
    let n = fits(cited.line) ? cited.line : 0;
    for (let d = 1; d <= 25 && !n; d++) n = [cited.line - d, cited.line + d].find((k) => k >= 1 && fits(k)) ?? 0;
    if (n && !lines.some((one) => one.n === n)) lines.push({ n, t: text[n - 1], value: coded(cited.value).replace(/\.$/, "") });
  }
  if (!lines.length) return null;
  lines.sort((a, b) => a.n - b.n);
  const covers = new Set();
  // New code: every line it cites is in a file or definition that did not exist before the change.
  let fresh = side === "new";
  for (const line of lines) {
    const found = entryAt(path, side, line.n);
    line.sign = found ? found.line.s : " ";
    const other = found && counterpart(found);
    if (other) line.other = { n: side === "old" ? other.n : other.o, t: other.t };
    const unit = found?.line.owner ?? smallestUnit(path, side, line.n);
    if (rowByUnit.has(unit)) covers.add(rowByUnit.get(unit));
    if (!(found?.file.added || unit?.mark === "new")) fresh = false;
  }
  // A changed definition its lines name is on the route too: the error it throws, the constant it checks.
  for (const word of identifiers(lines)) for (const row of named.get(word) ?? []) covers.add(row);
  const changed = lines.some((line) => line.sign !== " ");
  return {
    name: bare(stop.name), is: coded(stop.is).replace(/\.$/, ""), path, side, where: files.has(path) ? where(path) : basename(path), inChange: files.has(path),
    mark: changed ? "◆" : covers.size ? "●" : "○", fresh, lines, covers,
  };
}

/** Whether one stop leads to the next as far as the code shows: one names the other, or a name or field in
 * one's cited lines (the error it throws, the flag it sets) is near the other's, or seam has an edge between them. */
function leads(a, b) {
  const names = (stop) => [...(stop.name.match(/[A-Za-z_$][\w$]*/g) ?? []).filter((word) => word.length > 3), ...identifiers(stop.lines)];
  const near = (stop, words) => {
    const text = textAt(stop.side, stop.path);
    const chunk = text.slice(Math.max(0, stop.lines[0].n - 60), stop.lines.at(-1).n + 60).join("\n");
    return words.some((word) => new RegExp(`(^|[^\\w$])${word.replace(/\$/g, "\\$")}([^\\w$]|$)`).test(chunk));
  };
  if ((a.path === b.path && a.name === b.name) || near(a, names(b)) || near(b, names(a))) return true;
  const ids = (stop) => new Set([...stop.covers].map((row) => row.id));
  const x = ids(a), y = ids(b);
  return (graph?.edges ?? []).some((edge) => (x.has(edge.from) && y.has(edge.to)) || (y.has(edge.from) && x.has(edge.to)));
}

/** The definition a stop's lines all sit in, when the change has it: the smallest that holds them all. */
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

/** The line in a's function that calls or names b, the nearest to a's cited lines: never b's own definition. */
function callIn(a, b) {
  const name = callee(b);
  if (!name) return null;
  const text = textAt(a.side, a.path);
  const range = enclosing(a) ?? [Math.max(1, a.lines[0].n - 80), Math.min(text.length, a.lines.at(-1).n + 80)];
  const own = a.path === b.path && a.side === b.side ? enclosing(b) ?? [b.lines[0].n, b.lines.at(-1).n] : null;
  const uses = new RegExp(`(^|[^\\w$])${escape(name)}([^\\w$]|$)`);
  const defines = definition(name);
  let best = null;
  for (let n = range[0]; n <= range[1]; n++) {
    const line = text[n - 1] ?? "";
    if (!uses.test(line) || defines.test(line) || COMMENT.test(line) || /^\s*import\b/.test(line)) continue;
    if (own && n >= own[0] && n <= own[1]) continue;
    const distance = Math.min(...a.lines.map((one) => Math.abs(one.n - n)));
    if (!best || distance < best.distance) best = { n, distance };
  }
  return best && { n: best.n, t: text[best.n - 1] };
}

/** Who calls whom on a route, from the code: each stop under the stop whose function calls it (one before it
 * first), with the line that calls it. A stop nothing on the route calls stays at the top. */
function nest(stops) {
  stops.forEach((stop) => { stop.parent = -1; stop.call = null; });
  const above = (x, y) => { for (let k = stops[y].parent; k >= 0; k = stops[k].parent) if (k === x) return true; return false; };
  stops.forEach((b, j) => {
    const callers = stops.map((a, i) => (i === j ? null : { i, found: callIn(a, b) })).filter((one) => one?.found)
      .sort((x, y) => (x.i < j ? 0 : 1) - (y.i < j ? 0 : 1) || Math.abs(x.i - j) - Math.abs(y.i - j));
    const pick = callers.find(({ i }) => !above(j, i));
    if (!pick) return;
    b.parent = pick.i;
    const a = stops[pick.i], found = entryAt(a.path, a.side, pick.found.n);
    b.call = { n: pick.found.n, t: pick.found.t, sign: found ? found.line.s : " " };
    const unit = found?.line.owner ?? smallestUnit(a.path, a.side, pick.found.n);
    if (rowByUnit.has(unit)) a.covers.add(rowByUnit.get(unit));
  });
}

/** A line of code without its strings and its comment, for counting its brackets. */
const bareCode = (line) => (line ?? "").replace(/(["'`])(?:\\.|(?!\1)[^\\])*\1/g, '""').replace(/\/\/.*$/, "");
const net = (line, opens, closes) => { let depth = 0; for (const ch of bareCode(line)) { if (opens.includes(ch)) depth++; else if (closes.includes(ch)) depth--; } return depth; };

/** Where a stop's function starts and ends: from the nearest line above its lines that defines its name down to
 * where its braces close (a function inside another is its own), else the changed definition around its lines. */
function bounds(stop) {
  const name = /^[\w$.]+$/.test(stop.name) ? callee(stop) : null;
  if (!name) return enclosing(stop);
  const text = textAt(stop.side, stop.path), first = stop.lines[0].n, last = stop.lines.at(-1).n;
  const defines = definition(name);
  for (let start = first; start >= Math.max(1, first - 200); start--) {
    if (!defines.test(text[start - 1] ?? "")) continue;
    let depth = 0, opened = false;
    for (let end = start; end <= Math.min(text.length, start + 400); end++) {
      const line = text[end - 1];
      depth += net(line, "{", "}");
      opened ||= line.includes("{");
      if ((opened && depth <= 0) || (!opened && /;\s*$/.test(line))) return end >= last ? [start, end] : enclosing(stop);
    }
    return enclosing(stop);
  }
  return enclosing(stop);
}

/** The statement around line n, as far as brackets go: up to the bracket it sits in, down to where that closes,
 * or six lines on. */
function statement(text, n, lo, hi) {
  let start = n, sum = 0;
  for (let k = n - 1; k >= Math.max(lo, n - 8); k--) { sum += net(text[k - 1], "([", ")]"); if (sum > 0) { start = k; break; } }
  let end = n, depth = 0;
  for (let k = start; k <= n; k++) depth += net(text[k - 1], "([", ")]");
  for (let k = n + 1; depth > 0 && k <= Math.min(hi, n + 6); k++) { depth += net(text[k - 1], "([", ")]"); end = k; }
  return [start, end];
}

/** The code a stop shows, in the order of the diff: its whole function when that is short; else the function's
 * first lines, the statement around each line it cites or calls the next stop from, the lines between them when
 * only a few, and its closing line. Lines the change removed sit where the diff has them. A skip is a gap. */
const WHOLE = 25, FILL = 3;
function codeOf(stop, calls) {
  const text = textAt(stop.side, stop.path);
  const keep = [...new Set([...stop.lines.map((line) => line.n), ...calls])];
  const range = bounds(stop);
  const shown = new Set();
  if (range && range[1] - range[0] < WHOLE) for (let n = range[0]; n <= range[1]; n++) shown.add(n);
  else {
    const [lo, hi] = range ?? [1, text.length];
    if (range) {
      // Its name and parameters, after its doc comment, up to the line that opens its body.
      let from = lo, depth = 0;
      while (from < hi && COMMENT.test(text[from - 1])) from++;
      for (let n = from; n <= Math.min(hi, from + 8); n++) {
        shown.add(n);
        depth += net(text[n - 1], "([", ")]");
        if (depth <= 0 && /([{;]|=>)\s*$/.test(text[n - 1])) break;
      }
      shown.add(hi);
    }
    for (const n of keep) { const [a, b] = statement(text, n, lo, hi); for (let k = a; k <= b; k++) shown.add(k); }
    const sorted = [...shown].sort((a, b) => a - b);
    for (let i = 1; i < sorted.length; i++) if (sorted[i] - sorted[i - 1] - 1 <= FILL) for (let k = sorted[i - 1] + 1; k < sorted[i]; k++) shown.add(k);
  }
  const key = stop.side === "old" ? "o" : "n", otherKey = key === "n" ? "o" : "n";
  const cited = new Map(stop.lines.map((line) => [line.n, line]));
  const theirs = new Set(stop.lines.filter((line) => line.other).map((line) => line.other.n));
  let lines = [];
  const file = files.get(stop.path);
  if (file) {
    // A run the change removed is shown with the lines it sits between, or with the line it became.
    let pending = [], before = false;
    for (const line of file.lines) {
      if (line[key] == null) { pending.push(line); continue; }
      const here = shown.has(line[key]);
      lines.push(...pending.filter((one) => (here && (before || line.s !== " ")) || theirs.has(one[otherKey])));
      if (here) lines.push(line);
      pending = []; before = here;
    }
  } else lines = [...shown].sort((a, b) => a - b).map((n) => ({ s: " ", [key]: n, t: text[n - 1] }));
  const code = [];
  let last = null;
  for (const line of lines) {
    const n = line[key];
    if (n != null) {
      if (last != null && n > last + 1) code.push({ gap: n - last - 1 });
      last = n;
    }
    const mine = n != null ? cited.get(n) : null;
    code.push({ n: n ?? line[otherKey], sign: line.s, t: line.t, mine: n != null, cited: Boolean(mine), value: mine?.value ?? "" });
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

/** A value a fact gives, when a test in the change asserts it: the literal on one of the test's lines, beside the fact's own word. */
function asserted(fact, runs) {
  const literal = /"([^"]+)"|'([^']+)'|(?<![\w.])(-?\d{2,})(?![\w.])|\b(true|false|null)\b/.exec(fact.after);
  if (!literal) return false;
  const value = literal.slice(1).find(Boolean), weak = Boolean(literal[4]);
  const words = fact.what.toLowerCase().split(/\s+/).filter((word) => word.length > 3);
  return runs.some((row) => row.lines.some((line) => line.includes(value) && (!weak || words.some((word) => line.toLowerCase().includes(word)))));
}

const parts = [];
if (told) {
  const RANK = { "ends differently": 0, "only a label": 1, "the same": 2 };
  const groups = [];
  for (const one of told.cases) { const group = bare(one.group); if (one.described && !groups.some((g) => g.toLowerCase() === group.toLowerCase())) groups.push(group); }
  const groupAt = (one) => groups.findIndex((g) => g.toLowerCase() === bare(one.group).toLowerCase());
  const order = told.cases.map((one, at) => ({ one, at })).sort((a, b) =>
    (a.one.described ? 0 : 1) - (b.one.described ? 0 : 1) || (a.one.described ? groupAt(a.one) - groupAt(b.one) : 0)
    || (RANK[a.one.change] ?? 0) - (RANK[b.one.change] ?? 0) || a.at - b.at);
  const whereOf = new Map((told.groups ?? []).map((one) => [bare(one.group).toLowerCase(), coded(one.where)]));
  const keys = [];
  for (const { one } of order) {
    // One function cited twice is one stop, with both sets of lines.
    const stops = [];
    for (const stop of (one.stops ?? []).map(placeStop).filter(Boolean)) {
      const same = stops.find((x) => x.path === stop.path && x.side === stop.side && x.name === stop.name);
      if (!same) { stops.push(stop); continue; }
      for (const line of stop.lines) if (!same.lines.some((x) => x.n === line.n)) same.lines.push(line);
      same.lines.sort((a, b) => a.n - b.n);
      for (const row of stop.covers) same.covers.add(row);
      same.mark = same.lines.some((line) => line.sign !== " ") ? "◆" : same.covers.size ? "●" : "○";
      same.is ||= stop.is;
      same.fresh &&= stop.fresh;
    }
    nest(stops);
    stops.forEach((stop, i) => { stop.code = codeOf(stop, stops.filter((kid) => kid.parent === i).map((kid) => kid.call.n)); });
    const runs = testsNamed(one.tests);
    const quote = unmark(one.said);
    const source = quote && told.sources.find((s) => plain(s.text).includes(plain(quote)));
    for (const stop of stops) {
      keys.push(`${stop.side}\t${stop.path}`);
      if (stop.code.some((line) => line.n && !line.mine)) keys.push(`${stop.side === "old" ? "new" : "old"}\t${stop.path}`);
    }
    parts.push({
      kind: one.described ? "case" : "also", title: bare(one.name), group: one.described ? groups[groupAt(one)] : "",
      setup: coded(one.setup), where: whereOf.get(bare(one.group).toLowerCase()) ?? "", was: bare(one.was), now: bare(one.now), change: RANK[one.change] == null ? "ends differently" : one.change,
      quote: source ? quote : "", origin: source?.from ?? null,
      facts: (one.facts ?? []).slice(0, 5).map((fact) => ({ what: coded(fact.what), before: coded(fact.before), after: coded(fact.after), known: asserted(fact, runs) ? "test" : "read" })),
      // New code: the route starts in code the change adds, so the case has no before.
      stops, fresh: stops.length > 0 && stops.filter((stop) => stop.parent < 0).every((stop) => stop.fresh), ends: coded(one.ends), stopped: coded(one.stopped), runs,
      // Its tests bring their own setup: the suites, helpers and imports of the files they are in.
      rows: [...new Set([...stops.flatMap((stop) => [...stop.covers]), ...runs,
        ...rows.filter((row) => row.test && !(row.block && row.kind === "test") && runs.some((run) => run.path === row.path))])],
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
    for (const line of stop.code) if (line.n) line.paint = colored(line.mine ? stop.side : other, stop.path, line.n);
  }
} else {
  commits.forEach((commit, at) => parts.push({ kind: "story", title: commit.subject, quote: "", origin: short(commit.sha), rows: rows.filter((row) => row.commit === at) }));
}
const onRoute = new Set(parts.flatMap((part) => part.rows));
const loose = rows.filter((row) => !onRoute.has(row));
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
  filedBy: told ? told.model : null, described: Boolean(description),
  cases: sentences.filter((part) => part.kind === "case" || part.kind === "also").length, stories: numbered,
  sentences: sentences.map((part, at) => ({
    id: `s${at + 1}`, kind: part.kind, num: part.num, text: part.title, group: part.group ?? "",
    setup: part.setup ?? "", where: part.where ?? "", was: part.was ?? "", now: part.now ?? "", change: part.change ?? "",
    ending: part.was || part.now ? `${part.was || "?"} → ${part.now || "?"}` : "",
    quote: part.quote, origin: part.origin, from: part.kind === "rest" ? "rest" : "author", links: [],
    facts: part.facts ?? [], fresh: part.fresh ?? false, ends: part.ends ?? "", stopped: part.stopped ?? "",
    stops: (part.stops ?? []).map(({ covers, ...stop }) => stop),
    // A stop at the top after the first: whether the code shows the one before it leads there.
    hops: (part.stops ?? []).map((stop, i, all) => {
      const before = all.slice(0, i).findLast((one) => one.parent < 0);
      return stop.parent >= 0 || !before || leads(before, stop);
    }),
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
  let group = null;
  for (const part of outline.sentences) {
    const heading = part.kind === "case" ? part.group : part.kind === "also" ? "also changed, nobody named these" : part.kind === "rest" ? "on no route" : null;
    if (heading && heading !== group) { console.log(`\n${heading.toUpperCase()}`); group = heading; }
    console.log(`\n${part.num}  ${part.text}${part.ending ? `   ${part.ending}` : ""}${part.change && part.change !== "ends differently" ? `  (${part.change})` : ""}`);
    if (part.setup) console.log(`   ${part.setup}`);
    for (const fact of part.facts) console.log(`   ${fact.what}: ${fact.before} → ${fact.after}${fact.known === "test" ? "  (a test checks it)" : ""}`);
    if (part.quote) console.log(`   said  ${part.quote}`);
    const depth = (stop) => (stop.parent < 0 ? 0 : 1 + depth(part.stops[stop.parent]));
    if (part.where) console.log(`   where: ${part.where}`);
    part.stops.forEach((stop, i) => {
      if (!part.hops[i]) console.log("     ┄ not confirmed that the last stop leads here");
      const pad = "  ".repeat(depth(stop));
      if (stop.call) console.log(`   ${pad}called at ${stop.call.n}: ${stop.call.t.trim()}`);
      console.log(`   ${pad}${stop.mark} ${stop.name}  ${stop.where}${stop.inChange ? "" : ", not in this change"}${stop.is ? `: ${stop.is}` : ""}`);
      for (const line of stop.lines) {
        console.log(`       ${String(line.n).padStart(5)} ${line.sign === " " ? " " : line.sign} ${line.t.trim()}${line.value ? `      ${line.value}` : ""}`);
        if (line.other) console.log(`       ${String(line.other.n).padStart(5)} ${stop.side === "old" ? "now" : "was"} ${line.other.t.trim()}`);
      }
    });
    if (part.ends) console.log(`   ■ ${part.ends}`);
    if (part.stopped) console.log(`     stopped: ${part.stopped}`);
    for (const run of part.runs) console.log(`   ◦ ${run.name}  ${run.where}`);
    if (part.kind === "rest") for (const row of part.code) console.log(`    ${row.mark.padEnd(8)} ${row.name}  ${row.kind}  +${row.add} -${row.del}  ${row.where}`);
  }
  console.log(`\n${outline.cases} cases, ${rows.length} rows, ${loose.length} on no route, +${total.add} -${total.del}, ${outline.ms} ms${told?.cached ? ", cases cached" : ""}`);
}
