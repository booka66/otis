#!/usr/bin/env node
// story-pane.mjs <outline.json> <n>: case n of a change (sentences.mjs) as the symbol view's pane,
// FZF_PREVIEW_COLUMNS wide: what comes in, how it ended before and how it ends now, then its route through the code
// as the case runs it, like a debugger: what holds on each line it passes, the lines it never runs dim, and the
// tests that run it. The route is the same code for every case that comes in the same way, so moving from one of
// them to the next keeps the code where it is. A part told without cases is its words and its code.
//
// In a review, OTIS_CASE_THREADS is the MR's threads as git-mr-threads --json places them: each is drawn under the
// line of the route it sits on, and those on the rest of the case's code (OTIS_CASE_ON, their ids, one a line)
// after the route, each under its own line. With OTIS_PANE_MAP set, the pane opens with "\036map N" and N lines
// saying what a line of it is, by its number: a line of code (line, its file, side, first and last number, 1 if
// the file is in the change, the columns its code is in, and the place it is part of: a stop, or a thread's line)
// or a thread's (thread, its id, resolvable, resolved and draft), for otis-symbols to comment from what you select;
// or a paragraph's (text, the columns its words are in, and how it goes on from the line above: new, word after a
// space, or cut inside a word too long for a line), for otis-symbols to copy it as the one line it was.
// It also pins what comes in and how it ends ("\036pin N" and N lines), held at the pane's top while the rest scrolls.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

const [file, which] = process.argv.slice(2);
const outline = JSON.parse(readFileSync(file, "utf8"));
const part = outline.sentences[Number(which) - 1];
if (!part) process.exit(0);
// The route the case runs: its code, with each case's notes and skips by the case's at. An outline an older otis
// told has none, and is being told again behind it.
const route = part.route != null ? outline.routes?.[part.route] : null;
if ((part.kind === "case" || part.kind === "also") && !route) { console.log("\n  This change is being told again for this otis, which takes a moment."); process.exit(0); }
const stops = route?.stops ?? [];
const mine = (one) => one.of.includes(part.letter);
// The route as it was told, which its flags are filed under, whether or not the case is told again for you below.
const told = route?.text;
const W = Math.max(40, Number(process.env.FZF_PREVIEW_COLUMNS) || 96);
// The case told again for you (reword.mjs, from your words), laid over the case it was told from.
const reworded = (() => { try { return JSON.parse(readFileSync(file.replace(/\.json$/, `.reader.${which}.json`), "utf8")); } catch { return null; } })();
const rewording = existsSync(file.replace(/\.json$/, `.reader.${which}.running`));
// Only over the case it was told from, as it still is: as many stops on its route, each with as many of its notes;
// a case otis has since drawn otherwise is told again (retell).
const notesOf = (stop) => stop.lines.flatMap((line) => line.notes.filter(mine));
const overlaid = reworded?.of === part.text && reworded.stops?.length === stops.length && reworded.stops.every((stop, i) => stop.notes?.length === notesOf(stops[i]).length);
if (overlaid) {
  for (const key of ["text", "setup", "was", "now"]) if (part[key] || reworded[key]) part[key] = reworded[key];
  reworded.stops.forEach((stop, i) => {
    const one = stops[i];
    if (stop.is || one.is) one.is = stop.is;
    // Its notes told again, there and on the line as the code draws it.
    let j = 0;
    const values = new Map(one.lines.map((line) => [line.n, line.notes.filter(mine).map(() => stop.notes[j++])]));
    for (const line of [...one.lines, ...(one.code ?? [])]) if (values.has(line.n) && (line.cited || one.lines.includes(line))) line.notes.filter(mine).forEach((note, k) => { note.value = values.get(line.n)[k]; });
  });
}

