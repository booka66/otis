#!/usr/bin/env node
// story-pane.mjs <outline.json> <n>: case n of a change (sentences.mjs) as the symbol view's pane,
// FZF_PREVIEW_COLUMNS wide: the situation, how it ended before and how it ends now, its route through the
// code in the order it runs, the tests that run it. A part told without cases is its words and its code.
import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const [file, which] = process.argv.slice(2);
const outline = JSON.parse(readFileSync(file, "utf8"));
const part = outline.sentences[Number(which) - 1];
if (!part) process.exit(0);
const W = Math.max(40, Number(process.env.FZF_PREVIEW_COLUMNS) || 96);
// The case told again for you (reword.mjs, from your words), laid over the case it was told from.
const reworded = (() => { try { return JSON.parse(readFileSync(file.replace(/\.json$/, `.reader.${which}.json`), "utf8")); } catch { return null; } })();
const rewording = existsSync(file.replace(/\.json$/, `.reader.${which}.running`));
const overlaid = reworded?.of === part.text;
if (overlaid) {
  for (const key of ["text", "setup", "where", "ends", "stopped"]) if (part[key] || reworded[key]) part[key] = reworded[key];
  reworded.facts.forEach((fact, k) => Object.assign(part.facts[k], fact));
  reworded.stops.forEach((stop, i) => {
    const one = part.stops[i];
    if (stop.is || one.is) one.is = stop.is;
    const value = new Map(one.lines.map((line, j) => [line.n, stop.values[j]]));
    for (const line of [...one.lines, ...(one.code ?? [])]) if (value.has(line.n) && (line.cited || one.lines.includes(line))) line.value = value.get(line.n);
  });
}

