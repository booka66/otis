#!/usr/bin/env node
// story-pane.mjs <outline.json> <n> [<answer>]: case n of a change (sentences.mjs) as the symbol view's pane,
// FZF_PREVIEW_COLUMNS wide: the situation, how it ended before and how it ends now, its route through the
// code in the order it runs, the tests that run it. A part told without cases is its words and its code.
// On one of a case's answers, that answer comes first: the lines that decide it and the test line that asserts
// it; then the whole case, with only those lines lit.
import { readFileSync } from "node:fs";

const [file, which, answer] = process.argv.slice(2);
const outline = JSON.parse(readFileSync(file, "utf8"));
const part = outline.sentences[Number(which) - 1];
if (!part) process.exit(0);
const focus = answer ? part.facts?.[Number(answer) - 1] ?? null : null;
// The lines lit in the route: on an answer, the ones that decide it; a case followed before otis asked which
// (no lines) lights every line Claude cites, as the case does.
const lit = focus?.lines ? new Set(focus.lines) : null;
const W = Math.max(40, Number(process.env.FZF_PREVIEW_COLUMNS) || 96);

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
  if (focus) showAnswer();
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
      const what = prose(fact.what, whatW, fact === focus ? B + A : C);
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
  // column for the whole route, the code at least about half the pane. What holds on a line Claude cites is its
  // reading, in words beside the panel.
  const texts = (i) => part.stops[i].code.filter((line) => line.t?.trim()).map((line) => line.t.replace(/\t/g, "    "));
  const shared = part.stops.map((_, i) => Math.min(...texts(i).map(indent)));
  // Notes go beside the code when that wraps no line but the very long ones (a prompt, a message), else under.
  const spans = part.stops.flatMap((_, i) => texts(i).map((t) => ({ code: [...t].length - shared[i], at: 2 * (depthOf[i] + 1) + gutter + [...t].length - shared[i] })));
  const longest = Math.max(0, ...spans.map((one) => one.at)), usual = Math.max(0, ...spans.filter((one) => one.code <= 100).map((one) => one.at));
  const noted = Math.max(0, ...part.stops.flatMap((stop) => stop.code.filter((line) => line.cited && line.value).map((line) => [...line.value].length + 2)));
  const edge = Math.min(W - 4, longest + 1, Math.max(W - 4 - Math.min(noted, 60) - 3, usual + 1)), aside = W - 4 - edge - 3;

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
    if (stop.is) for (const line of prose(stop.is, room - 2)) say(`  ${rail(depth + 1)}${line}`);
    // Its code: the lines Claude cites bright on a stronger ground, with what holds there beside them in yellow;
    // the lines around them dim. A stop it calls is drawn under the line that calls it.
    const lead = rail(depth + 1), code = edge - 2 * (depth + 1) - gutter;
    const calledAt = new Map();
    for (const k of kids[i]) calledAt.set(part.stops[k].call.n, [...(calledAt.get(part.stops[k].call.n) ?? []), k]);
    const drawn = new Set();
    const draw = (line) => {
      const calls = line.mine ? calledAt.get(line.n) ?? [] : [];
      // On an answer only the lines that decide it are lit; the case's other readings stay, quiet.
      const bright = line.cited && (!lit || lit.has(`${i}:${line.n}`));
      const ground = bright ? (line.sign === "+" ? PLUS_EMPH : line.sign === "-" ? MINUS_EMPH : LIFT) : line.sign === "+" ? PLUS : line.sign === "-" ? MINUS : RAISE;
      const mark = line.sign === "+" ? `${G}+` : line.sign === "-" ? `${X}−` : " ";
      const text = line.t.replace(/\t/g, "    ");
      const body = dent(line.cited || calls.length ? (line.paint ?? T + text).replace(/\t/g, "    ") : C + text, shared[i]).replace(/\x1b\[0m/g, R + ground);
      // A line the change removed is numbered in red: its number is from before the change.
      const number = `${bright ? B + A : line.mine === false ? X : C}${String(line.n).padStart(digits)}${R}${ground} ${mark}${R}${ground} `;
      const value = line.cited ? line.value : calls.length ? `${part.stops[calls[0]].call.verb ?? "uses"} ${calls.map((k) => `\`${part.stops[k].name}\``).join(" and ")}, below` : "";
      const style = bright ? B + A : C;
      const note = value && aside >= 16 ? prose(value, aside - 2, style) : [];
      const beside = note.length === 1;
      cut(body, code).forEach((piece, at) => {
        say(`  ${lead}${ground}${at ? " ".repeat(gutter) : number}${ground}${pad(piece, code)}${R}${beside && !at ? `   ${bright ? `${A}◀${R}` : " "} ${note[0]}` : ""}`);
      });
      if (value && !beside && line.cited) prose(value, W - 4 - 2 * (depth + 1) - gutter - 2, style).forEach((one, at) => say(`  ${lead}${" ".repeat(gutter)}${bright ? A : C}${at ? " " : "↑"}${R} ${one}`));
      for (const k of calls) { drawStop(k, depth + 1); drawn.add(k); }
      return calls.length > 0;
    };
    stop.code.forEach((line, at) => {
      if (line.gap) say(`  ${lead}${" ".repeat(digits - 1)}${C}⋯ ${line.gap} line${line.gap === 1 ? "" : "s"}${R}`);
      else if (draw(line) && at < stop.code.length - 1) say(`  ${lead}${prose(`↩ back in \`${stop.name}\``, code, C)[0]}`);
    });
    for (const k of kids[i]) if (!drawn.has(k)) drawStop(k, depth + 1);
  }
  roots.forEach((i, at) => {
    if (at) say();
    // What ties it to the code above when nothing there calls it, so that it runs next is Claude's reading.
    const hop = part.hops[i];
    if (at && hop !== true && hop != null) {
      const tie = hop === "" || hop === false ? "nothing above calls this or hands it anything" : hop === "seam" ? "nothing above calls this; seam links it to the code above"
        : `nothing above calls this; it shares \`${hop}\` with the code above`;
      for (const line of prose(`┄ ${tie}, so that it runs next is Claude's reading`, W - 4, C)) say(`  ${line}`);
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