const env = process.env;
const fg = (name, fallback) => `\x1b[${env[name] || fallback}m`;
const bgOf = (hex, fallback) => (/^#[0-9a-f]{6}$/i.test(hex || "") ? `\x1b[48;2;${parseInt(hex.slice(1, 3), 16)};${parseInt(hex.slice(3, 5), 16)};${parseInt(hex.slice(5, 7), 16)}m` : fallback);
const R = "\x1b[0m", B = "\x1b[1m", I = "\x1b[3m";
const T = fg("OTIS_T_TEXT", "39"), C = fg("OTIS_T_CONTEXT", "90"), A = fg("OTIS_T_ATTENTION", "33");
const G = fg("OTIS_T_GOOD", "32"), X = fg("OTIS_T_BAD", "31"), E = fg("OTIS_T_ELSEWHERE", "34");
const RM = fg("OTIS_T_REMOVED", env.OTIS_T_CONTEXT || "90");
const PLUS = bgOf(env.OTIS_T_PLUS, "\x1b[48;5;22m"), MINUS = bgOf(env.OTIS_T_MINUS, "\x1b[48;5;52m");
const RAISE = env.OTIS_T_CODEBG ? `\x1b[${env.OTIS_T_CODEBG}m` : "\x1b[48;5;237m";
// A line Claude cites stands out on a stronger ground: the diff's emphasis, or the code's ground lifted.
const PLUS_EMPH = bgOf(env.OTIS_T_PLUS_EMPH, "\x1b[48;5;28m"), MINUS_EMPH = bgOf(env.OTIS_T_MINUS_EMPH, "\x1b[48;5;88m");
const LIFT = ((rgb) => (rgb ? `\x1b[48;2;${rgb.slice(1).map((c) => Math.max(0, Math.min(255, Number(c) + (env.OTIS_T_LIGHT ? -24 : 24)))).join(";")}m` : "\x1b[48;5;239m"))(/48;2;(\d+);(\d+);(\d+)/.exec(RAISE));
// What a changed line changed, on the ground the diff's preview has it on (share/delta.sh), stronger than a cited line's.
const PLUS_WORD = bgOf(env.OTIS_T_PLUS_WORD, "\x1b[48;5;34m"), MINUS_WORD = bgOf(env.OTIS_T_MINUS_WORD, "\x1b[48;5;124m");

const YOURS = fg("OTIS_T_YOURS", "35");

const out = [], map = [], pinned = [];
/** A line of the pane, and, for a line you can comment from or copy as a paragraph, what it is (the map). */
const say = (line = "", what = "") => { out.push(line); if (what) map.push(`${out.length}\t${what}`); };

// The review's threads on lines, by where they sit; each drawn once, under the first line of the pane it is on.
const threads = (() => { try { return JSON.parse(readFileSync(env.OTIS_CASE_THREADS, "utf8")).filter((one) => one.where?.state === "line" && one.notes?.length); } catch { return []; } })();
const threadsAt = new Map();
for (const one of threads) {
  const at = `${one.where.path}\t${one.where.side}\t${one.where.line}`;
  threadsAt.set(at, [...(threadsAt.get(at) ?? []), one]);
}
const onCase = (() => { try { return new Set(readFileSync(env.OTIS_CASE_ON, "utf8").split("\n").filter(Boolean)); } catch { return new Set(); } })();
const drawnThreads = new Set();
const otherSide = (side) => (side === "old" ? "new" : "old");

/** A thread as a diff's preview draws one (git-mr-file-preview): a bar in its state's color, what it is, then each
 * comment, its author and its words, whole; lead is what goes before the bar, room the width after it. */
function drawThread(one, lead, room) {
  drawnThreads.add(one.id);
  const state = one.draft ? "draft" : one.resolved ? "resolved" : one.resolvable ? "open" : "comment";
  const color = state === "resolved" ? C : state === "draft" ? YOURS : E;
  const what = `thread\t${one.id}\t${Boolean(one.resolvable)}\t${Boolean(one.resolved)}\t${Boolean(one.draft)}`;
  const bar = `${lead}${color}▍${R} `;
  const author = one.notes[0].author?.username ?? "";
  const label = state === "resolved" ? "✓ resolved" : state === "draft" ? (author === "you" ? "✎ your draft" : `✎ ${author}'s draft`) : ` ${state}`;
  say(`${lead}${color}▍ ${label}${one.where.from < one.where.line ? ` · lines ${one.where.from}-${one.where.line}` : ""}${R}`, what);
  // Each comment's words, and for a draft of Claude's why it wrote it, as markdown.
  const told = markdown(one.notes.flatMap((note) => [[note.body, room], ...(note.why ? [[note.why, room - 2]] : [])]));
  one.notes.forEach((note, k) => {
    if (note.draft && state !== "draft") say(`${bar}${YOURS}↳ ✎ your draft reply${R}`, what);
    else if (state !== "draft") say(`${bar}${k ? `${C}↳ ` : ""}${A}${note.author?.username ?? ""}${R}`, what);
    for (const line of told.shift()) say(`${bar}${line}`, what);
    if (note.why) {
      say(`${bar}${C}┆ why · for you only, never posted${R}`, what);
      for (const line of told.shift()) say(`${bar}${C}┆ ${R}${line}`, what);
    }
  });
}
/** Comments' markdown drawn as the diff's preview draws them (share/markdown.awk), in one awk for all of them:
 * each [text, width] its lines. What someone typed has no controls of its own. */
function markdown(items) {
  const program = readFileSync(join(dirname(new URL(import.meta.url).pathname), "markdown.awk"), "utf8");
  const input = items.map(([text, room]) => `${Math.max(12, room)}\t${(text ?? "").replace(/\r/g, "").replace(/[\x00-\x08\x0b-\x1e\x7f]/g, "").replace(/\t/g, " ").replace(/\n/g, "\x1f")}\n`).join("");
  const drawn = execFileSync("awk", ["-F", "\t", `${program}\n{ print "\\001"; md(substr($0, index($0, "\\t") + 1), $1 + 0, "") }`],
    { input, encoding: "utf8", maxBuffer: 1 << 26, env: { ...env, LC_ALL: "C" }, stdio: ["pipe", "pipe", "ignore"] });
  return drawn.split("\x01\n").slice(1).map((one) => one.replace(/\n$/, "").split("\n"));
}
const ANSI = /\x1b\[[0-9;]*m/g;
const width = (text) => [...text.replace(ANSI, "")].length;
const pad = (text, to) => text + " ".repeat(Math.max(0, to - width(text)));
// A count as every screen shows one, a comma every three digits (share/rowfmt.awk's gk_num).
const num = (n) => n.toLocaleString("en-US");

/** Words wrapped to a width, whole: a word longer than the width is the only one cut. */
function wrap(text, room) {
  const lines = [];
  let line = "";
  for (let word of text.split(/\s+/).filter(Boolean)) {
    while ([...word].length > room) { if (line) { lines.push(line); line = ""; } lines.push([...word].slice(0, room).join("")); word = [...word].slice(room).join(""); }
    if (line && [...line].length + 1 + [...word].length > room) { lines.push(line); line = ""; }
    line = line ? line + " " + word : word;
  }
  if (line || !lines.length) lines.push(line);
  return lines;
}

/** A colored line cut into pieces a width wide, each piece starting in the colors the last one ended in. */
function cut(text, room) {
  const pieces = [];
  let piece = "", seen = 0, state = "";
  for (const token of text.split(/(\x1b\[[0-9;]*m)/)) {
    if (token.startsWith("\x1b[")) { piece += token; state = token === R ? "" : state + token; continue; }
    for (const ch of token) {
      if (seen === room) { pieces.push(piece + R); piece = state; seen = 0; }
      piece += ch; seen++;
    }
  }
  pieces.push(piece);
  return pieces;
}

/** What each changed line changed, as the diff's preview marks it (delta): in a run of changed lines, each removed
 * line is paired with the first added line after the last pair alike enough to be it edited, and the columns where
 * the two differ are lit. lines are [sign, text] (no colors), null where a run stops; the lit columns by line. */
function changedWords(lines) {
  const lit = lines.map(() => new Set());
  let run = [];
  for (const [at, line] of [...lines, null].entries()) {
    if (line && line[0] !== " ") { run.push(at); continue; }
    const words = (sign) => run.filter((k) => lines[k][0] === sign).map((k) => [k, lines[k][1].match(/[\w$]+|\s+|[^\w$\s]/gu) ?? []]);
    const gone = words("-"), came = words("+");
    run = [];
    let from = 0;
    for (const [k, x] of gone) for (let j = from; j < came.length; j++) {
      const differs = differ(x, came[j][1]);
      if (!differs) continue;
      [lit[k], lit[came[j][0]]] = differs;
      from = j + 1;
      break;
    }
  }
  return lit;
}
/** Where two lines' words differ: the columns of each one's words the other lacks; none when over 60% of them
 * differs (delta's cut), too unlike to read as one line edited. */
function differ(x, y) {
  // What they start and end with is the same; the words between are matched, in order, keeping the most text.
  let head = 0, tail = 0;
  while (head < x.length && head < y.length && x[head] === y[head]) head++;
  while (tail < x.length - head && tail < y.length - head && x.at(-1 - tail) === y.at(-1 - tail)) tail++;
  const n = x.length - head - tail, m = y.length - head - tail;
  const wide = (tokens) => tokens.reduce((sum, token) => sum + [...token].length, 0);
  const total = wide(x) + wide(y);
  // Too unlike to be one line edited even if every word between that both have were matched: no need to match.
  const left = new Map();
  for (const token of x.slice(head, head + n)) left.set(token, (left.get(token) ?? 0) + 1);
  let shared = 0;
  for (const token of y.slice(head, head + m)) if (left.get(token) > 0) { left.set(token, left.get(token) - 1); shared += 2 * [...token].length; }
  if (wide(x.slice(head, head + n)) + wide(y.slice(head, head + m)) - shared > 0.6 * total) return null;
  const common = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) common[i][j] = x[head + i] === y[head + j] ? common[i + 1][j + 1] + [...x[head + i]].length : Math.max(common[i + 1][j], common[i][j + 1]);
  const goneX = new Set(), goneY = new Set();
  for (let i = 0, j = 0; i < n || j < m;) {
    if (i < n && j < m && x[head + i] === y[head + j]) { i++; j++; }
    else if (j === m || (i < n && common[i + 1][j] >= common[i][j + 1])) goneX.add(head + i++);
    else goneY.add(head + j++);
  }
  // A space between two changed words is changed too, so a phrase rewritten is lit as one.
  let changed = 0;
  const columns = (tokens, gone) => {
    const lit = new Set();
    let at = 0;
    tokens.forEach((token, k) => {
      const size = [...token].length;
      if (gone.has(k)) changed += size;
      if (gone.has(k) || (/^\s/.test(token) && gone.has(k - 1) && gone.has(k + 1))) for (let c = at; c < at + size; c++) lit.add(c);
      at += size;
    });
    return lit;
  };
  const lit = [columns(x, goneX), columns(y, goneY)];
  return changed <= 0.6 * total ? lit : null;
}
/** A colored line on its ground, its lit columns on the word's ground; a reset in it goes back to whichever it is on. */
function grounded(text, lit, ground, word) {
  let out = "", at = 0, on = false;
  for (const token of text.split(/(\x1b\[[0-9;]*m)/)) {
    if (token.startsWith("\x1b[")) { out += token === R ? R + (on ? word : ground) : token; continue; }
    for (const ch of token) {
      if (lit.has(at++) !== on) { on = !on; out += on ? word : ground; }
      out += ch;
    }
  }
  return on ? out + ground : out;
}

const KIND = { fn: "function", method: "method", const: "constant", var: "variable", type: "type", interface: "type", enum: "enum", class: "class" };
/** What a box of code is, in words: a symbol by its kind and file, a file's other lines by what they are. */
function describe(row) {
  if (row.symbol) {
    const kind = KIND[row.kind] ?? row.kind;
    if (row.mark === "moved") return `moved ${kind}, ${row.where}`;
    return `${row.mark === "changed" && row.tag.includes("signature") ? "changed signature," : row.mark} ${kind} in ${row.where}`;
  }
  if (row.kind === "imports") return "its imports";
  if (row.kind === "outside any symbol") return "lines outside any symbol";
  if (row.kind === "whole file") return row.mark === "new" ? "new file" : row.mark === "removed" ? "removed file" : "the whole file";
  if (row.kind === "binary file") return `${row.mark} binary file`;
  return row.kind;
}

/** Words wrapped to a width, whole, each line in style on ground, with the code names in them drawn as code:
 * a name Claude put in backticks, or one no English word looks like (camelCase, snake_case). */
function prose(text, room, style = T, ground = "") { return wrapped(text, room, style, ground).map((one) => one.line); }

/** prose's lines, each with whether it goes on inside a word the line above cut (cut). */
function wrapped(text, room, style = T, ground = "") {
  const words = [];
  let word = [], code = 0, spans = 0;
  const end = () => { if (word.length) words.push(word); word = []; };
  for (const ch of text ?? "") {
    if (ch === "`") { code = code ? 0 : ++spans; continue; }
    if (/\s/.test(ch)) { end(); continue; }
    const last = word.at(-1);
    if (last && last.code === code) last.t += ch; else word.push({ t: ch, code });
  }
  end();
  const named = /^([^\w$]*)([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*(?:\(\))?)([^\w$]*)$/;
  const looks = (name) => /[a-z][A-Z]/.test(name) || /[A-Za-z]_[A-Za-z]/.test(name) || /\(\)$/.test(name);
  for (const one of words) {
    const at = one.findIndex((piece) => !piece.code && named.test(piece.t) && looks(named.exec(piece.t)[2]));
    if (at < 0) continue;
    const [, before, name, after] = named.exec(one[at].t);
    one.splice(at, 1, ...[{ t: before, code: 0 }, { t: name, code: -1 }, { t: after, code: 0 }].filter((piece) => piece.t));
  }
  // A word longer than the line is the only one cut: the lines its pieces after the first start go on inside it.
  const size = (one) => one.reduce((n, piece) => n + [...piece.t].length, 0);
  const chop = (one) => {
    const out = [];
    let piece = [], seen = 0;
    for (const { t, code: c } of one) for (const ch of t) {
      if (seen === room) { out.push(piece); piece = []; seen = 0; }
      const last = piece.at(-1);
      if (last && last.code === c) last.t += ch; else piece.push({ t: ch, code: c });
      seen++;
    }
    out.push(piece);
    return out;
  };
  const lines = [];
  let line = [], used = 0, cut = false;
  for (const [one, inside] of words.flatMap((w) => (size(w) > room ? chop(w).map((piece, k) => [piece, k > 0]) : [[w, false]]))) {
    if (line.length && used + 1 + size(one) > room) { lines.push({ words: line, cut }); line = []; used = 0; cut = inside; }
    used += (line.length ? 1 : 0) + size(one);
    line.push(one);
  }
  if (line.length || !lines.length) lines.push({ words: line, cut });
  const back = `${R}${ground}${style}`;
  const draw = (piece) => (piece.code ? `${RAISE}${T}${piece.t}${back}` : piece.t);
  return lines.map(({ words: one, cut }) => ({ cut, line: style + one.map((w, k) => {
    const joined = k && one[k - 1].at(-1).code > 0 && one[k - 1].at(-1).code === w[0].code;
    return (k ? (joined ? `${RAISE} ${back}` : " ") : "") + w.map(draw).join("");
  }).join("") + R }));
}

/** Lines of prose (wrapped) said as a paragraph, each after lead, the first after first (a label as wide), and each
 * in the map: the columns its words are in and how it goes on from the line above, so a copy takes the words
 * alone, as the one line they were. */
function paragraph(lines, lead, first = lead) {
  const from = width(lead) + 1;
  lines.forEach(({ line, cut }, at) => say(`${at ? lead : first}${line}`,
    `text\t${from}\t${from + [...line.replace(ANSI, "").trimEnd()].length - 1}\t${!at ? "new" : cut ? "cut" : "word"}`));
}

/** A band of the story: its label, and its words wrapped beside it on its ground. */
function band(label, labelColor, text, textStyle, ground = "") {
  const room = Math.min(W - 18, 92);
  paragraph(wrapped(text, room, textStyle, ground).map(({ line, cut }) => ({ cut, line: `${line}${ground}${" ".repeat(Math.max(0, room - width(line) + 1))}${R}` })),
    `  ${ground}${" ".repeat(13)}`, `  ${ground}${pad(` ${labelColor}${label}${R}${ground}`, 13)}`);
}

/** The design red flags on this case (flags.mjs), in red above the rest of it: what is wrong, what it costs the
 * next change, the smaller design, what to say to the author, and the two places it is. Each place's line is
 * numbered, to comment on as the route's are, with what to say typed in for you (the map's tenth field); the
 * threads on it are drawn under it. */
const NAMED = { shallow: "shallow module", leak: "information leakage", "special case": "special-general mixture", "two jobs": "two jobs complected",
  exposure: "overexposure", defensive: "defensive code", "wrong layer": "fix in the wrong layer", bespoke: "bespoke abstraction", "unlike its neighbours": "unlike its neighbours" };
const flags = (() => { try { return JSON.parse(readFileSync(file.replace(/\.json$/, ".flags.json"), "utf8")).flags.filter((one) => one.case === told); } catch { return []; } })();
// Each flag's two places by where they are, with what it found there: a red note beside the line in the route.
const flaggedAt = new Map(flags.flatMap((flag) => [flag.line, flag.caller].filter((ref) => ref.note).map((ref) => [`${ref.path}\t${ref.side}\t${ref.line}`, ref.note])));
function showFlags() {
  const changed = new Set((outline.routes ?? []).flatMap((one) => one.stops.filter((stop) => stop.inChange).map((stop) => stop.path)));
  const room = Math.min(W - 18, 92), from = 16;
  flags.forEach((flag, k) => {
    say(`  ${X}${B}⚑ ${(NAMED[flag.flag] ?? flag.flag).toUpperCase()}${R}`);
    paragraph(wrapped(flag.claim, Math.min(W - 4, 100)), "  ");
    band("next change", X, flag.cost, T);
    band("smaller", G, flag.smaller, T);
    if (flag.comment) band("say", YOURS, flag.comment, T);
    const words = flag.comment ? `\t${flag.comment.replace(/[\t\n]/g, " ")}` : "";
    for (const [label, ref] of [["here", flag.line], ["and", flag.caller]]) {
      say(`  ${pad(` ${C}${label}${R}`, 13)}${C}${ref.path}${R}`);
      const what = `line\t${ref.path}\t${ref.side}\t${ref.line}\t${ref.line}\t${changed.has(ref.path) ? 1 : 0}\t${from}\t${from + room - 1}\tflag${k}${label}${words}`;
      wrap(ref.code.trim(), room).forEach((line, at) => say(`  ${at ? " ".repeat(13) : `${C}${String(ref.line).padStart(11)}${R}  `}${RAISE}${T}${line}${R}`, what));
      for (const one of threadsAt.get(`${ref.path}\t${ref.side}\t${ref.line}`) ?? []) if (!drawnThreads.has(one.id)) drawThread(one, `  ${" ".repeat(13)}`, room);
    }
    say();
  });
}

/** How a situation ended before → how it ends now, as the list says it, room wide: yellow when it ends differently. */
function ending(one, room) {
  if (!one.was && !one.now) return [];
  const was = one.fresh ? "new" : one.was || "?", now = one.now || "?", tone = one.change === "ends differently" ? A : C;
  const how = { "only a label": "  · only a label", "the same": "  = the same" }[one.change] ?? "";
  if (width(was) + width(now) + width(how) + 3 <= room) return [`${C}${was}${R} → ${tone}${now}${R}${C}${how}${R}`];
  return [...wrap(was, room).map((line) => C + line + R), ...wrap(now, room - 2).map((line, at) => `${at ? "  " : "→ "}${tone}${line}${R}`),
    ...(how ? [`  ${C}${how.trim()}${R}`] : [])];
}

/** A case: what comes in and how it ended before and ends now, then the route it runs through the code, with what
 * holds on each line it passes, the lines it never runs dim, and the tests that run it. */
function showCase() {
  const head = [...prose(part.input || part.text, W - 4, B + T), ...ending(part, W - 4)].map((line) => `  ${line}`);
  if (env.OTIS_PANE_MAP) pinned.push(...head, `  ${C}${"─".repeat(W - 4)}${R}`);
  say();
  if (!env.OTIS_PANE_MAP) for (const line of head) say(line);
  if (part.input) for (const line of prose(part.text, W - 4, C)) say(`  ${line}`);
  if (part.setup) paragraph(wrapped(part.setup, W - 4), "  ");
  const pins = [...new Set(part.facts.filter((fact) => fact.pinned).map((fact) => fact.pinned.where))];
  if (pins.length) for (const line of prose(`✓ ${pins.join(", ")}`, W - 4, C)) say(`  ${line.replace("✓", `${G}✓${R}${C}`)}`);
  say();
  if (rewording) { paragraph(wrapped("Claude is telling this case again in your words", W - 4, A), "  "); say(); }
  showFlags();
  band("the author", C, part.quote ? `“${part.quote}”` : "never mentions this", C + I);

  // The route: who calls whom as the case runs. A stop under another is called from the line just above it,
  // which is drawn in the caller's code; a rail on the left runs down what is inside each function. A function
  // the case never comes to is its name alone, so every case that comes in this way finds the code where it was.
  say();
  const peers = outline.sentences.filter((one) => one.route === part.route).length;
  for (const line of prose(`ROUTE: ${route.text} (case ${part.letter} of ${peers})`, W - 4, C)) say(`  ${line}`);
  const marks = new Set(stops.map((stop) => stop.mark));
  const legend = [["◆", A, "changed here"], ["●", T, "in changed code"], ["○", C, "not in this change"]].filter(([mark]) => marks.has(mark))
    .map(([mark, color, says]) => `${color}${mark}${R}${C} ${says}${R}`).join("  ");
  const title = `${C}WHO CALLS WHOM, as it runs${R}`;
  if (width(title) + width(legend) + 6 <= W - 2) say(`  ${pad(title, W - 4 - width(legend))}${legend}`);
  else { say(`  ${title}`); say(`  ${legend}`); }
  const kids = stops.map(() => []), roots = [];
  stops.forEach((stop, i) => (stop.parent >= 0 ? kids[stop.parent] : roots).push(i));
  // Where the case goes, and the lines it passes over there, as sentences.mjs read them from Claude's.
  const goes = (i) => stops[i].by.includes(part.letter);
  const numbers = stops.flatMap((stop) => stop.code.map((line) => line.n ?? 0));
  const digits = Math.max(3, ...numbers.map((n) => String(n).length));
  const gutter = digits + 3;
  const rail = (depth) => `${C}${"│ ".repeat(depth)}${R}`;
  const depthOf = [];
  const deepen = (i, depth) => { depthOf[i] = depth; for (const k of kids[i]) deepen(k, depth + 1); };
  roots.forEach((i) => deepen(i, 0));
  // Each stop's code without the indentation its lines share, all of it in one panel whose right edge is one
  // column for the whole route. What holds on a line Claude cites is its reading, in words beside the panel,
  // always on the right: wrapped there when long, the code wrapping at the panel's edge to leave it the room.
  const texts = (i) => stops[i].code.filter((line) => line.t?.trim()).map((line) => line.t.replace(/\t/g, "    "));
  const shared = stops.map((_, i) => Math.min(...texts(i).map(indent)));
  const spans = stops.flatMap((_, i) => texts(i).map((t) => ({ code: [...t].length - shared[i], at: 2 * (depthOf[i] + 1) + gutter + [...t].length - shared[i] })));
  const longest = Math.max(0, ...spans.map((one) => one.at));
  // The room on the right is for the longest note on the route, any case's, or a line's call to the stop below: the
  // same for every case on it, so moving from one to the next leaves the code where it was.
  const noted = Math.max(0, ...stops.flatMap((stop) => stop.code.filter((line) => line.cited).flatMap((line) => line.notes.map((note) => [...note.value].length + 2))),
    ...stops.flatMap((stop) => stop.code.map((line) => flaggedAt.get(`${stop.path}\t${line.mine === false ? otherSide(stop.side) : stop.side}\t${line.n}`)).filter(Boolean).map((note) => [...note].length + 2)),
    ...stops.filter((stop) => stop.call).map((stop) => [...`${stop.call.verb ?? "uses"} ${stop.name}, below`].length + 2));
  // The code first: the notes wrap, in at most a third of the pane, so the code has the rest to breathe in.
  const room = noted ? Math.max(24, Math.min(noted, 48, Math.floor(W * 0.3))) + 3 : 0;
  const edge = Math.min(W - 4 - room, longest + 1), aside = W - 4 - edge - 3;

  // Each function a step, numbered in the order the route reaches it.
  let step = 0;
  function drawStop(i, depth) {
    const stop = stops[i];
    const markColor = stop.mark === "◆" ? A : stop.mark === "●" ? T : C;
    const room = W - 4 - 2 * depth;
    if (!goes(i)) {
      for (const line of prose(`${++step} ${stop.mark} ${stop.name} in ${stop.where}: case ${part.letter} never comes here`, room, C)) say(`  ${rail(depth)}${line}`);
      return;
    }
    const head = `${C}${++step}${R} ${markColor}${stop.mark}${R} ${RAISE}${B}${T}${stop.name}${R}`;
    const place = `${C}in ${stop.where}${stop.inside ? `, inside ${RAISE}${T}${stop.inside}${R}${C}` : ""}${stop.inChange ? "" : ", not in this change"}${stop.side === "old" ? ", before the change" : ""}${R}`;
    if (width(head) + width(place) + 2 <= room) say(`  ${rail(depth)}${head}  ${place}`);
    else { say(`  ${rail(depth)}${head}`); say(`  ${rail(depth + 1)}${place}`); }
    // What it is for, without the name it opens with when Claude starts there: the line above says it.
    const is = (stop.is ?? "").replace(new RegExp(`^\`?${stop.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\`?\\s+`), "");
    if (is) paragraph(wrapped(is, room - 2), `  ${rail(depth + 1)}`);
    // Its code, every line in its file's colors on the diff's ground: the lines Claude cites on a stronger ground,
    // with what holds there beside them in yellow, and what a changed line changed on the strongest. A stop it
    // calls is drawn under the line that calls it.
    const lead = rail(depth + 1), code = edge - 2 * (depth + 1) - gutter;
    const calledAt = new Map();
    for (const k of kids[i]) calledAt.set(stops[k].call.n, [...(calledAt.get(stops[k].call.n) ?? []), k]);
    const drawn = new Set();
    // A note's lines beside the row it is on and the rows after it; on rows of their own when another note, a
    // stop it calls or the end of the stop comes first.
    let pending = [];
    const flush = () => { for (const one of pending) say(`  ${lead}${" ".repeat(gutter + code)}${one}`); pending = []; };
    const bodies = stop.code.map((line) => (line.gap ? "" : dent((line.paint ?? T + line.t).replace(/\t/g, "    "), shared[i])));
    const words = changedWords(stop.code.map((line, at) => (line.gap ? null : [line.sign, bodies[at].replace(ANSI, "")])));
    const draw = (line, at) => {
      const calls = line.mine ? calledAt.get(line.n) ?? [] : [];
      // Where the line is, for a comment on it: a line the change removed is on the side the stop is not.
      const side = line.mine === false ? otherSide(stop.side) : stop.side, from = 3 + 2 * (depth + 1) + gutter;
      // What a design red flag on this case found here: lit as a cited line is, its number and its note red.
      const wrong = (line.joined ?? [line.n]).map((n) => flaggedAt.get(`${stop.path}\t${side}\t${n}`)).find(Boolean);
      // What holds here for this case, lit; a line it never runs, dim, as a debugger greys what it steps over.
      const notes = line.cited ? line.notes.filter(mine) : [], dim = Boolean(line.off?.includes(part.letter));
      const lit = notes.length || wrong;
      const ground = lit ? (line.sign === "+" ? PLUS_EMPH : line.sign === "-" ? MINUS_EMPH : LIFT) : line.sign === "+" ? PLUS : line.sign === "-" ? MINUS : RAISE;
      const mark = line.sign === "+" ? `${G}+` : line.sign === "-" ? `${X}−` : " ";
      const body = dim ? `${ground}${C}${bodies[at].replace(ANSI, "")}` : grounded(bodies[at], words[at], ground, line.sign === "+" ? PLUS_WORD : MINUS_WORD);
      // A line the change removed is numbered in red: its number is from before the change.
      const number = `${wrong ? B + X : notes.length ? B + A : line.mine === false ? X : C}${String(line.n).padStart(digits)}${R}${ground} ${mark}${R}${ground} `;
      // Its notes, one under another, the first marked; else the call to the stop below.
      const call = !notes.length && calls.length ? `${stops[calls[0]].call.verb ?? "uses"} ${calls.map((k) => `\`${stops[k].name}\``).join(" and ")}, below` : "";
      if (notes.length) {
        flush();
        pending = notes.flatMap((note, j) => prose(note.value, Math.max(8, aside - 2), B + A).map((one, k) => `   ${j || k ? " " : `${A}◀${R}`} ${one}`));
      } else if (call) { flush(); pending = prose(call, Math.max(8, aside - 2), C).map((one) => `     ${one}`); }
      if (wrong) { if (!notes.length && !call) flush(); pending.push(...prose(wrong, Math.max(8, aside - 2), B + X).map((one, k) => `   ${k ? " " : `${X}⚑${R}`} ${one}`)); }
      const what = `line\t${stop.path}\t${side}\t${line.n}\t${line.to ?? line.n}\t${stop.inChange ? 1 : 0}\t${from}\t${from + code - 1}\t${i}`;
      cut(body, code).forEach((piece, k) => {
        say(`  ${lead}${ground}${k ? " ".repeat(gutter) : number}${ground}${pad(piece, code)}${R}${pending.shift() ?? ""}`, what);
      });
      // The review's threads on it, under it.
      const here = (line.joined ?? [line.n]).flatMap((n) => threadsAt.get(`${stop.path}\t${side}\t${n}`) ?? []).filter((one) => !drawnThreads.has(one.id));
      if (here.length) { flush(); for (const one of here) drawThread(one, `  ${lead}${" ".repeat(gutter)}`, W - from - 3); }
      return calls;
    };
    // The stops a line calls go under it, and under what it took the place of, which is read with it.
    let waiting = [];
    const descend = (more) => {
      if (!waiting.length) return;
      flush();
      for (const k of waiting) { drawStop(k, depth + 1); drawn.add(k); }
      waiting = [];
      if (more) say(`  ${lead}${prose(`↩ back in \`${stop.name}\``, code, C)[0]}`);
    };
    stop.code.forEach((line, at) => {
      if (line.mine !== false) descend(true);
      if (line.gap) {
        const lines = `${num(line.gap)} line${line.gap === 1 ? "" : "s"}`;
        // A gap with a sign is the other side's lines in a run: the note beside the line above goes on beside it.
        if (line.sign) say(`  ${lead}${pad(`${" ".repeat(digits + 1)}${line.sign === "-" ? `${RM}− ${lines} removed` : `${G}+ ${lines} added`}${R}`, gutter + code)}${pending.shift() ?? ""}`);
        else { flush(); say(`  ${lead}${" ".repeat(digits - 1)}${C}⋯ ${lines}${R}`); }
      }
      else waiting.push(...draw(line, at));
    });
    descend(false);
    flush();
    for (const k of kids[i]) if (!drawn.has(k)) drawStop(k, depth + 1);
  }
  roots.forEach((i, at) => {
    if (at) say();
    // How the case gets to a function nothing above calls: what in the code calls it, as otis found it.
    const from = stops[i].from;
    if (at) {
      const how = from ? `↓ ${from.fn ? `\`${from.fn}\`` : "code outside any function"} in ${from.where}:${from.n} ${from.verb} it` : "↓ next";
      paragraph(wrapped(how, W - 4, C), "  ");
    }
    drawStop(i, 0);
  });
  if (!stops.length) say(`  ${A}no line Claude cited could be found in the code, so there is no route to show${R}`);
  elsewhere();
  // Where in the system this happens, for a reader who has never seen this code.
  if (route.where) {
    say();
    say(`  ${C}WHERE THIS RUNS${R}`);
    paragraph(wrapped(route.where, Math.min(W - 4, 100)), "  ");
  }

  // The tests in the change that run it, by file.
  say();
  if (!part.runs.length) band("tested by", C, "no test in this change runs it", C + I);
  const files = [...new Set(part.runs.map((run) => run.where))];
  for (const [at, path] of files.entries()) {
    band(at ? "" : "tested by", C, path, C);
    for (const run of part.runs.filter((one) => one.where === path)) wrap(run.name, Math.min(W - 20, 90)).forEach((line, i) => say(`  ${" ".repeat(13)}${T}${i ? "  " : "◦ "}${line}${R}`));
  }
  if (part.data?.length) band("runs on", C, part.data.map((path) => path.split("/").at(-1)).join(", "), C);
  say();
}

/** The review's threads on the part's code that no line above shows: each under its own line, by file. */
function elsewhere() {
  const rest = threads.filter((one) => onCase.has(one.id) && !drawnThreads.has(one.id))
    .sort((a, b) => a.where.path.localeCompare(b.where.path) || a.where.line - b.where.line);
  if (!rest.length) return;
  // The outline is named for the change's two commits: an old side's line is read at the first, a new one's at the second.
  const [base, head] = basename(file, ".json").split("-");
  const texts = new Map();
  const textOf = (side, path) => {
    const at = `${side === "old" ? base : head}:${path}`;
    if (!texts.has(at)) {
      try { texts.set(at, execFileSync("git", ["show", at], { encoding: "utf8", maxBuffer: 1 << 26, stdio: ["ignore", "pipe", "ignore"] }).split("\n")); }
      catch { texts.set(at, []); }
    }
    return texts.get(at);
  };
  const digits = Math.max(3, ...rest.map((one) => String(one.where.line).length));
  const gutter = digits + 3, from = 3 + gutter, code = W - 4 - gutter;
  say();
  say(`  ${C}THREADS ON LINES THE ROUTE DOES NOT SHOW${R}`);
  let was = "";
  for (const one of rest) {
    const { path, side, line } = one.where;
    if (path !== was) { say(); say(`  ${E}${path}${R}`); was = path; }
    const ground = side === "old" ? MINUS : RAISE;
    const number = `${side === "old" ? X : C}${String(line).padStart(digits)}${R}${ground} ${side === "old" ? `${X}−` : " "}${R}${ground} `;
    const text = (textOf(side, path)[line - 1] ?? "").replace(/\t/g, "    ").replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
    cut(`${T}${text}`, code).forEach((piece, at) => say(`  ${ground}${at ? " ".repeat(gutter) : number}${ground}${pad(piece, code)}${R}`,
      `line\t${path}\t${side}\t${line}\t${line}\t1\t${from}\t${from + code - 1}\tt${one.id}`));
    drawThread(one, `  ${" ".repeat(gutter)}`, W - from - 3);
  }
}

/** Your words (otis-words): state, word, the thing it names, where that lives and your note, a row each. */
function yourWords() {
  try {
    return readFileSync(process.env.OTIS_WORDS || `${process.env.XDG_CONFIG_HOME || `${homedir()}/.config`}/otis/words.tsv`, "utf8")
      .split("\n").filter(Boolean).map((line) => line.split("\t"));
  } catch { return []; }
}
/** What the case says, in all its words, without the backticks around names. */
const saidOf = () => [part.text, part.input, part.setup, part.was, part.now, route?.where,
  ...stops.flatMap((stop) => [stop.is, ...notesOf(stop).map((note) => note.value)])].join(" ").replace(/`/g, "");
const escapeRe = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
/** Whether the case uses a word, as a whole word. */
function uses(word) { return new RegExp(`\\b${escapeRe(word)}\\b`, "i").test(saidOf()); }

/** Your words (otis-words), marked once, hold in every case: a case that uses a word you have marked, and was not
 * told with that mark, is told again for you behind the pane (reword.mjs), two at a time. */
function retell() {
  if (rewording || !stops.length) return;
  const told = `${overlaid ? reworded.reader : ""} ${outline.reader ?? ""}`.toLowerCase();
  // Each thing as the words give it to Claude: the word and what it names, or the word wherever it comes up.
  const stale = yourWords().some(([, word, thing]) => word && uses(word) && !told.includes(`"${word}" ${thing ? `naming ${thing}` : "wherever"}`.toLowerCase()));
  if (!stale) return;
  const busy = readdirSync(dirname(file)).filter((name) => name.endsWith(".running") && name.includes(".reader.")).length;
  if (busy >= 2) return;
  spawn("node", [join(dirname(new URL(import.meta.url).pathname), "reword.mjs"), file, which], { detached: true, stdio: "ignore" }).unref();
}

/** A colored line without its first n columns of indentation. */
function dent(text, n) {
  let out = "", dropped = 0;
  for (const token of text.split(/(\x1b\[[0-9;]*m)/)) {
    if (token.startsWith("\x1b[")) { out += token; continue; }
    let k = 0;
    while (dropped < n && k < token.length && token[k] === " ") { k++; dropped++; }
    if (k < token.length) dropped = n;
    out += token.slice(k);
  }
  return out;
}
function indent(text) { let n = 0; for (const ch of text) { if (ch === " ") n++; else break; } return n; }

/** A part of a story told without cases (one a commit, or what no case runs): its words, then its code. */
function showPart() {
// The part: its title, and the story beside nothing else.
say();
for (const line of wrap(part.text, W - 4)) say(`  ${B}${T}${line}${R}`);
say();
if (part.kind === "story" && part.before) {
  band("before", X, part.before, T, MINUS);
  band("after", G, part.after, T, PLUS);
}
if (part.kind === "support" && part.after) band("why", C, part.after, T);
if (part.kind === "story" && outline.filedBy) {
  if (part.quote) band("the author", C, `“${part.quote}”`, C + I);
  else band("the author", C, "said nothing about this", A);
}
if (part.kind === "story" && !outline.filedBy && part.origin) band("commit", C, part.origin, C);

// The code: each symbol a box, its lines numbered and colored as their file colors them.
const isTestImports = (row) => row.kind === "imports" || /import changes$/.test(row.name);
const boxes = [...part.code, ...part.tests.filter((row) => !row.block && !isTestImports(row))];
const digits = Math.max(3, ...boxes.flatMap((row) => row.nums.map((n) => String(n).length)));
for (const row of boxes) {
  say();
  const name = row.cases && row.name.includes("%s") ? row.name.split("%s").join(row.cases) : row.name;
  const size = `${row.add ? `${G}+${num(row.add)}${R}${RAISE}` : ""}${row.add && row.del ? " " : ""}${row.del ? `${RM}−${num(row.del)}${R}${RAISE}` : ""}`;
  const head = `${B}${T}${name}${R}${RAISE}  ${C}${describe(row)}${R}${RAISE}`;
  const room = W - 4;
  if (width(head) + width(size) + 3 <= room) say(`  ${RAISE} ${pad(head, room - width(size) - 2)}${size} ${R}`);
  else {
    for (const line of wrap(name, room - 2)) say(`  ${RAISE} ${pad(B + T + line + R + RAISE, room - 1)}${R}`);
    const words = wrap(describe(row), room - width(size) - 4);
    words.forEach((line, at) => say(`  ${RAISE} ${pad(C + line + R + RAISE, room - width(size) - 2)}${at === words.length - 1 ? size : " ".repeat(width(size))} ${R}`));
  }
  // A line's note on the right of the code, wrapped there, the code wrapping at its edge to leave it the room;
  // what is left of a note goes beside the lines after it.
  const longestNote = Math.max(0, ...(row.notes ?? []).filter(Boolean).map((note) => [...note].length + 2));
  const aside = longestNote ? Math.max(24, Math.min(longestNote, 48)) : 0;
  const gutter = digits + 3, code = W - 3 - gutter - (aside ? aside + 3 : 0);
  let pending = [];
  const flush = () => { for (const one of pending) say(`  ${" ".repeat(gutter + code)}${one}`); pending = []; };
  const texts = row.lines.map((raw, at) => (row.paint?.[at] ?? T + raw.slice(1)).replace(/\t/g, "    "));
  const words = changedWords(row.lines.map((raw, at) => (/^[-+ ]/.test(raw) ? [raw[0], texts[at].replace(ANSI, "")] : null)));
  row.lines.forEach((raw, at) => {
    const sign = raw[0];
    if (sign === "#") { flush(); say(); say(`  ${T}${raw.slice(1).trim()}${R}`); return; }
    if (sign === "~") { flush(); say(`  ${" ".repeat(gutter)}${C}⋯${raw.length > 1 ? "  " + raw.slice(1) : ""}${R}`); return; }
    const ground = sign === "+" ? PLUS : sign === "-" ? MINUS : "";
    const mark = sign === "+" ? `${G}+` : sign === "-" ? `${X}−` : " ";
    const text = grounded(texts[at], words[at], ground, sign === "+" ? PLUS_WORD : MINUS_WORD);
    const note = row.notes?.[at];
    if (note) { flush(); pending = wrap(note, aside - 2).map((one, k) => `   ${E}${k ? " " : "◀"} ${one}${R}`); }
    cut(text, code).forEach((piece, i) => {
      const lead = i ? " ".repeat(gutter) : `${C}${String(row.nums[at] || "").padStart(digits)} ${mark}${R}${ground} `;
      say(`  ${ground}${lead}${ground}${pad(piece, code)}${R}${pending.shift() ?? ""}`);
    });
  });
  flush();
}
if (part.links.length) {
  say();
  for (const link of part.links) for (const [at, line] of wrap(link, W - 6).entries()) say(`  ${C}${at ? "  " : "→ "}${line}${R}`);
}

// What tests it: their names, by file. The setup they share and their imports are counted, not shown.
const tests = part.tests.filter((row) => row.block && row.kind === "test");
const setup = part.tests.filter((row) => row.block && row.kind !== "test");
if (tests.length || (part.kind === "story" && outline.filedBy && boxes.length)) {
  say();
  if (!tests.length) band("tested by", C, "no test in this change", A);
  const where = [...new Set(tests.map((row) => row.where))];
  for (const [at, path] of where.entries()) {
    band(at ? "" : "tested by", C, path, C);
    for (const row of tests.filter((one) => one.where === path)) {
      const name = row.cases && row.name.includes("%s") ? row.name.split("%s").join(row.cases) : row.name;
      wrap(name, Math.min(W - 20, 90)).forEach((line, i) => say(`  ${" ".repeat(13)}${T}${i ? "  " : "◦ "}${line}${R}`));
    }
  }
  const extra = [...setup, ...part.tests.filter(isTestImports)];
  if (tests.length && extra.length) {
    const lines = extra.reduce((sum, row) => sum + row.add + row.del, 0);
    say(`  ${" ".repeat(13)}${C}and ${extra.length === 1 && setup.length ? "the setup they share" : "their setup and imports"}, ${lines} line${lines === 1 ? "" : "s"}${R}`);
  }
}
elsewhere();
say();
}

if (part.kind === "case" || part.kind === "also") { showCase(); retell(); } else showPart();
if (pinned.length) out.unshift(`\x1epin ${pinned.length}`, ...pinned);
if (env.OTIS_PANE_MAP && map.length) out.unshift(`\x1emap ${map.length}`, ...map);
process.stdout.write(out.join("\n") + "\n");