const env = process.env;
const fg = (name, fallback) => `\x1b[${env[name] || fallback}m`;
const bgOf = (hex, fallback) => (/^#[0-9a-f]{6}$/i.test(hex || "") ? `\x1b[48;2;${parseInt(hex.slice(1, 3), 16)};${parseInt(hex.slice(3, 5), 16)};${parseInt(hex.slice(5, 7), 16)}m` : fallback);
const R = "\x1b[0m", B = "\x1b[1m", I = "\x1b[3m";
const T = fg("OTIS_T_TEXT", "39"), C = fg("OTIS_T_CONTEXT", "90"), A = fg("OTIS_T_ATTENTION", "33");
const G = fg("OTIS_T_GOOD", "32"), X = fg("OTIS_T_BAD", "31"), E = fg("OTIS_T_ELSEWHERE", "34");
const PLUS = bgOf(env.OTIS_T_PLUS, "\x1b[48;5;22m"), MINUS = bgOf(env.OTIS_T_MINUS, "\x1b[48;5;52m");
const RAISE = env.OTIS_T_CODEBG ? `\x1b[${env.OTIS_T_CODEBG}m` : "\x1b[48;5;237m";
// A line Claude cites stands out on a stronger ground: the diff's emphasis, or the code's ground lifted.
const PLUS_EMPH = bgOf(env.OTIS_T_PLUS_EMPH, "\x1b[48;5;28m"), MINUS_EMPH = bgOf(env.OTIS_T_MINUS_EMPH, "\x1b[48;5;88m");
const LIFT = ((rgb) => (rgb ? `\x1b[48;2;${rgb.slice(1).map((c) => Math.max(0, Math.min(255, Number(c) + (env.OTIS_T_LIGHT ? -24 : 24)))).join(";")}m` : "\x1b[48;5;239m"))(/48;2;(\d+);(\d+);(\d+)/.exec(RAISE));

const out = [];
const say = (line = "") => out.push(line);
const ANSI = /\x1b\[[0-9;]*m/g;
const width = (text) => [...text.replace(ANSI, "")].length;
const pad = (text, to) => text + " ".repeat(Math.max(0, to - width(text)));

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
function prose(text, room, style = T, ground = "") {
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
  // A word longer than the line is the only one cut.
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
  let line = [], used = 0;
  for (const one of words.flatMap((w) => (size(w) > room ? chop(w) : [w]))) {
    if (line.length && used + 1 + size(one) > room) { lines.push(line); line = []; used = 0; }
    used += (line.length ? 1 : 0) + size(one);
    line.push(one);
  }
  if (line.length || !lines.length) lines.push(line);
  const back = `${R}${ground}${style}`;
  const draw = (piece) => (piece.code ? `${RAISE}${T}${piece.t}${back}` : piece.t);
  return lines.map((one) => style + one.map((w, k) => {
    const joined = k && one[k - 1].at(-1).code > 0 && one[k - 1].at(-1).code === w[0].code;
    return (k ? (joined ? `${RAISE} ${back}` : " ") : "") + w.map(draw).join("");
  }).join("") + R);
}

/** A band of the story: its label, and its words wrapped beside it on its ground. */
function band(label, labelColor, text, textStyle, ground = "") {
  const room = Math.min(W - 18, 92);
  prose(text, room, textStyle, ground).forEach((line, at) => {
    say(`  ${ground}${pad(` ${at ? "" : labelColor + label + R + ground}`, 13)}${line}${ground}${" ".repeat(Math.max(0, room - width(line) + 1))}${R}`);
  });
}

/** A case: the situation, how it ended before and how it ends now, then its route through the code in the
 * order it runs, each stop's deciding lines with what holds there, and the tests that run it. */
function showCase() {
  say();
  for (const line of prose(part.text, W - 4, B + T)) say(`  ${line}`);
  if (part.setup) for (const line of prose(part.setup, W - 4)) say(`  ${line}`);
  say();
  if (rewording) { for (const line of prose("Claude is telling this case again in your words", W - 4, A)) say(`  ${line}`); say(); }
  // The words you are learning or have noted (otis-words) that the case uses, each with what it is here, so
  // the meaning is in front of you however the case tells it.
  const meant = yourWords().filter(([state, word, meaning]) => (state === "learning" || state === "noted") && meaning && uses(word));
  if (meant.length) {
    say(`  ${C}WORDS${R}`);
    const label = Math.min(24, Math.max(...meant.map(([, word]) => [...word].length)));
    for (const [state, word, meaning] of meant) {
      prose(meaning, Math.min(W - 6 - label, 96), T).forEach((line, at) => say(`  ${at ? " ".repeat(label) : `${B}${A}${word}${R}${" ".repeat(Math.max(0, label - [...word].length))}`}  ${line}`));
      if (state === "noted") say(`  ${" ".repeat(label)}  ${C}your words${R}`);
    }
    say();
  }
  // Where in the system this happens, for a reader who has never seen this code.
  // Said in full by the first case it holds for; the rest give its first sentence and say where the rest is.
  if (part.where) {
    say(`  ${C}WHERE THIS RUNS${R}`);
    const first = part.where.match(/^.+?[.!?](?=\s|$)/)?.[0] ?? part.where;
    if (!part.whereAt || part.whereAt === part.num || first === part.where) for (const line of prose(part.where, Math.min(W - 4, 100))) say(`  ${line}`);
    else for (const line of prose(`${first} The rest of it is on case ${part.whereAt}.`, Math.min(W - 4, 100))) say(`  ${line}`);
    say();
  }

  // How it ends, in sentences; then before and after, side by side, the questions worth comparing. New code
  // has no before: none of it ran.
  if (part.ends) {
    say(`  ${C}HOW IT ENDS${R}`);
    for (const line of prose(part.ends, Math.min(W - 4, 100))) say(`  ${line}`);
    say();
  }
  const facts = part.facts;
  if (facts.length) {
    const whatW = Math.min(Math.max(18, Math.floor(W / 4)), 36, Math.max(...facts.map((fact) => [...fact.what.replace(/`/g, "")].length)));
    // An answer a test asserts says which test line, where the pane has room for it, else only that one does.
    const pins = facts.filter((fact) => fact.pinned).map((fact) => fact.pinned.where.length);
    const pinW = !pins.length ? 0 : W - 4 - whatW - 2 - 3 - Math.max(...pins) - 3 >= 40 ? Math.max(...pins) + 3 : 2;
    const row = (fact, cells) => {
      const what = prose(fact.what, whatW, C);
      const tall = Math.max(what.length, ...cells.map((cell) => cell.lines.length));
      for (let i = 0; i < tall; i++) {
        const pin = i === 0 && fact.pinned ? `${G}✓${R}${pinW > 2 ? ` ${C}${fact.pinned.where}${R}` : ""}` : "";
        say(`  ${pad(what[i] ?? "", whatW)}  ${cells.map(({ lines, w, ground }) => `${ground} ${lines[i] ?? ""}${ground}${" ".repeat(Math.max(0, w - width(lines[i] ?? "")))} ${R}`).join(" ")} ${pin}`);
      }
    };
    if (part.fresh) {
      const nowW = Math.min(W - 4 - whatW - 2 - 4 - pinW, 90);
      for (const [at, line] of prose("new code: the route starts in code this change adds, so there is no before", nowW - 4, C).entries()) say(`  ${" ".repeat(whatW + 2)}${at ? "     " : `${G} now${R} `}${line}`);
      for (const fact of facts) row(fact, [{ lines: prose(fact.after || "·", nowW - 2, T, PLUS), w: nowW - 2, ground: PLUS }]);
    } else {
      const room = W - 4 - whatW - 2 - 3 - pinW;
      const beforeW = Math.max(12, Math.floor(room * 0.45)), afterW = Math.max(12, room - beforeW - 2);
      say(`  ${" ".repeat(whatW + 2)}${X} before${R}${" ".repeat(Math.max(1, beforeW - 6))}${G} after${R}`);
      for (const fact of facts) {
        row(fact, [
          { lines: prose(fact.before || "·", beforeW - 2, T, MINUS), w: beforeW - 2, ground: MINUS },
          { lines: prose(fact.after || "·", afterW - 3, T, PLUS), w: afterW - 3, ground: PLUS },
        ]);
      }
    }
    const key = pins.length ? `✓ the test line that asserts it${pins.length < facts.length ? "; the rest is Claude's reading of the code" : ""}`
      : part.runs.length ? "Claude's reading of the code: no test line here asserts these answers" : "Claude's reading of the code: no test in this change asserts these answers";
    for (const line of prose(key, W - 4 - whatW - 2, C)) say(`  ${" ".repeat(whatW + 2)}${line.replace("✓", `${G}✓${R}${C}`)}`);
    say();
  }
  if (part.quote) band("the author", C, `“${part.quote}”`, C + I);
  else band("the author", C, part.kind === "also" ? "never mentions this" : "said nothing about this", C + I);

  // The route: who calls whom as the case runs. A stop under another is called from the line just above it,
  // which is drawn in the caller's code; a rail on the left runs down what is inside each function.
  say();
  const marks = new Set(part.stops.map((stop) => stop.mark));
  const legend = [["◆", A, "changed here"], ["●", T, "in changed code"], ["○", C, "not in this change"]].filter(([mark]) => marks.has(mark))
    .map(([mark, color, says]) => `${color}${mark}${R}${C} ${says}${R}`).join("  ");
  const title = `${C}WHO CALLS WHOM, as this case runs${R}`;
  if (width(title) + width(legend) + 6 <= W - 2) say(`  ${pad(title, W - 4 - width(legend))}${legend}`);
  else { say(`  ${title}`); say(`  ${legend}`); }
  const kids = part.stops.map(() => []), roots = [];
  part.stops.forEach((stop, i) => (stop.parent >= 0 ? kids[stop.parent] : roots).push(i));
  // A story built before stops carried their code shows the lines Claude cited and the calls.
  part.stops.forEach((stop, i) => { stop.code ??= [...stop.lines.map((line) => ({ ...line, mine: true, cited: true })), ...kids[i].map((k) => ({ ...part.stops[k].call, mine: true }))].sort((a, b) => a.n - b.n).filter((line, at, all) => !at || all[at - 1].n !== line.n); });
  const numbers = part.stops.flatMap((stop) => stop.code.map((line) => line.n ?? 0));
  const digits = Math.max(3, ...numbers.map((n) => String(n).length));
  const gutter = digits + 3;
  const rail = (depth) => `${C}${"│ ".repeat(depth)}${R}`;
  const depthOf = [];
  const deepen = (i, depth) => { depthOf[i] = depth; for (const k of kids[i]) deepen(k, depth + 1); };
  roots.forEach((i) => deepen(i, 0));
  // Each stop's code without the indentation its lines share, all of it in one panel whose right edge is one
  // column for the whole route. What holds on a line Claude cites is its reading, in words beside the panel,
  // always on the right: wrapped there when long, the code wrapping at the panel's edge to leave it the room.
  const texts = (i) => part.stops[i].code.filter((line) => line.t?.trim()).map((line) => line.t.replace(/\t/g, "    "));
  const shared = part.stops.map((_, i) => Math.min(...texts(i).map(indent)));
  const spans = part.stops.flatMap((_, i) => texts(i).map((t) => ({ code: [...t].length - shared[i], at: 2 * (depthOf[i] + 1) + gutter + [...t].length - shared[i] })));
  const longest = Math.max(0, ...spans.map((one) => one.at));
  const noted = Math.max(0, ...part.stops.flatMap((stop) => stop.code.filter((line) => line.cited && line.value).map((line) => [...line.value].length + 2)));
  const room = noted ? Math.max(24, Math.min(noted, 48)) + 3 : 0;
  const edge = Math.min(W - 4 - room, longest + 1), aside = W - 4 - edge - 3;

  // Each function a step, numbered in the order the route reaches it.
  let step = 0;
  function drawStop(i, depth) {
    const stop = part.stops[i];
    const markColor = stop.mark === "◆" ? A : stop.mark === "●" ? T : C;
    const head = `${C}${++step}${R} ${markColor}${stop.mark}${R} ${RAISE}${B}${T}${stop.name}${R}`;
    const place = `${C}in ${stop.where}${stop.inside ? `, inside ${RAISE}${T}${stop.inside}${R}${C}` : ""}${stop.inChange ? "" : ", not in this change"}${R}`;
    const room = W - 4 - 2 * depth;
    if (width(head) + width(place) + 2 <= room) say(`  ${rail(depth)}${head}  ${place}`);
    else { say(`  ${rail(depth)}${head}`); say(`  ${rail(depth + 1)}${place}`); }
    // What it is for, without the name it opens with when Claude starts there: the line above says it.
    const is = (stop.is ?? "").replace(new RegExp(`^\`?${stop.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\`?\\s+`), "");
    if (is) for (const line of prose(is, room - 2)) say(`  ${rail(depth + 1)}${line}`);
    // Its code, every line in its file's colors on the diff's ground: the lines Claude cites on a stronger ground,
    // with what holds there beside them in yellow. A stop it calls is drawn under the line that calls it.
    const lead = rail(depth + 1), code = edge - 2 * (depth + 1) - gutter;
    const calledAt = new Map();
    for (const k of kids[i]) calledAt.set(part.stops[k].call.n, [...(calledAt.get(part.stops[k].call.n) ?? []), k]);
    const drawn = new Set();
    // A note's lines beside the row it is on and the rows after it; on rows of their own when another note, a
    // stop it calls or the end of the stop comes first.
    let pending = [];
    const flush = () => { for (const one of pending) say(`  ${lead}${" ".repeat(gutter + code)}${one}`); pending = []; };
    const draw = (line) => {
      const calls = line.mine ? calledAt.get(line.n) ?? [] : [];
      const ground = line.cited ? (line.sign === "+" ? PLUS_EMPH : line.sign === "-" ? MINUS_EMPH : LIFT) : line.sign === "+" ? PLUS : line.sign === "-" ? MINUS : RAISE;
      const mark = line.sign === "+" ? `${G}+` : line.sign === "-" ? `${X}−` : " ";
      const text = line.t.replace(/\t/g, "    ");
      const body = dent((line.paint ?? T + text).replace(/\t/g, "    "), shared[i]).replace(/\x1b\[0m/g, R + ground);
      // A line the change removed is numbered in red: its number is from before the change.
      const number = `${line.cited ? B + A : line.mine === false ? X : C}${String(line.n).padStart(digits)}${R}${ground} ${mark}${R}${ground} `;
      const value = line.cited ? line.value : calls.length ? `${part.stops[calls[0]].call.verb ?? "uses"} ${calls.map((k) => `\`${part.stops[k].name}\``).join(" and ")}, below` : "";
      const style = line.cited ? B + A : C;
      if (value) { flush(); pending = prose(value, Math.max(8, aside - 2), style).map((one, k) => `   ${k ? " " : line.cited ? `${A}◀${R}` : " "} ${one}`); }
      cut(body, code).forEach((piece, at) => {
        say(`  ${lead}${ground}${at ? " ".repeat(gutter) : number}${ground}${pad(piece, code)}${R}${pending.shift() ?? ""}`);
      });
      if (calls.length) flush();
      for (const k of calls) { drawStop(k, depth + 1); drawn.add(k); }
      return calls.length > 0;
    };
    stop.code.forEach((line, at) => {
      if (line.gap) { flush(); say(`  ${lead}${" ".repeat(digits - 1)}${C}⋯ ${line.gap} line${line.gap === 1 ? "" : "s"}${R}`); }
      else if (draw(line) && at < stop.code.length - 1) say(`  ${lead}${prose(`↩ back in \`${stop.name}\``, code, C)[0]}`);
    });
    flush();
    for (const k of kids[i]) if (!drawn.has(k)) drawStop(k, depth + 1);
  }
  roots.forEach((i, at) => {
    if (at) say();
    // How the case gets to a function nothing above calls: what in the code calls it, as otis found it.
    const from = part.stops[i].from;
    if (at) {
      const how = from ? `↓ ${from.fn ? `\`${from.fn}\`` : "code outside any function"} in ${from.where}:${from.n} ${from.verb} it` : "↓ next";
      for (const line of prose(how, W - 4, C)) say(`  ${line}`);
    }
    drawStop(i, 0);
  });
  if (!part.stops.length) say(`  ${A}no line Claude cited could be found in the code, so there is no route to show${R}`);
  if (part.stopped) { say(); band("stopped", C, part.stopped, C); }

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

/** Your words (otis-words): state, word and meaning, a row each. */
function yourWords() {
  try {
    return readFileSync(process.env.OTIS_WORDS || `${process.env.XDG_CONFIG_HOME || `${homedir()}/.config`}/otis/words.tsv`, "utf8")
      .split("\n").filter(Boolean).map((line) => line.split("\t"));
  } catch { return []; }
}
/** What the case says, in all its words, without the backticks around names. */
const saidOf = () => [part.text, part.setup, part.where, part.ends, part.stopped, ...part.facts.flatMap((fact) => [fact.what, fact.before, fact.after]),
  ...part.stops.flatMap((stop) => [stop.is, ...stop.lines.map((line) => line.value)])].join(" ").replace(/`/g, "");
const escapeRe = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
/** Whether the case uses a word, as a whole word. */
function uses(word) { return new RegExp(`\\b${escapeRe(word)}\\b`, "i").test(saidOf()); }

/** Your words (otis-words), marked once, hold in every case: a case that uses a word you are learning, or explains
 * one you know, and was not told with it, is told again for you behind the pane (reword.mjs), two at a time. */
function retell() {
  if (rewording || !part.stops?.length) return;
  const said = saidOf();
  const told = `${overlaid ? reworded.reader : ""} ${outline.reader ?? ""}`.toLowerCase();
  const stale = yourWords().some(([state, word]) => {
    if (!word || told.includes(word.toLowerCase())) return false;
    return state === "learning" || state === "noted" ? uses(word) : state === "known" && new RegExp(`\\b${escapeRe(word)}\\s*\\(`, "i").test(said);
  });
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
  const size = `${row.add ? `${G}+${row.add}${R}${RAISE}` : ""}${row.add && row.del ? " " : ""}${row.del ? `${X}−${row.del}${R}${RAISE}` : ""}`;
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
  row.lines.forEach((raw, at) => {
    const sign = raw[0];
    if (sign === "#") { flush(); say(); say(`  ${T}${raw.slice(1).trim()}${R}`); return; }
    if (sign === "~") { flush(); say(`  ${" ".repeat(gutter)}${C}⋯${raw.length > 1 ? "  " + raw.slice(1) : ""}${R}`); return; }
    const ground = sign === "+" ? PLUS : sign === "-" ? MINUS : "";
    const mark = sign === "+" ? `${G}+` : sign === "-" ? `${X}−` : " ";
    const text = (row.paint?.[at] ?? T + raw.slice(1)).replace(/\t/g, "    ").replace(/\x1b\[0m/g, R + ground);
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
say();
}

if (part.kind === "case" || part.kind === "also") { showCase(); retell(); } else showPart();
process.stdout.write(out.join("\n") + "\n");