/** One of a case's answers, first: its question and how it ends, the lines in the case that decide it in the order
 * the case runs them, and the test line that asserts it in its whole statement; then a rule, and the case. */
function showAnswer() {
  const fact = focus;
  for (const line of prose(fact.what, W - 4, B + A)) say(`  ${line}`);
  if (!part.fresh && fact.before) band("before", X, fact.before, T, MINUS);
  band(part.fresh ? "now" : "after", G, fact.after || "·", T, PLUS);

  // The lines that decide it, each under its function, in the order the route reaches them.
  say();
  say(`  ${C}DECIDED BY${R}`);
  const tab = (text) => text.replace(/\t/g, "    ");
  if (!fact.lines) {
    for (const line of prose("this case was followed before otis asked which lines decide each answer, so every line it cites is lit below", W - 4, C)) say(`  ${line}`);
  } else {
    const kids = part.stops.map(() => []), roots = [];
    part.stops.forEach((stop, i) => (stop.parent >= 0 ? kids[stop.parent] : roots).push(i));
    const order = [];
    const walk = (i) => { order.push(i); kids[i].forEach(walk); };
    roots.forEach(walk);
    const rootOf = (i) => (part.stops[i].parent >= 0 ? rootOf(part.stops[i].parent) : i);
    const lines = (i) => part.stops[i].code.filter((line) => line.cited && lit.has(`${i}:${line.n}`));
    const want = order.filter((i) => lines(i).length);
    if (!want.length) for (const line of prose("no line in this case shows this happen, so the answer is Claude's reading alone", W - 4, A)) say(`  ${line}`);
    const all = want.flatMap((i) => lines(i).map((line) => ({ i, line })));
    const dentOf = new Map(want.map((i) => [i, Math.min(...lines(i).map((line) => indent(tab(line.t))))]));
    const digits = Math.max(3, ...all.map(({ line }) => String(line.n).length)), gutter = digits + 3;
    const codeW = Math.max(0, ...all.map(({ i, line }) => [...tab(line.t)].length - dentOf.get(i)));
    const noteW = Math.max(0, ...all.map(({ line }) => [...(line.value ?? "")].length));
    // What holds on each line goes beside it when every line and its note fit the pane, else under it.
    const beside = 2 + gutter + codeW + 1 + 4 + noteW <= W - 2;
    const code = Math.min(codeW + 1, W - 4 - gutter);
    let lastRoot = roots[0];
    for (const i of want) {
      const stop = part.stops[i], root = rootOf(i);
      // A function nothing in the case calls: that it runs here is Claude's reading, and this answer leans on it.
      if (root !== roots[0] && (i === want[0] || root !== lastRoot)) {
        const hop = part.hops[root];
        if (hop !== true && hop != null) {
          const tie = hop === "" || hop === false ? " and hands it nothing" : hop === "seam" ? "; seam links it to the code before it"
            : hop === part.stops[root].name ? "" : `; it shares \`${hop}\` with the code before it`;
          for (const line of prose(`┄ nothing in the case calls \`${part.stops[root].name}\`${tie}, so that it runs here is Claude's reading`, W - 4, C)) say(`  ${line}`);
        }
      }
      lastRoot = root;
      const markColor = stop.mark === "◆" ? A : stop.mark === "●" ? T : C;
      const head = `${markColor}${stop.mark}${R} ${RAISE}${B}${T}${stop.name}${R}`, place = `${C}in ${stop.where}${R}`;
      if (width(head) + width(place) + 2 <= W - 4) say(`  ${head}  ${place}`); else { say(`  ${head}`); say(`    ${place}`); }
      let prev = null;
      for (const line of lines(i)) {
        if (prev != null && line.n - prev > 1) say(`  ${" ".repeat(digits - 1)}${C}⋯${R}`);
        prev = line.n;
        const ground = line.sign === "+" ? PLUS_EMPH : line.sign === "-" ? MINUS_EMPH : LIFT;
        const mark = line.sign === "+" ? `${G}+` : line.sign === "-" ? `${X}−` : " ";
        const body = dent(tab(line.paint ?? T + line.t), dentOf.get(i)).replace(/\x1b\[0m/g, R + ground);
        const number = `${B}${A}${String(line.n).padStart(digits)}${R}${ground} ${mark}${R}${ground} `;
        cut(body, code).forEach((piece, at) => say(`  ${ground}${at ? " ".repeat(gutter) : number}${ground}${pad(piece, code)}${R}${beside && !at && line.value ? `  ${A}◀${R} ${prose(line.value, noteW + 2, B + A)[0]}` : ""}`));
        if (!beside && line.value) prose(line.value, W - 4 - gutter - 2, B + A).forEach((one, at) => say(`  ${" ".repeat(gutter)}${A}${at ? " " : "↑"}${R} ${one}`));
      }
    }
  }

  // The test line that asserts it, in the whole statement it is in, under the test's name.
  say();
  say(`  ${C}ASSERTED BY${R}`);
  const pin = fact.pinned;
  if (!pin) {
    const runs = part.runs.length;
    for (const line of prose(`no test line asserts this answer${runs ? `; ${runs === 1 ? "the test that runs" : `the ${runs} tests that run`} this case ${runs === 1 ? "is" : "are"} at the bottom` : ", and no test in this change runs this case"}`, W - 4, C)) say(`  ${line}`);
  } else {
    say(`  ${G}✓${R} ${C}${pin.path ?? pin.where}${R}`);
    if (pin.test && !pin.test.includes("$")) wrap(pin.test, W - 8).forEach((line, k) => say(`    ${T}${k ? "  " : "◦ "}${line}${R}`));
    const shown = pin.lines ?? [{ n: pin.n, t: pin.t }];
    const digits = Math.max(3, ...shown.map((line) => String(line.n).length)), gutter = digits + 3;
    const shared = Math.min(...shown.filter((line) => line.t.trim()).map((line) => indent(tab(line.t))));
    const code = Math.min(W - 4 - gutter, Math.max(...shown.map((line) => [...tab(line.t)].length - shared)) + 1);
    for (const line of shown) {
      const hit = line.n === pin.n, ground = hit ? LIFT : RAISE;
      const body = dent(tab(line.paint ?? T + line.t), shared).replace(/\x1b\[0m/g, R + ground);
      cut(body, code).forEach((piece, at) => say(`  ${ground}${at ? " ".repeat(gutter) : `${hit ? B + A : C}${String(line.n).padStart(digits)}${R}${ground}   `}${ground}${pad(piece, code)}${R}`));
    }
  }
  say();
  const label = " the whole case ";
  say(`  ${C}──${label}${"─".repeat(Math.max(2, W - 4 - 2 - label.length))}${R}`);
  say();
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
  const gutter = digits + 3, code = W - 3 - gutter;
  row.lines.forEach((raw, at) => {
    const sign = raw[0];
    if (sign === "#") { say(); say(`  ${T}${raw.slice(1).trim()}${R}`); return; }
    if (sign === "~") { say(`  ${" ".repeat(gutter)}${C}⋯${raw.length > 1 ? "  " + raw.slice(1) : ""}${R}`); return; }
    const ground = sign === "+" ? PLUS : sign === "-" ? MINUS : "";
    const mark = sign === "+" ? `${G}+` : sign === "-" ? `${X}−` : " ";
    const text = (row.paint?.[at] ?? T + raw.slice(1)).replace(/\t/g, "    ").replace(/\x1b\[0m/g, R + ground);
    const note = row.notes?.[at];
    const pieces = cut(text, code);
    const inline = note && pieces.length === 1 && width(pieces[0]) + 4 + [...note].length <= code;
    pieces.forEach((piece, i) => {
      const lead = i ? " ".repeat(gutter) : `${C}${String(row.nums[at] || "").padStart(digits)} ${mark}${R}${ground} `;
      const tail = inline ? `${R}${ground}  ${E}← ${note}` : "";
      say(`  ${ground}${lead}${ground}${pad(piece + tail, code)}${R}`);
    });
    if (note && !inline) for (const line of wrap(note, code - 2)) say(`  ${" ".repeat(gutter)}${E}↑ ${line}${R}`);
  });
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

if (part.kind === "case" || part.kind === "also") showCase(); else showPart();
process.stdout.write(out.join("\n") + "\n");
