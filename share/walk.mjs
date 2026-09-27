// walk.mjs: P's traced walks (git-trace), from what share/walk-trace.js left.
//
//   walk.mjs targets <table> [base]    the tracer's targets: every line of each changed definition,
//                                      at head, or with base as the base has them
//   walk.mjs split <dir> [base]        each slot's trace back into a trace a spec (below)
//   walk.mjs cover <dir>               <dir>/cover.json: the tests the traces saw, the changed
//                                      definitions each ran, and the callable ones none ran, each
//                                      with why
//   walk.mjs rows <dir>                P's list: those gaps, then the tests
//   walk.mjs preview <dir> <row id>    a row's preview
//   walk.mjs walk-rows <dir> <test> <side>        a test's walk, a row a call it made
//   walk.mjs walk-prep <dir> <test> <side> <width>  that walk rendered for a pane that wide:
//                                      its rows, where each key goes from each line, and each
//                                      line's preview (git-trace cats them)
//
// <dir> is the run's (git-trace): table (git-symbols --table), shas (base and
// head), specs (a path a line), trace/<i>.jsonl the head's hits for spec i
// and base/<i>.jsonl the base's, ran/<i> and base/<i>.status how each ran,
// inputs.json the inputs Claude wrote (w). <test> is its index in cover.json,
// <side> head or base.
//
// A hit is a pause before its line runs, so what changed since the last hit
// in the same call was set by that one's line, and is shown there.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { gzipSync } from "node:zlib";

const [cmd, ...args] = process.argv.slice(2);

// --- the table -----------------------------------------------------------------
// A row: path, kind, name, class, exported, change, side, start, end, and at
// 14 and 15 where the base has it; mentions further on, as ids.
function table(file) {
  return readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => l.split("\t")).filter((f) => f[1] !== "file").map((f) => ({
    path: f[0], kind: f[1], name: f[2], cls: f[3], change: f[5], side: f[6],
    start: +f[7], end: +f[8], bstart: f[13] ? +f[13] : null, bend: f[14] ? +f[14] : null,
    sig: f[12] || "", id: f[0] + "#" + (f[3] ? f[3] + "." : "") + f[2], rest: f.slice(15).join("\t"),
  }));
}
const TEST = /(\.(spec|test)\.[cm]?[jt]sx?$|_test\.[cm]?[jt]sx?$|\/__tests__\/)/;
// A definition's range on a side, or none.
function range(d, side) {
  if (side === "base") return d.side === "old" ? [d.start, d.end] : d.bstart ? [d.bstart, d.bend] : null;
  return d.side === "old" ? null : [d.start, d.end];
}
// The definitions to trace: a class's members rather than the class.
function defs(rows) {
  const src = rows.filter((d) => !TEST.test(d.path));
  return src.filter((d) => !(d.kind === "class" && src.some((o) => o.cls === d.name && o.path === d.path)));
}
function callable(d) {
  return d.kind === "fn" || d.kind === "method" || d.kind === "constfn" || (d.kind === "const" && /=>|function/.test(d.sig));
}
// owner: the tightest definition holding line on side.
function owner(ds, path, line, side) {
  let best = null;
  for (const d of ds) {
    if (d.path !== path) continue;
    const r = range(d, side);
    if (r && r[0] <= line && line <= r[1] && (!best || r[1] - r[0] < best.r[1] - best.r[0])) best = { d, r };
  }
  return best;
}

// --- git --------------------------------------------------------------------------
const git = (...a) => { try { return execFileSync("git", a, { encoding: "utf8", maxBuffer: 1 << 28, stdio: ["ignore", "pipe", "ignore"] }); } catch { return ""; } };
const texts = new Map();
function text(rev, path) {
  const k = rev + ":" + path;
  if (!texts.has(k)) texts.set(k, git("show", k).split("\n"));
  return texts.get(k);
}
// changed: the lines the change made on a side, per path.
const changedCache = new Map();
function changed(rev, path, side) {
  const k = side + path;
  if (!changedCache.has(k)) {
    const s = new Set();
    const d = git("diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", rev.base, rev.head, "--", path);
    for (const m of d.matchAll(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/gm)) {
      const [a, n] = side === "base" ? [+m[1], m[2] === undefined ? 1 : +m[2]] : [+m[3], m[4] === undefined ? 1 : +m[4]];
      for (let i = a; i < a + n; i++) s.add(i);
    }
    changedCache.set(k, s);
  }
  return changedCache.get(k);
}

// --- a run's files ----------------------------------------------------------------
function run(dir) {
  const [base, head] = readFileSync(join(dir, "shas"), "utf8").trim().split(/\s+/);
  const specs = existsSync(join(dir, "specs")) ? readFileSync(join(dir, "specs"), "utf8").split("\n").filter(Boolean) : [];
  return { dir, rev: { base, head }, specs, rows: table(join(dir, "table")) };
}
function hits(dir, side, i) {
  const f = join(dir, side === "base" ? "base" : "trace", i + ".jsonl");
  if (!existsSync(f)) return [];
  return lines(f).filter((h) => h.at);
}
// A trace file is read once a process, however many tests ask for it.
const read = new Map();
function lines(f) {
  if (!read.has(f)) read.set(f, readFileSync(f, "utf8").split("\n").filter(Boolean).flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } }));
  return read.get(f);
}
// breakable: the lines of path V8 could stop on, as the tracer found them;
// null when it said nothing (a trace from before it did).
function breakable(r, side, path) {
  const s = new Set();
  let any = false;
  const sub = side === "base" ? "base" : "trace";
  for (const f of [join(r.dir, sub, "breakable.jsonl"), ...r.specs.map((spec, i) => join(r.dir, sub, i + ".jsonl"))]) {
    if (!existsSync(f)) continue;
    for (const b of lines(f)) if (b.breakable === path) { any = true; for (const n of b.lines) s.add(n); }
  }
  return any ? s : null;
}

// split: what each slot's run left (w<k>.jsonl, w<k>.specs its specs, w<k>.status
// how it ended) back into a file a spec, by the spec file each test ran in, and
// a file of where V8 could stop. A test's file is where the build put it (lib/
// for src/, .js for .ts), so it is matched by its name, then by the most
// directories in common.
function split(r, side) {
  const sub = join(r.dir, side === "base" ? "base" : "trace");
  const stem = (p) => p.split("/").pop().replace(/\.[cm]?[jt]sx?$/, "");
  const of = new Map();
  const spec = (file) => {
    if (!of.has(file)) {
      const want = stem(file), dirs = file.split("/").slice(0, -1).reverse();
      let best = -1, score = -1;
      r.specs.forEach((sp, i) => {
        if (stem(sp) !== want) return;
        const ds = sp.split("/").slice(0, -1).reverse();
        let n = 0; while (n < ds.length && n < dirs.length && (ds[n] === dirs[n] || /^(src|lib)$/.test(ds[n]))) n++;
        if (n > score) { score = n; best = i; }
      });
      of.set(file, best);
    }
    return of.get(file);
  };
  const out = new Map(), marks = [];
  for (const f of readdirSync(sub).filter((x) => /^w\d+\.jsonl$/.test(x))) {
    for (const l of readFileSync(join(sub, f), "utf8").split("\n")) {
      if (!l) continue;
      if (l.startsWith('{"breakable"')) { marks.push(l); continue; }
      let h; try { h = JSON.parse(l); } catch { continue; }
      const i = h.file ? spec(h.file) : -1;
      if (i < 0) continue;
      if (!out.has(i)) out.set(i, []);
      out.get(i).push(l);
    }
  }
  // Only the specs these slots ran: a run of one spec (w) leaves the rest.
  const ran = new Set();
  for (const f of readdirSync(sub).filter((x) => /^w\d+\.specs$/.test(x))) for (const i of readFileSync(join(sub, f), "utf8").split("\n").filter(Boolean)) ran.add(+i);
  for (const i of ran) writeFileSync(join(sub, i + ".jsonl"), (out.get(i) || []).join("\n") + (out.has(i) ? "\n" : ""));
  const bf = join(sub, "breakable.jsonl");
  const had = existsSync(bf) ? readFileSync(bf, "utf8").split("\n").filter(Boolean) : [];
  const all = [...new Set([...had, ...marks])];
  writeFileSync(bf, all.join("\n") + (all.length ? "\n" : ""));
  // How each spec's run ended: its slot's.
  const ranDir = side === "base" ? sub : join(r.dir, "ran");
  mkdirSync(ranDir, { recursive: true });
  for (const f of readdirSync(sub).filter((x) => /^w\d+\.specs$/.test(x))) {
    const st = existsSync(join(sub, f.replace("specs", "status"))) ? readFileSync(join(sub, f.replace("specs", "status")), "utf8").trim() : "";
    for (const i of readFileSync(join(sub, f), "utf8").split("\n").filter(Boolean)) writeFileSync(join(ranDir, side === "base" ? i + ".status" : i), st + "\n");
  }
}
function status(dir, side, i) {
  const f = join(dir, side === "base" ? "base" : "ran", side === "base" ? i + ".status" : String(i));
  return existsSync(f) ? readFileSync(f, "utf8").trim() : "";
}
// mocks: the modules a spec replaces with jest.mock, as paths without extensions.
function mocks(spec, head) {
  const t = text(head, spec).join("\n");
  return [...t.matchAll(/jest\.mock\(\s*["'`]([^"'`]+)["'`]/g)].map((m) => m[1]).filter((p) => p.startsWith(".")).map((p) => resolve("/", dirname(spec), p).slice(1));
}
const stem = (p) => p.replace(/\.[cm]?[jt]sx?$/, "");

// --- the palette, as rowfmt.awk has it ----------------------------------------
const sgr = (k, d) => "\x1b[" + (process.env["OTIS_T_" + k] ?? d) + "m";
const C = { at: sgr("ATTENTION", "33"), good: sgr("GOOD", "32"), bad: sgr("BAD", "31"), yours: sgr("YOURS", "35"),
  text: sgr("TEXT", "39"), ctx: sgr("CONTEXT", "90"), faint: sgr("FAINT", "2"), else: sgr("ELSEWHERE", "36"), r: "\x1b[0m" };
const width = (s) => [...s.replace(/\x1b\[[0-9;]*m/g, "")].length;
// solid: each line's erase to its end (a ground carried to the pane's edge:
// the change's, the line it is on) as spaces to width w instead, since the
// screens' wrap drops every erase (share/pane-wrap.awk): so every such line
// is the pane's width whatever its code, and the code sits in a block of
// one width rather than bars as ragged as the lines.
const solid = (text, w) => text.split("\n").map((l) => {
  const i = l.indexOf("\x1b[0K");
  if (i < 0) return l;
  const head = l.slice(0, i);
  return head + " ".repeat(Math.max(0, w - width(head))) + l.slice(i + 4).replace(/\x1b\[0K/g, "");
}).join("\n");
const cut = (s, n) => ([...s].length > n ? [...s].slice(0, Math.max(0, n - 1)).join("") + "…" : s);
function wrap(t, w, lead = "") {
  const out = [];
  let line = "";
  for (const word of t.split(/\s+/)) {
    if (line && width(lead + line + " " + word) > w) { out.push(lead + line); line = word; } else line = line ? line + " " + word : word;
  }
  if (line) out.push(lead + line);
  return out;
}
const W = () => +(process.env.FZF_PREVIEW_COLUMNS || 100);
// cutA: s cut to n columns, its colors kept and closed.
function cutA(s, n) {
  let out = "", w = 0;
  for (const m of s.matchAll(/\x1b\[[0-9;]*m|[^\x1b]/gu)) {
    if (m[0].startsWith("\x1b")) { out += m[0]; continue; }
    if (w >= n - 1 && w + 1 < width(s)) return out + "…\x1b[0m";
    out += m[0]; w++;
  }
  return out;
}
// under: s with pre put back after every reset in it, as a ground or a dim.
const under = (s, pre) => pre + s.replace(/\x1b\[0m/g, "\x1b[0m" + pre);
// The theme's grounds for added and removed lines, as git-delta's.
function ground(hex, dflt) {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || "");
  return m ? `\x1b[48;2;${parseInt(m[1], 16)};${parseInt(m[2], 16)};${parseInt(m[3], 16)}m` : `\x1b[${dflt}m`;
}
// The code drawn around a step's own lines, above and below (render).
const AROUND = 60;
const PLUS = ground(process.env.OTIS_T_PLUS, "48;5;22"), MINUS = ground(process.env.OTIS_T_MINUS, "48;5;52");
// The line you are on: a bar in the theme's attention hue, dimmed to a ground.
const HERE = (() => {
  const m = /38;2;(\d+);(\d+);(\d+)/.exec(process.env.OTIS_T_ATTENTION || "");
  return m ? `\x1b[48;2;${Math.round(m[1] * 0.28)};${Math.round(m[2] * 0.28)};${Math.round(m[3] * 0.28)}m` : "\x1b[48;5;58m";
})();
// painted: a file's lines colored as code by bat, once; plain without it.
const paintedCache = new Map();
function painted(rev, path) {
  const k = rev + ":" + path;
  if (!paintedCache.has(k)) {
    const t = text(rev, path);
    let out = null;
    try {
      out = execFileSync("bat", ["--color=always", "--style=plain", "--paging=never", "-l", path.replace(/.*\./, "")],
        { input: t.join("\n"), encoding: "utf8", env: { ...process.env, BAT_THEME: process.env.OTIS_T_BAT || "ansi" }, stdio: ["pipe", "pipe", "ignore"], maxBuffer: 1 << 28 }).split("\n");
    } catch {}
    paintedCache.set(k, out && out.length >= t.length - 1 ? out : t);
  }
  return paintedCache.get(k);
}
// hunks: the change to path, as the lines it removed before each head line
// (a pure removal before the line after it), and the lines it added.
const hunksCache = new Map();
function hunks(rev, path) {
  if (!hunksCache.has(path)) {
    const before = new Map(), added = new Set(), removed = new Set();
    const d = git("diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", rev.base, rev.head, "--", path).split("\n");
    let o = 0, n = 0, at = 0;
    for (const l of d) {
      const m = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(l);
      if (m) { o = +m[1]; n = +m[3]; at = m[4] === "0" ? n + 1 : n; continue; }
      if (l.startsWith("-") && !l.startsWith("---")) { if (!before.has(at)) before.set(at, []); before.get(at).push([o, l.slice(1)]); removed.add(o); o++; }
      else if (l.startsWith("+") && !l.startsWith("+++")) { added.add(n); n++; }
    }
    hunksCache.set(path, { before, added, removed });
  }
  return hunksCache.get(path);
}

// --- the walk of one test on one side --------------------------------------------
// Steps: each hit its function (the changed definition holding it), line and
// depth, and the values set on that line. Kept, since every preview asks.
const NOISE = /^(\w+_\d+|exports|module|require|__\w+)$/;
// A module or a service object: nothing but functions, as the tracer shows them.
const API = /^(\w+ )?\{ (\w+: ƒ(, )?)+(, …)? \}$/;
// A value as the tracer keeps it: a string, or an object or array as
// {c, a, p: [[name, value]...], m}. tree: a field a line, nested, for reading.
const isObj = (v) => v && typeof v === "object";
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
// full: a value on one line, all of it; shape: an object by its fields' names.
function full(v) {
  if (!isObj(v)) return String(v);
  const inner = v.p.map(([k, x]) => (v.a ? "" : k + ": ") + full(x)).join(", ");
  return (v.c && !v.a ? v.c + " " : "") + (v.a ? "[" : "{ ") + inner + (v.m ? ", and more" : "") + (v.a ? "]" : " }");
}
function shape(v) {
  if (!isObj(v)) return String(v);
  return v.a ? `${v.p.length}${v.m ? "+" : ""} items` : (v.c ? v.c + " " : "") + "{ " + v.p.map(([k]) => k).join(", ") + (v.m ? ", and more" : "") + " }";
}
function tree(name, v, lead, w, out, max) {
  if (out.length >= max) return;
  // Whole on its line when it fits: ["email", "phoneNumber"], not a line each.
  if (isObj(v) && width(lead) + name.length + 2 + full(v).length <= w) { out.push(lead + C.ctx + name + C.r + "  " + C.else + full(v) + C.r); return; }
  if (!isObj(v)) {
    const room = Math.max(20, w - width(lead) - name.length - 2), t = [...String(v)];
    out.push(lead + C.ctx + name + C.r + "  " + C.else + t.slice(0, room).join("") + C.r);
    for (let i = room; i < t.length && out.length < max; i += room) out.push(lead + " ".repeat(name.length + 2) + C.else + t.slice(i, i + room).join("") + C.r);
    return;
  }
  out.push(lead + C.ctx + name + C.r + C.faint + "  " + (v.a ? "" : v.c || "") + C.r);
  for (const [k, x] of v.p) tree(k, x, lead + "  ", w, out, max);
  if (v.m && out.length < max) out.push(lead + "  " + C.faint + "and more the trace did not keep" + C.r);
}
function walk(r, ti, side) {
  const cover = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
  const t = cover.tests[ti];
  const cache = join(r.dir, "walks", `${ti}-${side}.json`);
  if (existsSync(cache)) return { t, ...JSON.parse(readFileSync(cache, "utf8")) };
  const ds = defs(r.rows);
  const steps = [], last = new Map(), at = new Map(), raw = new Map();
  for (const h of hits(r.dir, side, t.spec)) {
    if (h.test !== t.name || h.at.line == null) continue;
    const o = owner(ds, h.at.src, h.at.line, side);
    if (!o) continue;
    const key = o.d.id + ":" + h.stack.length, depth = h.stack.length;
    // The same call as this function's last hit at this depth, unless its
    // caller had control since: then this is a call of its own.
    let cont = at.has(key);
    for (let j = cont ? at.get(key) + 1 : steps.length; cont && j < steps.length; j++) if (steps[j].rawDepth < depth) cont = false;
    const prev = cont ? last.get(key) : {};
    // "=": the value this function had at its last pause at this depth.
    const carried = raw.get(key) || {};
    const locals = Object.fromEntries(Object.entries(h.locals).map(([k, v]) => [k, v === "=" ? carried[k] : v]));
    raw.set(key, locals);
    const vals = Object.fromEntries(Object.entries(locals).filter(([k, v]) => v !== undefined && !NOISE.test(k) && v !== "ƒ" && !(typeof v === "string" && API.test(v)) && !(isObj(v) && !v.a && !v.c && !v.p.length)));
    const set = Object.entries(vals).filter(([k, v]) => !same(prev[k], v));
    last.set(key, vals);
    // A function inside the definition (a callback it passes on) is a call
    // of its own, named for it: map's callback, not the definition again.
    const src = text(side === "base" ? r.rev.base : r.rev.head, o.d.path);
    const cb = cont ? null : inner(src, o.r, h.at.line, h.at.fn, o.d.name);
    const fn = cont ? steps[at.get(key)].fn : cb ? cb.name : o.d.name;
    const start = cont ? steps[at.get(key)].start : cb ? cb.start : o.r[0];
    steps.push({ id: o.d.id, fn, start, path: o.d.path, line: h.at.line, depth, rawDepth: depth, def: o.r, values: [], args: [] });
    // What a call starts with is what it was called with (its parameters, not
    // the names it closes over); what changes after was set by the line before.
    if (cont) steps[at.get(key)].values.push(...set);
    else {
      const sig = params(src, cb ? cb.start : o.r[0], h.at.line, !!cb);
      const param = ([a]) => new RegExp("(^|[^\\w$.])" + a.replace(/\$/g, "\\$") + "\\b").test(sig);
      steps[steps.length - 1].args = set.filter(param);
      // What it closes over: not what it was called with, but what its lines read.
      steps[steps.length - 1].outer = set.filter((x) => !param(x));
    }
    at.set(key, steps.length - 1);
  }
  const m = Math.min(...steps.map((s) => s.depth));
  for (const s of steps) s.depth -= m;
  mkdirSync(join(r.dir, "walks"), { recursive: true });
  writeFileSync(cache, JSON.stringify({ steps }));
  return { t, steps };
}
// inner: the function a hit is in when it is not the definition itself, a
// callback in it: {start, name}, "map's callback" for one passed to .map.
function inner(src, def, line, fn, name) {
  if (fn && fn !== "(anonymous)" && fn !== name && !fn.endsWith("." + name)) return { start: line, name: fn };
  if (fn !== "(anonymous)") return null;
  for (let l = line; l >= Math.max(def[0] + 1, line - 6); l--) {
    const t = src[l - 1] || "";
    if (!/=>|\bfunction\b/.test(t)) continue;
    const pre = (src[l - 2] || "") + " " + t.slice(0, t.search(/=>|\bfunction\b/));
    const calls = [...pre.matchAll(/\.?(\w+)\s*\(/g)].map((m) => m[1]).filter((x) => !/^(async|function)$/.test(x));
    return { start: l, name: calls.length ? calls[calls.length - 1] + "'s callback" : "callback" };
  }
  return { start: line, name: "callback" };
}
// params: the text a function's parameters are in, from its first line to
// the line it first paused on.
function params(src, start, line, cb) {
  // Without defaults: deps = liveDeps takes deps, not liveDeps.
  const t = src.slice(start - 1, Math.max(start, line - 1)).join(" ").replace(/([\w$\]}]\s*(:[^=,()]*)?)=(?!>)[^,()]*/g, "$1");
  const e = t.search(/=>|\)\s*(:[^{]*)?\{/);
  if (e < 0 || !cb) return e < 0 ? t : t.slice(0, e + 1);
  // A callback's own list: back from its arrow to the paren that opens it.
  const h = t.slice(0, e).trimEnd();
  if (!h.endsWith(")")) return (h.match(/[\w$]+$/) || [""])[0];
  let n = 0;
  for (let i = h.length - 1; i >= 0; i--) { n += h[i] === ")" ? 1 : h[i] === "(" ? -1 : 0; if (!n) return h.slice(i); }
  return h;
}
// visits: runs of steps in one call of one function.
function visits(steps) {
  const v = [];
  steps.forEach((s, i) => {
    const l = v[v.length - 1];
    if (l && l.id === s.id && l.depth === s.depth && l.fn === s.fn) l.last = i; else v.push({ id: s.id, fn: s.fn, depth: s.depth, first: i, last: i });
  });
  return v;
}
function outline(steps) {
  return visits(steps).filter((v) => v.depth <= 1).map((v) => [v.fn, v.depth]).filter((x, i, a) => i === 0 || x[0] !== a[i - 1][0] || x[1] !== a[i - 1][1]);
}

// --- cover ------------------------------------------------------------------------
function cover(r) {
  const ds = defs(r.rows);
  const inputs = existsSync(join(r.dir, "inputs.json")) ? JSON.parse(readFileSync(join(r.dir, "inputs.json"), "utf8")) : [];
  const written = (name) => inputs.some((x) => x.name && name.endsWith(x.name));
  const tests = new Map();
  // What the change's own tests run, and what Claude's inputs (w) run.
  const ran = new Set(), ranWritten = new Set();
  r.specs.forEach((spec, i) => {
    for (const h of hits(r.dir, "head", i)) {
      if (!h.test || h.at.line == null) continue;
      const o = owner(ds, h.at.src, h.at.line, "head");
      if (!tests.has(h.test)) tests.set(h.test, { name: h.test, spec: i, defs: new Set(), steps: [] });
      if (!o) continue;
      tests.get(h.test).defs.add(o.d.id);
      (written(h.test) ? ranWritten : ran).add(o.d.id);
    }
  });
  // Before: whether a test ran at the base, and how much of the change's old code.
  const before = new Map();
  let based = false;
  r.specs.forEach((spec, i) => {
    if (!status(r.dir, "base", i)) return;
    based = true;
    for (const h of hits(r.dir, "base", i)) if (h.test) before.set(h.test, (before.get(h.test) || 0) + 1);
  });
  const mocked = new Map();
  r.specs.forEach((spec) => { for (const m of mocks(spec, r.rev.head)) mocked.set(m, [...(mocked.get(m) || []), spec.split("/").pop()]); });
  const byId = new Map(ds.map((d) => [d.id, d]));
  const gaps = ds.filter((d) => callable(d) && d.side !== "old" && !ran.has(d.id)).map((d) => {
    const by = mocked.get(stem(d.path));
    const callers = ds.filter((c) => c.id !== d.id && c.rest.split(/[\t|]/).includes(d.id));
    const live = callers.find((c) => ran.has(c.id));
    let why, call = null;
    if (by) why = "mocked in " + [...new Set(by)].join(", ");
    else if (live) {
      const t = text(r.rev.head, live.path);
      for (let n = live.start; n <= live.end; n++) if (new RegExp("\\b" + d.name + "\\s*[(<]").test(t[n - 1] || "")) { call = { id: live.id, path: live.path, line: n }; break; }
      why = call ? `its call in ${live.name} (line ${call.line}) never runs` : `${live.name} runs, but never calls it`;
    } else if (callers.length) why = `its caller ${callers[0].name} never runs either`;
    else why = "nothing traced reaches it";
    const sig = d.change === "signature" ? "signature changed · " : d.change === "added" ? "" : "";
    const input = inputs.find((x) => x.gap === d.id);
    return { id: d.id, name: d.name, path: d.path, start: d.start, end: d.end, change: d.change, why: sig + why, mocked: !!by, call,
      callers: callers.map((c) => c.id), input: input ? { ...input, reached: ranWritten.has(d.id) } : null };
  });
  // Mocked last: nothing an input could do about those.
  gaps.sort((a, b) => a.mocked - b.mocked || (b.change === "signature") - (a.change === "signature"));
  const out = {
    specs: r.specs.map((s, i) => ({ path: s, status: status(r.dir, "head", i), base: status(r.dir, "base", i), hits: hits(r.dir, "head", i).length })),
    based,
    callable: ds.filter((d) => callable(d) && d.side !== "old").length,
    tests: [...tests.values()].map((t) => ({ name: t.name, spec: t.spec, ids: [...t.defs], defs: [...t.defs].filter((id) => callable(byId.get(id))).length,
      before: based ? before.get(t.name) || 0 : null, written: written(t.name) })).sort((a, b) => b.defs - a.defs),
    gaps,
  };
  writeFileSync(join(r.dir, "cover.json"), JSON.stringify(out));
}

// --- P's list -----------------------------------------------------------------------
// The picker's fields: the row, then path, line, side, start, end, and the id at 12.
const row = (show, path, line, id) => [show, path, line, "new", line, line, "", "", "", "", "", id].join("\t");
function rows(r) {
  console.log(testRows(r).join("\n"));
}
// testRows: P's screen's rows: the changed code no test runs, then the tests.
function testRows(r) {
  const c = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
  const out = [];
  if (c.gaps.length) {
    out.push(`${C.at}changed code no test runs · ${c.gaps.length}${C.r}` + "\t".repeat(11) + "gk-gaps");
    c.gaps.forEach((g, i) => {
      const mark = g.input ? (g.input.reached ? `${C.good}✦ ` : `${C.yours}✦ `) : `${C.at}⚠ `;
      out.push(row(`${mark}${C.r}${C.text}${g.name}${C.r}  ${C.ctx}${g.why}${C.r}`, g.path, g.start, "g:" + i));
    });
  }
  const n = c.tests.length, max = Math.max(1, ...c.tests.map((t) => t.defs));
  out.push(`${C.faint}tests, by how much of the change they run · ${n}${C.r}` + "\t".repeat(11) + "gk-tests");
  c.tests.forEach((t, i) => {
    const bar = "▇".repeat(Math.max(1, Math.round(6 * t.defs / max)));
    const w = t.written ? `${C.yours}✦ ${C.r}` : "";
    const b = t.before === null ? "" : t.before ? "" : `  ${C.faint}new at head${C.r}`;
    out.push(row(`${C.faint}${bar.padEnd(6)}${C.r} ${C.ctx}${String(t.defs).padStart(2)}${C.r}  ${w}${C.text}${t.name}${C.r}${b}`, c.specs[t.spec].path, 1, "t:" + i));
  });
  // A spec that ran and left no hits: another runner than Jest (Vitest), or
  // tests that never reach the change. Either way P has nothing from it.
  const blind = c.specs.filter((s) => s.status === "0" && !s.hits);
  if (blind.length) out.push(`${C.ctx}traced nothing from ${blind.map((s) => s.path.split("/").pop()).join(", ")}: it ran, but none of its tests reached the change${C.r}` + "\t".repeat(11) + "gk-blind");
  const failed = c.specs.filter((s) => s.status && s.status !== "0");
  if (failed.length) out.push(`${C.bad}${failed.length} spec file${failed.length === 1 ? "" : "s"} failed to run: ${failed.map((s) => s.path.split("/").pop()).join(", ")}${C.r}` + "\t".repeat(11) + "gk-failed");
  return out;
}

// --- a row's preview ------------------------------------------------------------------
function preview(r, id, c = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"))) {
  const w = W(), out = [];
  if (id.startsWith("t:")) {
    const ti = +id.slice(2), t = c.tests[ti];
    const { steps } = walk(r, ti, "head");
    out.push(...wrap(t.name, w).map((l) => C.text + "\x1b[1m" + l + C.r));
    out.push(C.ctx + c.specs[t.spec].path + C.r, "");
    out.push(`${C.ctx}runs ${C.r}${C.text}${t.defs}${C.r}${C.ctx} of the change's ${c.callable} functions, ${steps.length} of its lines. Its path through them:${C.r}`, "");
    for (const [fn, d] of outline(steps)) out.push("  " + (d ? C.faint + "└ " + C.r + C.ctx : C.text) + fn + C.r);
    out.push("");
    if (t.before !== null) out.push(t.before ? `${C.ctx}before the change it ran too: b in its walk shows that run${C.r}` : `${C.at}at the base it ran none of the change's old code, or did not load${C.r}`);
    out.push(`${C.faint}enter walks it, line by line, with the values it ran with${C.r}`);
  } else if (id.startsWith("g:")) {
    const g = c.gaps[+id.slice(2)];
    out.push(C.text + "\x1b[1m" + g.name + C.r, C.ctx + g.path + ":" + g.start + C.r, "");
    out.push(...wrap(g.why, w).map((l) => C.at + l + C.r), "");
    // The call no test makes, else the function itself: each line as the
    // traces saw it, ● run by some test.
    const at = g.call || { path: g.path, line: g.start };
    const ranLines = new Set();
    r.specs.forEach((s, i) => { for (const h of hits(r.dir, "head", i)) if (h.test && h.at.src === at.path) ranLines.add(h.at.line); });
    const t = text(r.rev.head, at.path);
    for (let n = Math.max(1, at.line - 6); n <= Math.min(t.length, at.line + 6); n++) {
      const here = n === at.line, ran = ranLines.has(n);
      const mark = ran ? C.good + "●" : here ? C.at + "○" : " ";
      out.push(`${C.faint}${String(n).padStart(5)}${C.r} ${mark}${C.r} ${here ? C.text : ran ? C.text : C.ctx}${cut(t[n - 1] || "", w - 12)}${C.r}${here ? "  " + C.at + "← no test gets here" + C.r : ""}`);
    }
    out.push("", `${C.good}●${C.r}${C.faint} ran in some test   ${C.r}${C.at}○${C.r}${C.faint} no test runs it${C.r}`, "");
    if (g.input) {
      out.push(`${C.yours}✦ Claude's input${C.r}${C.ctx}, in ${g.input.spec}: ${C.r}${C.text}${g.input.name}${C.r}`);
      out.push(g.input.reached ? `${C.good}it reaches ${g.name}: it is in the tests below${C.r}` : `${C.at}it ran, but did not reach ${g.name}${g.input.error ? ": " + g.input.error : ""}${C.r}`);
    } else if (!g.mocked) out.push(`${C.faint}i: Claude writes an input into a spec that reaches this, and P traces it. It only has to run.${C.r}`);
  }
  return out.join("\n") + "\n";
}
// previews: every row's preview into <out>/<id>, : as _, for one width.
function previews(r, out) {
  const c = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
  mkdirSync(out, { recursive: true });
  const ids = [...c.gaps.map((g, i) => "g:" + i), ...c.tests.map((t, i) => "t:" + i)];
  for (const id of ids) writeFileSync(join(out, id.replace(":", "_")), preview(r, id, c));
}

// --- the walk's list and preview -------------------------------------------------------
// The list is the calls the test made into the change, in order, a row each
// (v:<i>); the line within a call is the preview's, moved by j, l, h and k.
// walk-prep renders it all at once, for a pane's width, into walks/: the
// rows, nav (a line a step: the step, its call, where j, l and h go, -1 for
// nowhere, and the file, as an index, and line it is on), a preview a step,
// and each file the walk goes through whole (file-<index>), which the screen
// scrolls through from one step to the next in the same file.
function callRows(steps) {
  const vs = visits(steps), out = [];
  vs.forEach((v, i) => {
    const again = vs.slice(0, i).some((u) => u.id === v.id && u.depth === v.depth && vs.slice(vs.indexOf(u) + 1, i).every((x) => x.depth > v.depth));
    const lines = steps.slice(v.first, v.last + 1).map((x) => x.line);
    const span = Math.min(...lines) === Math.max(...lines) ? `:${lines[0]}` : `:${Math.min(...lines)}–${Math.max(...lines)}`;
    const name = again ? `${C.faint}↩ ${C.r}${C.ctx}${v.fn}${C.r}` : `${C.text}${v.fn}${C.r}`;
    out.push(row(`${"  ".repeat(v.depth)}${name}${C.faint}${span}${C.r}`, steps[v.first].path, steps[v.first].line, "v:" + i));
  });
  return { vs, out };
}

function walkRows(r, ti, side) {
  const { steps } = walk(r, +ti, side);
  const { out } = callRows(steps);
  if (!steps.length) out.push(`${C.at}${side === "base" ? "at the base this test ran none of the change's old code" : "this test ran none of the change"}${C.r}` + "\t".repeat(11) + "gk-none");
  console.log(out.join("\n"));
}

function glossOf(r) {
  try {
    const croot = git("rev-parse", "--path-format=absolute", "--git-common-dir").trim() + "/git-alias-cache";
    const g = JSON.parse(readFileSync(`${croot}/symbols-gloss/${r.rev.base}-${r.rev.head}.json`, "utf8"));
    return new Map(g.symbols.map((s) => [s.id, s.does]));
  } catch { return new Map(); }
}

// render: step k's preview: where it is and what it was called with, pinned,
// over the code of its call with what each line set and what ran.
// around: that many lines of the file above and below the step's own, as
// the file draws them (codeRows), so the pane is full of code rather than
// a snippet over nothing; the head's line says which row of the code is
// the step's ("\x1epin N at K"), where the screen puts it.
function render(ctx, k, w, win, around = 0) {
  const { r, steps, vs, side, gloss, mockedNames } = ctx;
  const s = steps[k];
  // The line it is about: a tour's stop says (a function's name, say, where
  // its test first stopped on its first statement), else where it stopped.
  const at = (win && win[2]) || s.line;
  const vi = vs.findIndex((v) => k >= v.first && k <= v.last);
  // The calls it is in, the outermost dropped first when they do not fit.
  const all = [];
  for (let d = 0; d < s.depth; d++) for (let j = vi - 1; j >= 0; j--) if (vs[j].depth === d) { all.push(vs[j].fn); break; }
  const frames = all.slice();
  while (frames.length && [...frames, s.fn].join(" › ").length > w - 22) frames.shift();
  if (frames.length < all.length) frames.unshift("…");
  const where = frames.map((f) => C.ctx + f + C.r + C.faint + " › " + C.r).join("") + C.at + "\x1b[1m" + s.fn + C.r;
  const head = [where + `${C.faint}  ·  ${k + 1} of ${steps.length}${side === "base" ? "  ·  before the change" : ""}${C.r}`];
  // Where it goes next, said plainly, with the key that goes there.
  const nx = steps[k + 1];
  const key = (kk) => `${C.faint}   ${kk}${C.r}`;
  let next;
  if (!nx) next = `${C.at}■${C.r} ${C.text}the test is done with the change here${C.r}`;
  else if (nx.depth > s.depth) {
    let ov = null;
    for (let i = k + 1; i < steps.length; i++) if (steps[i].depth <= s.depth) { ov = steps[i]; break; }
    const over = !ov ? "" : ov.id === s.id && ov.depth === s.depth ? `over it to line ${ov.line}` : ov.depth < s.depth ? `over it and back out to ${ov.fn}` : `over it to ${ov.fn}`;
    next = `${C.at}↓${C.r} ${C.text}into ${C.r}${C.at}\x1b[1m${nx.fn}${C.r}` + key("l") + (over ? `${C.faint}   ·   ${over}   j${C.r}` : "");
  }
  else if (nx.depth < s.depth) next = `${C.at}↩${C.r} ${C.text}back out to ${C.r}${C.at}\x1b[1m${nx.fn}${C.r}${C.faint}  line ${nx.line}${C.r}` + key("j");
  else if (nx.id !== s.id) next = `${C.at}→${C.r} ${C.text}on to ${C.r}${C.at}\x1b[1m${nx.fn}${C.r}` + key("j");
  else next = `${C.at}→${C.r} ${C.text}line ${nx.line}${C.r}${nx.line < s.line ? C.faint + "  (loops back)" + C.r : ""}` + key("j");
  head.push(`${C.faint}next  ${C.r}` + next);
  // This call: from where its caller last had control to where it has it
  // again, the calls it makes in between left out.
  let lo0 = k, hi0 = k;
  while (lo0 > 0 && steps[lo0 - 1].depth >= s.depth) lo0--;
  while (hi0 + 1 < steps.length && steps[hi0 + 1].depth >= s.depth) hi0++;
  const src = text(side === "base" ? r.rev.base : r.rev.head, s.path);
  const vals = new Map(), ranHere = new Set(), here = new Map();
  let args = [];
  // A value goes on the line that declares or assigns its name, looked for
  // back from the pause that saw it to the call's start: a statement that
  // spans lines was paused in inside, and its first line is where it sets.
  const home = (name, from) => {
    const n = name.replace(/^.*\./, "");
    if (!/^[A-Za-z_$][\w$]*$/.test(n)) return from;
    const re = new RegExp("(const|let|var)\\s[^=]*\\b" + n + "\\b|(^|[^\\w$.])" + n + "\\s*(=[^=>]|\\+=|-=)");
    for (let l = from; l >= Math.max(s.def[0], from - 30); l--) if (re.test(src[l - 1] || "")) return l;
    return from;
  };
  // What each name holds when the line runs: what it was called with, and
  // what the lines before set.
  const known = new Map();
  for (let j = lo0; j <= hi0; j++) {
    // Its closures run deeper, under whatever calls them, but are its lines.
    if (steps[j].id === s.id) ranHere.add(steps[j].line);
    if (steps[j].id !== s.id || steps[j].depth !== s.depth) continue;
    if (j <= k) for (const [a, b] of steps[j].values) { const at = home(a, steps[j].line); if (!here.has(at)) here.set(at, []); here.get(at).push([a, b]); }
    if (steps[j].args.length) args = steps[j].args;
    if (j <= k) for (const [a, b] of [...(steps[j].outer || []), ...steps[j].args, ...(j < k ? steps[j].values : [])]) known.set(a, b);
  }
  // The line you are on says what it reads, as far down a path as the value
  // was kept (deps.resolvers, not all of deps), and then what it makes (⇒).
  const line0 = (src[at - 1] || "").replace(/(["'`]).*?\1/g, "");
  const reads = [];
  for (const m of line0.matchAll(/(?<![\w$.])([A-Za-z_$][\w$]*)((?:\??\.[A-Za-z_$][\w$]*)*)/g)) {
    if (!known.has(m[1])) continue;
    let path = m[1], v = known.get(m[1]);
    for (const f of m[2].split(/\??\./).slice(1)) {
      const x = isObj(v) && !v.a && v.p.find(([k]) => k === f);
      if (!x) break;
      path += "." + f; v = x[1];
    }
    // deps.now(): a method, not deps.
    if (m[2] && path === m[1] && isObj(v)) continue;
    // result = …: what the line sets, not reads (⇒, below).
    if (new RegExp("(^|[^\\w$.])" + path.replace(/[$.]/g, "\\$&") + "\\s*=[^=>]").test(line0)) continue;
    if (!reads.some(([p]) => p === path)) reads.push([path, v]);
  }
  // candidate.kind, not candidate as well.
  for (let i = reads.length - 1; i >= 0; i--) if (reads.some(([p]) => p.startsWith(reads[i][0] + "."))) reads.splice(i, 1);
  const made = (here.get(at) || []).filter(([a]) => !reads.some(([p]) => p === a));
  // A plain value beside the line, whole; an object named there (↓) and
  // opened, whole, under it.
  const says = [...reads.map(([a, b]) => a + " = " + (isObj(b) ? "↓" : full(b))), ...made.map(([a, b], i) => (i ? "" : "⇒ ") + a + " = " + (isObj(b) ? "↓" : full(b)))];
  if (says.length) vals.set(at, says.join("  ·  "));
  // Called with: its parameters, plain values whole; objects opened under the
  // call's first line.
  const first = !steps.slice(lo0, k).some((x) => x.id === s.id && x.depth === s.depth && x.fn === s.fn);
  if (args.length) {
    const lines = [""];
    for (const x of args.map(([a, b]) => a + " = " + (isObj(b) ? (first ? "↓" : shape(b)) : full(b)))) {
      if (lines[lines.length - 1] && width(lines[lines.length - 1] + "   " + x) > w - 13) lines.push("");
      lines[lines.length - 1] += (lines[lines.length - 1] ? "   " : "") + x;
    }
    head.push(...lines.map((l, i) => C.faint + (i ? "             " : "called with  ") + C.r + C.else + l + C.r));
  }
  const open = [];
  for (const [a, b] of [...(first ? args : []), ...reads, ...made]) if (isObj(b) && b.p.length && !open.some((l) => l.startsWith(C.ctx + a + C.r))) tree(a, b, "", w - 12, open, 60);
  const does = side === "head" ? gloss.get(s.id) : "";
  if (does) head.push(C.yours + "✦ " + C.r + C.ctx + cut(does, w - 3) + C.r);
  head.push(C.faint + "─".repeat(w) + C.r);
  const can = ctx.can(s.path);
  // The window: the call's lines, from its first to its last, and the line
  // with room around it when that is more than fits.
  const ran = [...ranHere];
  let lo = Math.max(s.def[0], Math.min(...ran) - 3), hi = Math.min(s.def[1], Math.max(...ran) + 3);
  if (hi - lo > 34) { lo = Math.max(s.def[0], s.line - 6); hi = Math.min(s.def[1], lo + 34); }
  if (win) [lo, hi] = win;
  const body = codeRows(r, side, s.path, w, lo - around, lo - 1), hk = hunks(r.rev, s.path);
  let atRow = 0;
  const paint = painted(side === "base" ? r.rev.base : r.rev.head, s.path);
  const oldPaint = side === "head" ? painted(r.rev.base, s.path) : null;
  const gut = (num, mark) => `${num} ${mark}${C.r} `;
  for (let n = lo; n <= hi; n++) {
    // What the change removed here, where the head has it no more.
    if (side === "head") for (const [on, ot] of hk.before.get(n) || []) {
      const code = cutA(oldPaint[on - 1] ?? ot, w - 9);
      body.push(gut(C.bad + String(on).padStart(5) + C.r, C.bad + "-") + under(code, MINUS) + "\x1b[0K" + C.r);
    }
    const tx = src[n - 1] ?? "", cur = n === at, did = ranHere.has(n);
    const goes = !cur && nx && nx.id === s.id && nx.depth === s.depth && n === nx.line;
    const add = side === "head" ? hk.added.has(n) : hk.removed.has(n);
    const skipped = !did && n > (s.start ?? s.def[0] - 1) && (can ? can.has(n) : add && !/^\s*(\/\/|\*|\/\*|[}\])]+[;,)]*\s*$|$)/.test(tx));
    const mark = cur ? C.at + "\x1b[1m▶" : goes ? C.at + "→" : did ? C.good + "●" : skipped ? C.faint + "○" : " ";
    const num = (add ? (side === "base" ? C.bad : C.good) : C.faint) + String(n).padStart(5) + C.r;
    const mockCall = [...tx.matchAll(/\b(\w+)\s*\(/g)].map((m) => m[1]).find((x) => mockedNames.has(x));
    let tail = "";
    if (cur && vals.has(n)) tail = C.else + "\x1b[3m" + vals.get(n) + C.r;
    else if (!cur && n < Math.max(at, s.line) && here.has(n)) {
      const room = w - 11 - width(tx);
      tail = C.else + "\x1b[3m" + here.get(n).map(([a, b]) => a + " = " + (a.length + 3 + full(b).length <= room ? full(b) : shape(b))).join("   ") + C.r;
    }
    if (mockCall) tail = C.at + "\x1b[3m← mocked by this test" + C.r;
    // The code as bat colors it, cut to leave the value room, then on the
    // change's ground, dim where this call skipped it, bold where it is.
    let code = cutA(paint[n - 1] ?? tx, w - 9);
    if (skipped) code = under(code, "\x1b[2m");
    if (cur) code = under(code, "\x1b[1m");
    // The value beside the code when both fit, else on a line of its own under it.
    const beside = tail && width(code) + width(tail) + 2 <= w - 9;
    const line = beside ? code + "  " + tail : code;
    if (cur) { body.push(under(gut(num, mark) + line, HERE) + "\x1b[0K" + C.r); atRow = body.length; }
    // What the change added on its ground, always: the same as the code
    // around the window (codeRows), so a function it wrote reads as one.
    else if (add) body.push(gut(num, mark) + under(line, side === "base" ? MINUS : PLUS) + "\x1b[0K" + C.r);
    else body.push(gut(num, mark) + line + C.r);
    if (tail && !beside) {
      const lead = (tx.match(/^\s*/) || [""])[0].length;
      const pad = " ".repeat(9 + Math.min(lead, 24));
      wrap(tail.replace(/\x1b\[[0-9;]*m/g, ""), w - width(pad) - 3).forEach((l, i) => {
        const under1 = pad + C.faint + (i ? "  " : "↳ ") + C.r + C.else + "\x1b[3m" + l + C.r;
        body.push(cur ? under(under1, HERE) + "\x1b[0K" + C.r : under1);
      });
    }
    // The values the line reads and sets, opened, in a box under it.
    if (cur && open.length) {
      const lead = " ".repeat(9);
      body.push(lead + C.faint + "┌" + "─".repeat(Math.max(4, w - 12)) + C.r);
      for (const l of open) body.push(lead + C.faint + "│ " + C.r + cutA(l, w - 12) + C.r);
      body.push(lead + C.faint + "└" + "─".repeat(Math.max(4, w - 12)) + C.r);
    }
  }
  body.push(...codeRows(r, side, s.path, w, hi + 1, hi + around));
  return `\x1epin ${head.length} at ${atRow}\n` + head.join("\n") + "\n" + body.join("\n") + "\n";
}

function walkPrep(r, ti, side, w) {
  const { t, steps } = walk(r, +ti, side);
  const { vs, out } = callRows(steps);
  const paths = [...new Set(steps.map((s) => s.path))];
  const base = join(r.dir, "walks", `${ti}-${side}`);
  mkdirSync(`${base}-${w}`, { recursive: true });
  writeFileSync(`${base}.rows`, out.join("\n") + (out.length ? "\n" : ""));
  // nav: step, its call, and the step j (over), l (into) and h (out) go to.
  const nav = steps.map((s, k) => {
    let over = -1, into = -1, outk = -1;
    for (let i = k + 1; i < steps.length; i++) if (steps[i].depth <= s.depth) { over = i; break; }
    if (k + 1 < steps.length && steps[k + 1].depth > s.depth) into = k + 1;
    for (let i = k + 1; i < steps.length; i++) if (steps[i].depth < s.depth) { outk = i; break; }
    return [k, vs.findIndex((v) => k >= v.first && k <= v.last), over, into, outk, paths.indexOf(s.path), s.line].join(" ");
  });
  writeFileSync(`${base}.nav`, nav.join("\n") + "\n");
  const ctx = context(r, t, steps, vs, side);
  steps.forEach((s, k) => writeFileSync(`${base}-${w}/${k}`, solid(render(ctx, k, w, null, AROUND), w)));
  paths.forEach((p, i) => writeFileSync(`${base}-${w}/file-${i}`, fileView(r, side, p, w)));
}
// codeRows: lines from..to of a file as the pane draws code no step is on
// (the gutter, the change's ground, what it removed), the same bytes
// wherever they are drawn: the file whole, and the code around a step's own
// lines, so the screen can scroll from one into the other without a row
// changing under it.
function codeRows(r, side, path, w, from, to) {
  const src = text(side === "base" ? r.rev.base : r.rev.head, path);
  const hk = hunks(r.rev, path);
  const paint = painted(side === "base" ? r.rev.base : r.rev.head, path);
  const oldPaint = side === "head" ? painted(r.rev.base, path) : null;
  const gut = (num, mark) => `${num} ${mark}${C.r} `;
  const body = [];
  for (let n = Math.max(1, from); n <= Math.min(src.length, to); n++) {
    if (side === "head") for (const [on, ot] of hk.before.get(n) || []) {
      body.push(gut(C.bad + String(on).padStart(5) + C.r, C.bad + "-") + under(cutA(oldPaint[on - 1] ?? ot, w - 9), MINUS) + "\x1b[0K" + C.r);
    }
    const add = side === "head" ? hk.added.has(n) : hk.removed.has(n);
    const num = (add ? (side === "base" ? C.bad : C.good) : C.faint) + String(n).padStart(5) + C.r;
    const code = cutA(paint[n - 1] ?? src[n - 1] ?? "", w - 9);
    body.push(add ? gut(num, " ") + under(code, side === "base" ? MINUS : PLUS) + "\x1b[0K" + C.r : gut(num, " ") + code + C.r);
  }
  return body;
}
// fileView: a file whole, for the scroll from one step to the next.
function fileView(r, side, path, w) {
  return solid(codeRows(r, side, path, w, 1, Infinity).join("\n") + "\n", w);
}
function context(r, t, steps, vs, side) {
  const cans = new Map();
  const mockedMods = new Set(mocks(r.specs[t.spec], r.rev.head));
  return { r, t, steps, vs, side, gloss: side === "head" ? glossOf(r) : new Map(),
    mockedNames: new Set(defs(r.rows).filter((d) => mockedMods.has(stem(d.path))).map((d) => d.name)),
    can: (p) => { if (!cans.has(p)) cans.set(p, breakable(r, side, p)); return cans.get(p); } };
}

// --- the tour ----------------------------------------------------------------------
// P's first screen: what the change sets out to do, then a few stops through
// it in reading order, each a sentence, its lines, and the values a test
// really had there. Claude picks the stops and says them. A big change is
// split first (tour-plan-prompt) into chapters, one behavior each, every
// changed file of code in one, each its own tour, written side by side and
// read on its own; a small one is one chapter. Files, in the run's directory:
// tour.plan.json the chapters ({intent, chapters: [{title, files, tests}]}),
// tour.c<i>.json a chapter's tour ({intent, stops}), tour.c<i>.q.json what a
// reader still could not answer from it, tour.c<i>.state while it is being
// written or checked, and tour.json all of it put together (tour-assemble),
// which the screen draws (tour-prep) and watches.
const LOCK = /(^|\/)(yarn\.lock|package-lock\.json|pnpm-lock\.yaml|Cargo\.lock|go\.sum)$/;
const codeFiles = (r) => git("diff", "--name-only", "--no-renames", r.rev.base, r.rev.head).split("\n").filter((f) => f && !TEST.test(f) && !LOCK.test(f));
const readJson = (f, d) => { try { return JSON.parse(readFileSync(f, "utf8")); } catch { return d; } };
function tourSize(r) {
  return git("diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", r.rev.base, r.rev.head, "--", ...codeFiles(r)).length;
}
function plan(r) {
  const p = readJson(join(r.dir, "tour.plan.json"), null);
  const all = codeFiles(r);
  if (!p || !p.chapters || !p.chapters.length) return { intent: "", chapters: [{ title: "", files: all, tests: [] }] };
  // Every file of code in a chapter: one the plan left out goes in the last.
  const seen = new Set();
  const chapters = p.chapters.map((c) => ({ ...c, files: (c.files || []).filter((f) => all.includes(f) && !seen.has(f) && seen.add(f)) }));
  chapters[chapters.length - 1].files.push(...all.filter((f) => !seen.has(f)));
  return { intent: p.intent || "", chapters };
}
function tourPlanDefault(r) {
  return JSON.stringify({ intent: "", chapters: [{ title: "", files: codeFiles(r), tests: [] }] }) + "\n";
}
// What the plan is given: the commits, each file of code with the symbols it
// changed, and each test with the files it reaches.
function tourPlanPrompt(r) {
  const cover = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
  const log = git("log", "--reverse", "--format=%s%n%b", `${r.rev.base}..${r.rev.head}`).slice(0, 6000);
  const stat = git("diff", "--numstat", "--no-renames", r.rev.base, r.rev.head, "--", ...codeFiles(r)).trim();
  const syms = new Map();
  for (const d of defs(r.rows)) if (d.change && d.change !== "same") { const l = syms.get(d.path) || []; l.push(`${d.name} (${d.change})`); syms.set(d.path, l); }
  const files = stat.split("\n").filter(Boolean).map((l) => { const [a, dl, f] = l.split("\t"); return `${f}  +${a} -${dl}${syms.has(f) ? "  " + syms.get(f).slice(0, 30).join(", ") : ""}`; }).join("\n");
  const tests = cover.tests.map((t, i) => `"${t.name}"  reaches ${[...new Set(walk(r, i, "head").steps.map((s) => s.path))].join(", ") || "nothing changed"}`).join("\n").slice(0, 40000);
  return `A code reviewer is about to be walked through a merge request too big for one short tour. Split it into chapters, each one behavior the change adds or changes that a reviewer can understand on its own: 2 to 6 of them, in the order they are best read.

Say first what the whole change sets out to do: two or three plain sentences.
For each chapter:
- title: a few words naming the behavior ("queued sends run as a child workflow").
- files: the files of code it covers, exactly as listed below. Every file below goes in exactly one chapter. Plumbing (build files, manifests, exports, config) can be its own last chapter, titled so.
- tests: the exact names of the tests below that exercise it.

The commits:
${log}

The files of code, with lines added and removed and the symbols changed:
${files}

The tests, and the files each reaches:
${tests}
`;
}
// What a chapter's tour is written from: its files' diff and what its tests
// ran of them, and where it sits among the others.
function tourPrompt(r, ci) {
  const cover = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
  const p = plan(r), ch = p.chapters[ci], many = p.chapters.length > 1;
  const files = new Set(ch.files);
  const log = git("log", "--reverse", "--format=%s%n%b", `${r.rev.base}..${r.rev.head}`).slice(0, 4000);
  let diff = ch.files.length ? git("diff", "-U4", "--no-color", "--no-ext-diff", "--no-renames", r.rev.base, r.rev.head, "--", ...ch.files) : "";
  if (diff.length > 80000) diff = diff.slice(0, 80000) + "\n[the rest of the diff is left out]";
  // Its tests (all, for one chapter), the ones that between them reach the
  // most of its lines first: each branch has its test (the timeout, the
  // error, the skip). Each as the calls it made into the chapter's files and
  // the values each line set.
  const named = (t) => !many || (ch.tests || []).some((n) => t.name === n || t.name.endsWith(n));
  const tests = cover.tests.map((t, i) => ({ t, i })).filter((x) => named(x.t))
    .map((x) => ({ ...x, steps: walk(r, x.i, "head").steps.filter((s) => files.has(s.path)) })).filter((x) => x.steps.length)
    .map((x) => ({ ...x, lines: new Set(x.steps.map((s) => s.path + ":" + s.line)) }));
  const left = new Set(tests.flatMap((x) => [...x.lines])), pick = [];
  while (pick.length < 20) {
    let best = null, gain = 0;
    for (const x of tests) { if (pick.includes(x)) continue; const g = [...x.lines].filter((l) => left.has(l)).length; if (g > gain) { best = x; gain = g; } }
    if (!best) break;
    pick.push(best); for (const l of best.lines) left.delete(l);
  }
  pick.sort((a, b) => a.i - b.i);
  const show = (v) => cut(full(v), 160);
  let budget = 30000;
  const ran = [];
  for (const { t, steps } of pick) {
    const out = [`test "${t.name}"`];
    for (const st of steps.slice(0, 80)) {
      out.push(`${"  ".repeat(st.depth + 1)}${st.fn} ${st.path}:${st.line}` + (st.args.length ? `  called with ${st.args.map(([a, b]) => a + " = " + show(b)).join(", ")}` : "") +
        (st.values.length ? `  then ${st.values.map(([a, b]) => a + " = " + show(b)).join(", ")}` : ""));
    }
    const s = out.join("\n");
    if (s.length > budget) break;
    ran.push(s); budget -= s.length;
  }
  const others = tests.filter((x) => !pick.includes(x) || !ran.some((s) => s.startsWith(`test "${x.t.name}"`))).map((x) => `test "${x.t.name}"`).join("\n");
  const gaps = cover.gaps.filter((g) => files.has(g.path)).map((g) => `${g.name} (${g.path}:${g.start}): ${g.why}`).join("\n");
  const where = many ? `This tour is chapter ${ci + 1} of ${p.chapters.length} of a tour of one merge request. The whole change: ${p.intent}
The chapters:
${p.chapters.map((c, i) => `${i + 1}. ${c.title}${i === ci ? "  (this one)" : ""}: ${c.files.join(", ")}`).join("\n")}
Write only this chapter, from its files. It must stand alone: a reader may read it first or alone. Another chapter's subject gets a phrase ("chapter 2 covers the retry") where it matters, never more.

` : "";
  return `You are walking a code reviewer through ${many ? "part of " : ""}a merge request so they understand what it sets out to do and how its code does it, as fast as possible and with as little thinking about navigation as possible. They will read your stops one after another, pressing a key for the next.

${where}First say what ${many ? "this part of the change" : "the change"} sets out to do: two or three plain sentences, the behavior it adds or changes, not a list of files.

Then pick the stops: ${many ? "3 to 10" : "5 to 15"}, in the order that tells the story best (usually the order the code runs in, entry point first). Each stop is one place in the changed code (not tests) and answers one question. For each:
- title: a few words, what happens there ("finds the resolver for the token").
- says: one to three plain sentences on what this code does and why it matters to the change. No restating the code token by token.
- path, start, end: the lines to show, at the head, at most 30 lines; focus: the line the stop is about, within them, marked for the reader: for a function, type or constant, the line with its name on it (export const awaitWithin = ..., not the line with its return type or its opening brace); for a decision inside one, the statement that makes it.
- test: the exact name of a test below that runs the focus line, when one does; its values are shown at the stop as proof. Else "".
- proves: when there is a test, one sentence on what that test shows about this code's behavior, with the real values ("with no resolver registered it logs and returns: resolver = undefined"). Else "".

The tour has to stand alone. The reader sees only it: your summary, then each stop's title, says, the lines you pick and the test values under them, one after another. They will not open a file, search, or run anything. When they finish the last stop they must understand what ${many ? "this part of the change" : "the change"} does and how, well enough to explain it. So:
- Explain a name before you lean on it. A type, helper, table, flag or constant the reader has not met yet is explained where it first appears, or gets a stop of its own first; order the stops so no stop uses a name a later stop introduces. Show a data shape (a type, a schema) at the stop where it first matters. A name from outside the change (an import) gets a phrase saying what it is.
- Back each branch with its own test where one exists: the timeout stop cites the test that times out, the skip stop the test that skips, with that test's values.
- Each stop follows from the one before; when the link is not obvious, say it ("Once the token is claimed, ...").
- Cover all of it. Every file below is in some stop. Plumbing (build files, package manifests, exports, a new flag's key) can share one stop near the end whose says names each and what it adds; show the lines of the one that matters most.
- End the story: the last stop says where the result goes and what is left out or for later, when the commits say.
Stop where the behavior is decided, not on glue. Do not invent values: use only the ones below.

The commits:
${log}

The diff of ${many ? "this chapter's" : "the"} code (tests left out):
${diff}

What the tests ran of it, test by test (a line a pause: the function, its file and line, what it was called with, what the line set; deeper is called from above):
${ran.join("\n\n") || "no test reaches it"}
${others ? "\nOther tests that reach it, left out for room:\n" + others + "\n" : ""}
Changed functions here no test runs:
${gaps || "none"}
`;
}
// tourAssemble: the plan and each chapter, as far as they have come, as one.
function tourAssemble(r) {
  const p = readJson(join(r.dir, "tour.plan.json"), null), f = (n) => join(r.dir, n);
  const t = { intent: "", planning: existsSync(f("tour.state")), chapters: [] };
  if (p) {
    const pp = plan(r);
    t.intent = pp.intent;
    t.chapters = pp.chapters.map((c, i) => {
      const got = readJson(f(`tour.c${i}.json`), null), q = readJson(f(`tour.c${i}.q.json`), null);
      const state = existsSync(f(`tour.c${i}.state`)) ? readFileSync(f(`tour.c${i}.state`), "utf8").trim() : "";
      return { title: c.title, files: c.files, intent: got ? got.intent : "", stops: got ? got.stops : [], questions: q ? q.questions : [], state };
    });
    if (!t.intent && t.chapters.length === 1) t.intent = t.chapters[0].intent;
  }
  const tmp = f(`tour.json.${process.pid}`);
  writeFileSync(tmp, JSON.stringify(t) + "\n");
  renameSync(tmp, f("tour.json"));
  for (const x of readdirSync(r.dir)) if (/^tour-\d+(\.\w+)?$/.test(x)) rmSync(join(r.dir, x), { recursive: true, force: true });
}
// readTour: tour.json, a tour from before chapters (its stops at the top)
// read as one chapter of them.
function readTour(r) {
  const t = JSON.parse(readFileSync(join(r.dir, "tour.json"), "utf8"));
  if (!t.chapters) return { intent: t.intent || "", planning: false, chapters: [{ title: "", files: codeFiles(r), intent: t.intent || "", stops: t.stops || [], questions: [], state: "" }] };
  return t;
}
// prose: Claude's sentences wrapped to w, a symbol in them drawn as code:
// what it put in backticks (the backticks dropped), and what reads as one
// though it did not (MESSAGE_READ, supportMessageId, OutreachSendEvent,
// error.status, send(), a file:line, a name the change defines).
const SYMBOL = /^([A-Z][A-Z0-9]*(_[A-Z0-9]+)+|[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*|[\w$]+(\.[\w$]+)+(\(\))?|[\w$]+\(\)|[\w./-]+\.[cm]?[jt]sx?(:\d+(-\d+)?)?)$/;
function prose(t, w, base, names) {
  const lines = [];
  let line = "", width0 = 0, inCode = false;
  for (const word of String(t || "").split(/\s+/).filter(Boolean)) {
    let out = "", vis = 0;
    word.split("`").forEach((part, i) => {
      if (i) inCode = !inCode;
      if (!part) return;
      const m = /^([^\w$]*)(.*?)([^\w$()]*)$/.exec(part);
      const core = m[2];
      const code = inCode || (core && !/^(e\.g|i\.e|etc)$/i.test(core) && (SYMBOL.test(core) || (names && core.length > 3 && names.has(core.replace(/\(\)$/, "")))));
      out += code ? (inCode ? C.else + part + base : m[1] + C.else + core + base + m[3]) : part;
      vis += [...part].length;
    });
    if (line && width0 + 1 + vis > w) { lines.push(base + line + C.r); line = ""; width0 = 0; }
    line += (line ? " " : "") + out; width0 += (width0 ? 1 : 0) + vis;
  }
  if (line) lines.push(base + line + C.r);
  return lines;
}
// tourPrep: the tour's rows and each row's preview, for a pane w wide, in
// out (the run's directory, else the page's own: tour-html).
function tourPrep(r, w, out = r.dir) {
  const tour = readTour(r);
  const cover = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
  const dir = join(out, `tour-${w}`);
  mkdirSync(dir, { recursive: true });
  const many = tour.chapters.length > 1, rows = [];
  const names = new Set(defs(r.rows).map((d) => d.name).filter(Boolean));
  const para = (t, c = C.text, ww = w - 2) => prose(t, ww, c, names);
  const one = (t, c) => para(t, c, 10000)[0] || "";
  const state = (c) => c.state === "writing" ? "Claude is writing it; it lands here by itself." : c.state === "checking" ? "A reader is checking it; what it cannot answer lands here as open questions." : "";
  // The reader's questions: {stop, says}, or a string from before they
  // had a stop; each is listed on the chapter and again at its stop.
  const ask = (q) => typeof q === "string" ? { stop: 0, says: q } : q;
  const asked = (qs) => qs.flatMap((q) => para(q.says, C.text, w - 4).map((l, j) => (j ? "  " : C.at + "? " + C.r) + l));
  const questions = (c) => c.questions && c.questions.length ? ["", C.at + "Still open after a close read" + C.r, ...asked(c.questions.map(ask).map((q) => q.stop ? { says: `Stop ${q.stop}: ${q.says}` } : q))] : [];
  // The first page: what it sets out to do, and every chapter's stops.
  rows.push(row(`${C.at}\x1b[1mwhat it sets out to do${C.r}`, "", "", "tour:0"));
  const intro = [C.at + "\x1b[1m" + "What it sets out to do" + C.r, ""];
  if (tour.planning) intro.push(C.faint + "Claude is splitting the change into chapters; they land here by themselves." + C.r);
  else if (tour.intent) intro.push(...para(tour.intent));
  tour.chapters.forEach((c, ci) => {
    intro.push("");
    if (many) intro.push(C.text + "\x1b[1m" + `${ci + 1}  ${c.title}` + C.r);
    if (!c.stops.length) intro.push(C.faint + (many ? "   " : "") + (state(c) || "no tour came back for it") + C.r);
    else c.stops.forEach((x, si) => intro.push(C.faint + (many ? "   " : "") + String(si + 1).padStart(3) + "  " + C.r + one(x.title, C.text)));
    if (!many) { if (c.stops.length && state(c)) intro.push("", C.faint + state(c) + C.r); intro.push(...questions(c)); }
  });
  if (cover.gaps.length) intro.push("", ...para(`${cover.gaps.length} changed function${cover.gaps.length === 1 ? "" : "s"} no test runs: ` + cover.gaps.map((g) => "`" + g.name + "`").join(", "), C.at));
  writeFileSync(join(dir, "0"), intro.join("\n") + "\n");
  const stopOf = stops(r, cover);
  tour.chapters.forEach((c, ci) => {
    const n = c.stops.length;
    if (many) {
      rows.push(row(`${C.text}\x1b[1m${ci + 1}  ${c.title}${C.r}` + (c.state === "writing" ? C.faint + "  being written" + C.r : ""), "", "", `tour:c${ci + 1}`));
      const page = [C.faint + `chapter ${ci + 1} of ${tour.chapters.length}` + C.r, C.at + "\x1b[1m" + c.title + C.r, ""];
      if (c.intent) page.push(...para(c.intent), "");
      if (state(c)) page.push(C.faint + state(c) + C.r, "");
      c.stops.forEach((x, si) => page.push(C.faint + String(si + 1).padStart(3) + "  " + C.r + one(x.title, C.text)));
      page.push(...questions(c));
      writeFileSync(join(dir, `c${ci + 1}`), page.join("\n") + "\n");
    }
    c.stops.forEach((x, si) => {
      const id = `${ci + 1}-${si + 1}`;
      rows.push(row(`${many ? "   " : ""}${C.faint}${String(si + 1).padStart(2)}${C.r}  ${one(x.title, C.text)}`, x.path, x.focus, "tour:" + id));
      // Where it is, short: the screen shows its whole path over the preview.
      const head = [C.faint + (many ? `${ci + 1}.${si + 1}  ${c.title}  ·  ` : `${si + 1} of ${n}  ·  `) + `${x.path.split("/").pop()}:${x.focus}` + C.r, "", ...para(x.title, C.at + "\x1b[1m"), ...para(x.says), ""];
      // The values: the test it names, else the first that stops on the line.
      const { ti, k, body, at } = stopOf(x, w, AROUND);
      if (k >= 0 && x.proves) head.push(...para(x.proves, C.text, w - 4).map((l, j) => (j ? "  " : C.good + "✓ " + C.r) + l), ...wrap(`from the test "${cover.tests[ti].name}"`, w - 4).map((l) => C.faint + "  " + l + C.r));
      else if (k >= 0) head.push(C.faint + `values from the test "${cover.tests[ti].name}"` + C.r);
      else head.push(C.faint + "no test stops here, so no values" + C.r);
      const here = (c.questions || []).map(ask).filter((q) => q.stop === si + 1);
      if (here.length) head.push("", ...asked(here));
      head.push(C.faint + "─".repeat(w) + C.r);
      writeFileSync(join(dir, id), `\x1epin ${head.length} at ${at}\n` + head.join("\n") + "\n" + solid(body, w));
      // What enter and s need: where it is, and the test and step to step from.
      writeFileSync(join(dir, `${id}.at`), `${x.path} ${x.focus} ${k >= 0 ? ti : -1} ${k}\n`);
    });
  });
  // Each stop's file whole (files/<path, / as %>), which the screen scrolls
  // through from one stop to the next in the same file.
  mkdirSync(join(dir, "files"), { recursive: true });
  for (const p of new Set(tour.chapters.flatMap((c) => c.stops.map((x) => x.path))))
    writeFileSync(join(dir, "files", p.replace(/\//g, "%")), fileView(r, "head", p, w));
  writeFileSync(join(out, "tour.rows"), rows.join("\n") + "\n");
}
// stops: a stop's lines as the walk draws them, with the values of the test
// it names (else the first that stops on its line): {ti, k, body}, k -1 and
// the bare lines when no test stops there.
function stops(r, cover) {
  const walks = new Map();
  const walkOf = (ti) => { if (!walks.has(ti)) { const { t, steps } = walk(r, ti, "head"); const vs = visits(steps); walks.set(ti, { steps, ctx: context(r, t, steps, vs, "head") }); } return walks.get(ti); };
  const stepAt = (ti, x) => {
    const { steps } = walkOf(ti);
    let k = steps.findIndex((s) => s.path === x.path && s.line === x.focus);
    // Else where it first stopped in the function the line is in (a pause is
    // on a statement, never on a name): not another function the lines show.
    if (k < 0) k = steps.findIndex((s) => s.path === x.path && s.def[0] <= x.focus && x.focus <= s.def[1] && s.line >= x.start && s.line <= x.end);
    return k;
  };
  return (x, w, around = 0) => {
    let ti = cover.tests.findIndex((t) => t.name === x.test || (x.test && t.name.endsWith(x.test)));
    let k = ti >= 0 ? stepAt(ti, x) : -1;
    if (k < 0) for (ti = 0; ti < cover.tests.length && (k = stepAt(ti, x)) < 0; ti++);
    if (k < 0) return { ti: -1, k: -1, ...plain(r, x, w, around) };
    const out = render(walkOf(ti).ctx, k, w, [x.start, x.end, x.focus], around).split("\n");
    const m = /^\x1epin (\d+) at (\d+)/.exec(out[0]) || [0, 0, 0];
    return { ti, k, body: out.slice(1 + +m[1]).join("\n"), at: +m[2] };
  };
}
// --- the tour as a page ------------------------------------------------------------
// tour-html: the tour as one HTML page, to post on the MR (git-trace
// --attach) or open in a browser: P's screens themselves. The tour's rows
// and panes are the ones tour-prep draws for the screen, a's are git-trace
// --tests's, and a test's walk is walk-prep's, all at PAGE_W columns; the
// page moves between them as otis-symbols does: the head holding still while
// its words change a row at a time, the code scrolling through the file to
// another line of it (what hangs under the old line folding first, what
// hangs under the new unfolding after), and pushing to another file. The
// address names the screen and the row or step, so a link opens on it. One
// file, nothing loaded from elsewhere. The theme's colors are marker codes
// here (git-trace sets them: OTIS_T_* as 38;5;201 and on) that become the
// page's classes, light or dark as the reader's system is.
const esc = (t) => String(t ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const MARK = { 201: "at", 202: "good", 203: "bad", 204: "yours", 205: "text", 206: "ctx", 207: "faint", 208: "else" };
// ansiRow: one drawn line as HTML spans.
function ansiRow(line) {
  let out = "", open = false;
  const st = { fg: "", bg: "", b: false, dim: false, it: false };
  const span = () => { if (open) out += "</span>"; const cls = [st.fg, st.bg, st.b && "b", st.dim && "dim", st.it && "it"].filter(Boolean); open = cls.length > 0; if (open) out += `<span class="${cls.join(" ")}">`; };
  for (const m of line.matchAll(/\x1b\[([0-9;]*)([mK])|([^\x1b]+)/g)) {
    if (m[3]) { out += esc(m[3]); continue; }
    if (m[2] === "K") continue;
    const c = (m[1] || "0").split(";").map(Number);
    for (let i = 0; i < c.length; i++) {
      const n = c[i];
      if (n === 0) Object.assign(st, { fg: "", bg: "", b: false, dim: false, it: false });
      else if (n === 1) st.b = true; else if (n === 2) st.dim = true; else if (n === 3) st.it = true;
      else if (n === 22) { st.b = false; st.dim = false; } else if (n === 23) st.it = false; else if (n === 39) st.fg = ""; else if (n === 49) st.bg = "";
      else if ((n >= 30 && n <= 37) || (n >= 90 && n <= 97)) st.fg = "c" + n;
      else if (n === 38 && c[i + 1] === 5) { st.fg = MARK[c[i + 2]] ? "m-" + MARK[c[i + 2]] : ""; i += 2; }
      else if (n === 38 && c[i + 1] === 2) { st.fg = ""; i += 4; }
      else if (n === 48 && c[i + 1] === 2) { st.bg = c[i + 2] === 1 ? "bg-add" : c[i + 2] === 4 ? "bg-del" : ""; i += 4; }
      else if (n === 48 && c[i + 1] === 5) { st.bg = c[i + 2] === 58 ? "bg-here" : ""; i += 2; }
    }
    span();
  }
  return open ? out + "</span>" : out;
}
// A line of code's gutter, as otis-symbols's xkeys reads it: L<n> a line
// of code, R<n> a line the change removed.
const GUTTER = /^(?:\x1b\[[0-9;]*m)*( *)(\d+)\x1b\[0m(?:\x1b\[[0-9;]*m)* (.*)$/;
const PAGE_W = 110;
function tourHtml(r, title, url) {
  const out = mkdtempSync(join(tmpdir(), "otis-tour-")), cols = process.env.FZF_PREVIEW_COLUMNS;
  process.env.FZF_PREVIEW_COLUMNS = String(PAGE_W);
  try {
    tourPrep(r, PAGE_W, out);
    const dir = join(out, `tour-${PAGE_W}`);
    // Every drawn row once (S, and SK its gutter's key), the rows and panes
    // as indexes into it.
    const S = [], SK = [], seen = new Map(), raw = new Map();
    const s = (line) => {
      let i = raw.get(line);
      if (i !== undefined) return i;
      const h = ansiRow(line);
      i = seen.get(h);
      if (i === undefined) {
        const m = GUTTER.exec(line);
        i = S.length; S.push(h); seen.set(h, i);
        SK.push(m ? (/^(?:\x1b\[[0-9;]*m)*-/.test(m[3]) ? "R" : "L") + m[2] : 0);
      }
      raw.set(line, i);
      return i;
    };
    const lines = (t) => t.replace(/\n$/, "").split("\n");
    const listOf = (rows) => rows.map((l) => { const f = l.split("\t"); return { show: s(f[0]), id: f[11] || "" }; });
    // Each file a pane shows, whole, which the scroll goes through.
    const files = {}, fileAt = {};
    const file = (path) => {
      if (!files[path]) {
        files[path] = lines(fileView(r, "head", path, PAGE_W)).map(s);
        fileAt[path] = new Map();
        files[path].forEach((i, g) => { if (SK[i] && !fileAt[path].has(SK[i])) fileAt[path].set(SK[i], g); });
      }
      return files[path];
    };
    // page: a pane as drawn: h its pinned rows (-1 none), at the row of its
    // line, b its rows, where it shows its file's own rows as they are in
    // the file a run [from, count]; path and line where its code is, open
    // the line ⏎ opens.
    const page = (text, at0) => {
      let ls = lines(text), h = -1, at = 0;
      const m = /^\x1epin (\d+)(?: at (\d+))?/.exec(ls[0]);
      if (m) { h = +m[1]; at = +(m[2] || 0); ls = ls.slice(1); }
      // A line of words over the code wider than the pane wrapped, as the
      // screen's wrap does, in its first color: the page's rows are one row
      // high.
      ls = ls.flatMap((l, i) => {
        if (width(l) <= PAGE_W || GUTTER.test(l) || (h >= 0 && i >= h)) return [l];
        const pre = (/^(?:\x1b\[[0-9;]*m)*/.exec(l) || [""])[0], lead = /^ */.exec(l.replace(/\x1b\[[0-9;]*m/g, ""))[0];
        const parts = wrap(l.replace(/\x1b\[[0-9;]*m/g, "").trim(), PAGE_W, lead).map((x) => pre + x + C.r);
        if (i < h) h += parts.length - 1;
        return parts;
      });
      const ids = ls.map(s), b = [], p = { h, b };
      const F = at0 && at0.path ? file(at0.path) : null, fat = F && fileAt[at0.path];
      for (let i = 0; i < ids.length;) {
        const g = F && SK[ids[i]] ? fat.get(SK[ids[i]]) : undefined;
        let n = 0;
        if (g !== undefined) while (i + n < ids.length && F[g + n] === ids[i + n]) n++;
        if (n >= 2) { b.push([g, n]); i += n; } else { b.push(ids[i]); i++; }
      }
      if (at) p.at = at;
      if (at0) Object.assign(p, at0);
      return p;
    };
    // The tour.
    const tour = { list: listOf(lines(readFileSync(join(out, "tour.rows"), "utf8"))), pages: {} };
    for (const x of tour.list) {
      x.id = x.id.replace(/^tour:/, "");
      const f = join(dir, x.id + ".at");
      let at0 = null;
      if (existsSync(f)) { const [path, line, ti, k] = readFileSync(f, "utf8").trim().split(" "); at0 = { path, line: +line, open: [path, +line], ti: +ti, k: +k }; }
      tour.pages[x.id] = page(readFileSync(join(dir, x.id), "utf8"), at0);
    }
    // a: the changed code no test runs, and every test.
    const c = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
    const tests = { list: listOf(testRows(r)), pages: {} };
    for (const { id } of tests.list) {
      if (id.startsWith("g:")) { const g = c.gaps[+id.slice(2)]; tests.pages[id] = page(preview(r, id, c), { open: [g.path, g.start] }); }
      else if (id.startsWith("t:")) tests.pages[id] = page(preview(r, id, c), { open: [c.specs[c.tests[+id.slice(2)].spec].path, 1] });
    }
    // Each test's walk: its calls down the side, a pane a step, and where
    // j (over), l (into) and h (out) go from each: nav, [call, j, l, h].
    const walks = c.tests.map((t, ti) => {
      const { t: tt, steps } = walk(r, ti, "head");
      const { vs, out: calls } = callRows(steps);
      const list = listOf(calls);
      if (!steps.length) list.push({ show: s(C.at + "this test ran none of the change" + C.r), id: "gk-none" });
      const ctx = steps.length ? context(r, tt, steps, vs, "head") : null;
      const nav = steps.map((st, k) => {
        let over = -1, into = -1, outk = -1;
        for (let i = k + 1; i < steps.length; i++) if (steps[i].depth <= st.depth) { over = i; break; }
        if (k + 1 < steps.length && steps[k + 1].depth > st.depth) into = k + 1;
        for (let i = k + 1; i < steps.length; i++) if (steps[i].depth < st.depth) { outk = i; break; }
        return [vs.findIndex((v) => k >= v.first && k <= v.last), over, into, outk];
      });
      const pages = steps.map((st, k) => page(solid(render(ctx, k, PAGE_W, null, AROUND), PAGE_W), { path: st.path, line: st.line, open: [st.path, st.line] }));
      return { name: t.name, list, nav, pages };
    });
    const key = r.dir.split("/").pop();
    const what = /^\d+$/.test(key) ? "!" + key : key.replace(/^b-/, "").replace(/%/g, "/");
    const blob = url ? url.replace(/\/-\/merge_requests\/\d+.*$/, "") + "/-/blob/" + r.rev.head : "";
    const listW = Math.min(64, Math.max(36, ...[...tour.list, ...tests.list].map((x) => [...S[x.show].replace(/<[^>]*>/g, "")].length + 4)));
    const data = { S, SK, files, tour, tests, walks, blank: s(""), seam: s("  " + C.faint + "─".repeat(PAGE_W - 4) + C.r), W: PAGE_W, blob, what, title, url, listW };
    return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title || "Walkthrough of " + what)}</title>
<style>${TOUR_CSS}</style></head><body>
<div id="screen">
<div id="list"><div class="lh"></div><div id="rows"></div></div>
<div id="pane"><div id="crumb"></div><div id="stage"><div id="head"></div><div id="code"></div></div></div>
<div id="foot"><span id="keys"></span><span id="flash" class="m-good"></span></div>
</div>
<script type="application/octet-stream" id="data">${gzipSync(JSON.stringify(data), { level: 9 }).toString("base64")}</script>
<script>${TOUR_JS}</script></body></html>
`;
  } finally {
    if (cols === undefined) delete process.env.FZF_PREVIEW_COLUMNS; else process.env.FZF_PREVIEW_COLUMNS = cols;
    rmSync(out, { recursive: true, force: true });
  }
}
// The screens in the page: otis-symbols's transitions (xpush, xcode, xhead,
// xwhen, xmerge, xspread), done again over the same panes, with the rows
// moving smoothly rather than a whole row at a time.
const TOUR_JS = String.raw`
// The data comes gzipped (it is mostly the same rows over and over).
(async function () {
const bytes = Uint8Array.from(atob(document.getElementById("data").textContent), function (c) { return c.charCodeAt(0); });
const D = JSON.parse(await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"))).text());
const S = D.S, SK = D.SK, XFW = 0.22;
const LINE = /^[LR]\d+(#\d+)?$/;
const $ = function (q) { return document.querySelector(q); };
const rowsEl = $("#rows"), headEl = $("#head"), codeEl = $("#code"), crumbEl = $("#crumb"), flashEl = $("#flash");
const clamp = function (x) { return x < 0 ? 0 : x > 1 ? 1 : x; };
const ease = function (t) { return (1 - Math.cos(Math.PI * clamp(t))) / 2; };
const esc = function (t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); };
let rowPx = 20, ph = 40, X = null, raf = 0, scr = null;
const stack = [];

// --- the geometry: a terminal's, sized to the window --------------------------------
function measure() {
  const probe = document.createElement("span");
  probe.textContent = "0".repeat(100);
  probe.style.cssText = "position:absolute;visibility:hidden;font:100px var(--mono);white-space:pre";
  document.body.appendChild(probe);
  const ratio = probe.getBoundingClientRect().width / 100 / 100;
  probe.remove();
  let font = innerWidth / (D.listW + 3 + D.W + 2) / ratio;
  const narrow = font < 10.5;
  if (narrow) font = Math.min(13, Math.max(8, innerWidth / (D.W + 4) / ratio));
  font = Math.min(15, Math.floor(font * 4) / 4);
  rowPx = Math.round(font * 1.5);
  ph = Math.max(12, Math.floor(innerHeight / rowPx) - 2);
  const st = document.documentElement.style;
  st.setProperty("--font", font + "px");
  st.setProperty("--row", rowPx + "px");
  st.setProperty("--listw", D.listW + "ch");
  st.setProperty("--w", D.W + "ch");
  st.setProperty("--ph", ph);
  document.body.classList.toggle("narrow", narrow);
}

// --- panes ---------------------------------------------------------------------------
// keysOf: a key a row, as xkeys: a line's gutter, what hangs under a line
// that line's key and the row, a row over the code h: and the row; a row
// there twice gets #2 and on.
function keysOf(rows) {
  let last = "";
  const seen = new Map();
  return rows.map(function (i) {
    const k = SK[i] ? (last = SK[i]) : last ? last + "+" + i : "h:" + i;
    const n = (seen.get(k) || 0) + 1;
    seen.set(k, n);
    return n > 1 ? k + "#" + n : k;
  });
}
const fileKeys = {};
function fileOf(path) {
  if (!fileKeys[path]) fileKeys[path] = keysOf(D.files[path]);
  return { rows: D.files[path], keys: fileKeys[path] };
}
// rowsOf: a page's rows, its runs of its file taken from the file.
function rowsOf(p) {
  if (!p._rows) {
    const F = p.path ? D.files[p.path] : null, rows = [];
    p.b.forEach(function (t) { if (typeof t === "number") rows.push(t); else for (let j = 0; j < t[1]; j++) rows.push(F[t[0] + j]); });
    p._rows = rows; p._keys = keysOf(rows);
  }
  return p;
}
const EMPTY = { h: -1, b: [] };
// headpad: a head as tall as most heads of the screen, blank rows over its rule.
function headpad(rows, hfix) {
  const want = Math.min(hfix, ph - 2 - 6);
  if (rows.length >= want) return rows;
  const pad = [];
  for (let i = rows.length; i < want; i++) pad.push(D.blank);
  const last = rows[rows.length - 1];
  return last !== undefined && S[last].indexOf("─") >= 0 ? rows.slice(0, -1).concat(pad, [last]) : rows.concat(pad);
}
// split: a page as the screen shows it: its head, its code (body, keys),
// the row of the code its line is on (NK), and where it lands (NL), that
// line a third of the way down.
function split(p, hfix) {
  rowsOf(p);
  if (p.h < 0) return { p: p, head: [], body: p._rows, keys: p._keys, NK: 0, NL: 0 };
  const np = Math.min(p.h, ph - 2 - 6), head = headpad(p._rows.slice(0, np), hfix);
  const NK = p.at ? p.at + p.h - np : 0, F = Math.floor((ph - 2 - head.length) / 3);
  return { p: p, head: head, body: p._rows.slice(np), keys: p._keys.slice(np), NK: NK, NL: Math.max(0, NK - 1 - F) };
}
function crumbOf(p) {
  if (!p.open) return "";
  const path = p.open[0], cut = path.lastIndexOf("/");
  return '<span class="m-faint">' + esc(path.slice(0, cut + 1)) + '</span><span class="m-text">' + esc(path.slice(cut + 1)) + '</span><span class="m-faint">:' + p.open[1] + "</span>";
}

// --- screens -------------------------------------------------------------------------
// A screen: its rows down the side, the row the cursor is on, and the page
// the pane shows. The tour's and a's move a row at a time; a walk's moves
// a step at a time, its cursor on the step's call.
// hfixOf: the height most heads pad to, the median (otis-symbols's hfixof).
function hfixOf(pages) {
  const hs = [];
  for (const k in pages) if (pages[k].h >= 0) hs.push(pages[k].h);
  hs.sort(function (a, b) { return a - b; });
  return hs.length ? hs[(hs.length + 1 >> 1) - 1] : 0;
}
const hint = function (k, t) { return '<span class="m-at">' + k + '</span> <span class="m-faint">' + t + "</span>"; };
const DOT = '   <span class="m-faint">·</span>   ';
function tourScreen(row) {
  return { kind: "tour", list: D.tour.list, row: row, poff: -1, hfix: hfixOf(D.tour.pages),
    title: '<span class="m-text">tour ' + esc(D.what) + "</span>" + (D.title ? '  <span class="m-faint">' + esc(D.title) + "</span>" : ""),
    keys: (D.blob ? hint("⏎", "open the line on GitLab") + DOT : "") + hint("j", "next stop") + "  " + hint("k", "back") + "  " + hint("s", "step through its test line by line") + "  " + hint("a", "every test and what none runs") + "  " + hint("y", "copy a link"),
    page: function () { return D.tour.pages[this.list[this.row].id]; },
    cursor: function () { return this.row; },
    hash: function () { return this.list[this.row].id; } };
}
function testsScreen(row) {
  return { kind: "tests", list: D.tests.list, row: row, poff: -1, hfix: 0,
    title: '<span class="m-text">walk ' + esc(D.what) + "</span>",
    keys: hint("⏎", "walk the test") + "  " + hint("j", "down") + "  " + hint("k", "up") + "  " + hint("q", "back to the tour") + "  " + hint("y", "copy a link"),
    page: function () { return D.tests.pages[this.list[this.row].id] || EMPTY; },
    cursor: function () { return this.row; },
    hash: function () { return "a:" + this.list[this.row].id; } };
}
function walkScreen(ti, k) {
  const w = D.walks[ti];
  if (!w.hfix) w.hfix = hfixOf(w.pages);
  return { kind: "walk", w: w, ti: ti, k: k, hist: [], poff: -1, hfix: w.hfix, list: w.list,
    title: '<span class="m-text b">' + esc(w.name) + "</span>",
    keys: (D.blob ? hint("⏎", "open the line on GitLab") + DOT : "") + hint("j", "next line") + "  " + hint("l", "step into") + "  " + hint("h", "step out") + "  " + hint("k", "back") + "  " + hint("q", "back") + "  " + hint("y", "copy a link"),
    page: function () { return this.w.pages[this.k] || EMPTY; },
    cursor: function () { return this.w.nav[this.k] ? this.w.nav[this.k][0] : 0; },
    hash: function () { return "w" + this.ti + ":" + this.k; } };
}
const selectable = function (x) { return x.id && x.id.indexOf("gk-") !== 0; };
let lrs = [];
function showList() {
  $(".lh").innerHTML = scr.title;
  $("#keys").innerHTML = scr.keys;
  rowsEl.innerHTML = scr.list.map(function (x, i) { return '<div class="lr' + (selectable(x) ? "" : " gk") + '" data-i="' + i + '"><span class="bar">▌</span> ' + S[x.show] + "</div>"; }).join("");
  lrs = Array.prototype.slice.call(rowsEl.children);
  rowsEl.scrollTop = 0;
}
function cursor() {
  const c = scr.cursor();
  lrs.forEach(function (d, i) { d.classList.toggle("on", i === c); });
  const d = lrs[c];
  if (d) {
    const box = rowsEl.getBoundingClientRect(), r = d.getBoundingClientRect();
    if (r.top < box.top) rowsEl.scrollTop -= box.top - r.top;
    else if (r.bottom > box.bottom) rowsEl.scrollTop += r.bottom - box.bottom;
  }
  history.replaceState(null, "", "#" + scr.hash());
}

// --- drawing -------------------------------------------------------------------------
// A frame: {crumb: [[html, alpha]...], head: [{i, a}], hr: the head's rows,
// code: [{i, y, a, bar}]}, y in rows from the top of the code.
const pools = { head: [], code: [] };
function rowDiv(pool, parent, n) {
  while (pool.length <= n) { const d = document.createElement("div"); d.className = "r"; parent.appendChild(d); pool.push(d); }
  return pool[n];
}
const stripped = {};
function barHtml(i) {
  if (stripped[i] === undefined) stripped[i] = S[i].replace(/\bbg-(here|add|del)\b/g, "");
  return stripped[i];
}
function groundOf(i) { return S[i].indexOf("bg-add") >= 0 ? "var(--add)" : S[i].indexOf("bg-del") >= 0 ? "var(--del)" : "transparent"; }
function paint(pool, parent, items) {
  let n = 0;
  for (const it of items) {
    if (!it) { n++; continue; }
    const d = rowDiv(pool, parent, n++);
    const k = it.bar === undefined ? "" + it.i : "b" + it.i;
    if (d._k !== k) { d._k = k; d.innerHTML = it.bar === undefined ? S[it.i] : barHtml(it.i); }
    d.style.transform = "translateY(" + (it.y * rowPx).toFixed(2) + "px)";
    d.style.opacity = it.a >= 0.999 ? "" : it.a.toFixed(3);
    d.style.background = it.bar === undefined ? "" : "color-mix(in srgb, var(--here) " + (it.bar * 100).toFixed(1) + "%, " + (it.ground || "transparent") + ")";
    d.style.display = "";
  }
  for (; n < pool.length; n++) if (pool[n].style.display !== "none") pool[n].style.display = "none";
}
let crumbK = "";
function draw(f) {
  const k = f.crumb.map(function (c) { return c[0]; }).join("\u0000");
  if (k !== crumbK) { crumbK = k; crumbEl.innerHTML = f.crumb.map(function (c) { return '<div class="c">' + c[0] + "</div>"; }).join(""); }
  Array.prototype.forEach.call(crumbEl.children, function (c, j) { c.style.opacity = f.crumb[j][1]; });
  paint(pools.head, headEl, f.head.map(function (h, j) { return h && { i: h.i, a: h.a, y: j }; }));
  codeEl.style.top = (f.hr * rowPx).toFixed(2) + "px";
  paint(pools.code, codeEl, f.code.filter(function (c) { return c.y > -1 && c.y < ph; }));
}
// landed: the pane at rest, scrolled as the screen is.
function landed() {
  const p = scr.page(), v = split(p, scr.hfix), H = ph - 2 - v.head.length;
  if (scr.poff < 0) scr.poff = v.NL;
  return { crumb: [[crumbOf(p), 1]], head: v.head.map(function (i) { return { i: i, a: 1 }; }), hr: v.head.length,
    code: v.body.slice(scr.poff, scr.poff + H + 1).map(function (i, j) { return { i: i, y: j, a: 1 }; }) };
}

// --- transitions ---------------------------------------------------------------------
// headFrame: the head's words changing a row at a time, top down, each row
// out and its new words in; it grows before the new words come, or shrinks
// after the old have gone, so the code under it never jumps.
function headFrame(HO, HN, xh) {
  const ho = HO.length, hn = HN.length, n = Math.max(ho, hn);
  const hr = hn < ho ? (xh < 0.8 ? ho : ho + (hn - ho) * (xh - 0.8) * 5) : (xh >= 0.2 ? hn : ho + (hn - ho) * xh * 5);
  const out = [];
  for (let i = 0; i < Math.ceil(hr); i++) {
    const tl = clamp((xh - 0.5 * i / (n > 1 ? n - 1 : 1)) / 0.3), o = HO[i], w = HN[i];
    if (o !== undefined && o === w) out.push({ i: w, a: 1 });
    else if (tl < 0.5) out.push(o === undefined ? null : { i: o, a: 1 - tl * 2 });
    else out.push(w === undefined ? null : { i: w, a: tl * 2 - 1 });
  }
  return { head: out, hr: hr };
}
function crumbFrame(a, b, xh) {
  return a === b ? [[b, 1]] : [[a, xh < 0.5 ? 1 - xh * 2 : 0], [b, xh < 0.5 ? 0 : xh * 2 - 1]];
}
// push: to another file or a page with no code. When both have a head it
// holds while its words change and the code under it goes up and away, the
// new code following it in, a rule between (down with k); else the whole
// pane goes and the new one follows, head and all.
function push(from, to, dir, ca, cb) {
  let H = ph - 2, HO = [], HN = [], old, nu;
  if (from.head.length && to.head.length) {
    HO = from.head; HN = to.head; H -= to.head.length;
    old = from.body.slice(from.poff); nu = to.body.slice(to.poff);
  } else {
    old = from.head.concat(from.body.slice(from.poff)); nu = to.head.concat(to.body.slice(to.poff));
  }
  old = old.slice(0, H); nu = nu.slice(0, H);
  const XK = dir > 0 ? old.concat([D.seam], nu) : nu.concat([D.seam], old);
  const a0 = dir > 0 ? 0 : nu.length + 1, a1 = dir > 0 ? old.length + 1 : 0;
  return { dur: 0.6, frame: function (t) {
    const xe = ease(t / 0.6), pos = a0 + (a1 - a0) * xe, h = headFrame(HO, HN, xe);
    return { crumb: crumbFrame(ca, cb, xe), head: h.head, hr: h.hr, code: XK.map(function (i, j) { return { i: i, y: j - pos, a: 1 }; }) };
  } };
}
// spread: the file whole from its row g0 to g1 with a pane's rows in place
// of its lines there.
function spread(R, K, F, g0, g1) {
  const at = new Map();
  K.forEach(function (k, i) { if (LINE.test(k)) at.set(k, i); });
  const rows = [], keys = [];
  let own = false;
  for (let g = g0; g <= g1; g++) {
    const fk = F.keys[g];
    if (LINE.test(fk)) {
      if (at.has(fk)) {
        own = true;
        let i = at.get(fk);
        rows.push(R[i]); keys.push(K[i]);
        for (i++; i < K.length && !at.has(K[i]); i++) { rows.push(R[i]); keys.push(K[i]); }
      } else { own = false; rows.push(F.rows[g]); keys.push(fk); }
    } else if (!own) { rows.push(F.rows[g]); keys.push(fk); }
  }
  return { rows: rows, keys: keys };
}
// merge: the two as one list: K the keys, O and N each one's row, F 0
// both, 1 the old alone, 2 the new alone. A line of code only one has is
// the same file around it, so it stays: only what hangs under lines folds.
function merge(o, n) {
  const inN = new Map();
  n.keys.forEach(function (k, j) { inN.set(k, j); });
  const M = { K: [], O: [], N: [], F: [] };
  let i = 0, j = 0;
  const add = function (k, a, b, f) { M.K.push(k); M.O.push(a); M.N.push(b); M.F.push(f); };
  while (i < o.keys.length || j < n.keys.length) {
    if (i < o.keys.length && j < n.keys.length && o.keys[i] === n.keys[j]) { add(o.keys[i], o.rows[i], n.rows[j], 0); i++; j++; }
    else if (i < o.keys.length && (j >= n.keys.length || !inN.has(o.keys[i]) || inN.get(o.keys[i]) < j)) { add(o.keys[i], o.rows[i], null, 1); i++; }
    else { add(n.keys[j], null, n.rows[j], 2); j++; }
  }
  for (let k = 0; k < M.K.length; k++) {
    if (!M.F[k] || !LINE.test(M.K[k])) continue;
    if (M.F[k] === 1) M.N[k] = M.O[k]; else M.O[k] = M.N[k];
    M.F[k] = 0;
  }
  return M;
}
// when: when each row folds or unfolds: a wave out from the anchor, those
// within a pane of it spread evenly over the whole, the rest at the end.
function when(M, anchor) {
  const H = ph - 2, T = M.K.map(function () { return 0; }), near = [];
  for (let i = 0; i < M.K.length; i++) {
    if (!M.F[i]) continue;
    const d = Math.abs(i - anchor);
    if (d <= H) near.push([d, i]); else T[i] = 1 - XFW;
  }
  near.sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
  near.forEach(function (x, k) {
    const r = near.length > 1 ? k / (near.length - 1) : 0;
    T[x[1]] = M.F[x[1]] === 1 ? XFW + (1 - XFW) * r : (1 - XFW) * r;
  });
  return T;
}
// held: the row to hold still, from row a at y: the nearest row both show,
// counting the rows only this side shows (side 1 the old, 2 the new).
function held(M, a, y, side) {
  while (a < M.K.length && M.F[a] !== 0) { if (M.F[a] === side) y++; a++; }
  return [a, y];
}
// code: the scroll to another line of the same file, as an editor would,
// one thing at a time: what hangs under the old lines fades and folds away
// (A), the lines move together to where the new line lands, the bar going
// off the old line and on to the new as they pass (B), and what hangs under
// the new lines unfolds while the lines' marks change in place (C).
function code(from, to, la, lb, ca, cb) {
  const F = fileOf(to.p.path), H = ph - 2 - to.head.length;
  const LA = "L" + la, LB = "L" + lb;
  if (from.keys.indexOf(LA) < 0 || to.keys.indexOf(LB) < 0 || F.keys.indexOf(LA) < 0 || F.keys.indexOf(LB) < 0) return null;
  const ok = from.keys.filter(function (k) { return LINE.test(k); }), nk = to.keys.filter(function (k) { return LINE.test(k); });
  const gi = function (k) { return F.keys.indexOf(k); };
  const gs = [ok[0], ok[ok.length - 1], nk[0], nk[nk.length - 1], LA, LB].map(gi).filter(function (g) { return g >= 0; });
  const g0 = Math.min.apply(null, gs), g1 = Math.max.apply(null, gs);
  const M = merge(spread(from.body, from.keys, F, g0, g1), spread(to.body, to.keys, F, g0, g1));
  const fa = M.K.indexOf(LA), fb = M.K.indexOf(LB);
  if (fa < 0 || fb < 0) return null;
  // Held rows: the old line where it is shown (else the top row), the new
  // line where it lands (else the top row).
  let yA = from.keys.indexOf(LA) - from.poff, A0 = fa;
  if (yA < 0 || yA >= H) { A0 = M.K.indexOf(from.keys[from.poff]); yA = 0; }
  let yB = to.keys.indexOf(LB) - to.poff, A1 = fb;
  if (yB < 0 || yB >= H) { A1 = M.K.indexOf(to.keys[to.poff]); yB = 0; }
  if (A0 < 0 || A1 < 0) return null;
  const h0 = held(M, A0, yA, 1), h1 = held(M, A1, yB, 2);
  A0 = h0[0]; yA = h0[1]; A1 = h1[0]; yB = h1[1];
  if (A0 >= M.K.length || A1 >= M.K.length) return null;
  const TA = when(M, A0), TC = when(M, A1);
  const V = [];
  for (let i = 0; i < M.K.length; i++) if (!M.F[i]) V.push(i);
  const top0 = V.indexOf(A0) - yA, top1 = V.indexOf(A1) - yB, dist = Math.abs(top1 - top0);
  const nold = M.F.filter(function (f) { return f === 1; }).length, nnew = M.F.filter(function (f) { return f === 2; }).length;
  // Folding and unfolding as long as there is to fold; a few rows go
  // quickly, a long way at a pace to follow.
  const dA = nold ? 0.2 + Math.min(nold, 12) * 0.025 : 0;
  let dB = 0.5 + Math.min(dist, 900) / 700;
  if (dist && 0.1 + 0.06 * dist < dB) dB = 0.1 + 0.06 * dist;
  if (dist === 0) dB = fa !== fb ? 0.3 : 0;
  const dC = 0.3 + Math.min(nnew, 12) * 0.02, dur = dA + dB + dC;
  const gA = groundOf(F.rows[gi(LA)]), gB = groundOf(F.rows[gi(LB)]);
  return { dur: dur, frame: function (t) {
    let ph_, xe;
    if (t < dA) { ph_ = "A"; xe = ease(t / dA); }
    else if (t < dA + dB) { ph_ = "B"; xe = ease((t - dA) / dB); }
    else { ph_ = "C"; xe = ease((t - dA - dB) / dC); }
    const xh = ease(t / Math.min(dur || 1, 0.6)), hd = headFrame(from.head, to.head, xh);
    // Row i now: its content, alpha, height and bar.
    const row = function (i) {
      const f = M.F[i];
      let r;
      if (f === 1) {
        if (ph_ !== "A") return null;
        r = { i: M.O[i], a: clamp((TA[i] - XFW * 0.4 - xe) / (XFW * 0.6)), h: clamp((TA[i] - xe) / (XFW * 0.4)) };
      } else if (f === 2) {
        if (ph_ !== "C") return null;
        r = { i: M.N[i], a: clamp((xe - TC[i] - XFW * 0.4) / (XFW * 0.6)), h: clamp((xe - TC[i]) / (XFW * 0.4)) };
      } else if (ph_ === "C" && M.O[i] !== M.N[i]) {
        r = xe < 0.5 ? { i: M.O[i], a: 1 - 0.25 * clamp((xe - 0.25) / 0.25), h: 1 } : { i: M.N[i], a: 0.75 + 0.25 * clamp((xe - 0.5) / 0.25), h: 1 };
      } else r = { i: ph_ === "C" ? M.N[i] : M.O[i], a: 1, h: 1 };
      if (i === fa || i === fb) {
        let b;
        if (fa === fb) b = 1;
        else if (i === fa) b = ph_ === "A" ? 1 : ph_ === "B" ? clamp(1 - 2 * xe) : 0;
        else b = ph_ === "A" ? 0 : ph_ === "B" ? clamp(2 * xe - 1) : 1;
        r.bar = b; r.ground = i === fa ? gA : gB;
      }
      return r.h > 0 ? r : null;
    };
    const out = [], Hc = ph - 2 - hd.hr;
    if (ph_ === "B") {
      const top = top0 + (top1 - top0) * xe;
      for (let k = Math.max(0, Math.floor(top) - 1); k < V.length && k - top < Hc + 1; k++) { const r = row(V[k]); if (r) { r.y = k - top; out.push(r); } }
    } else {
      const A = ph_ === "A" ? A0 : A1, yH = ph_ === "A" ? yA : yB;
      const a = row(A) || { i: M.N[A], a: 1, h: 1 };
      a.y = yH; out.push(a);
      let y = yH;
      for (let i = A - 1; i >= 0 && y > -1; i--) { const r = row(i); if (!r) continue; y -= r.h; r.y = y; out.push(r); }
      y = yH + a.h;
      for (let i = A + 1; i < M.K.length && y < Hc + 1; i++) { const r = row(i); if (!r) continue; r.y = y; y += r.h; out.push(r); }
    }
    return { crumb: crumbFrame(ca, cb, xh), head: hd.head, hr: hd.hr, code: out };
  } };
}

// --- moving --------------------------------------------------------------------------
function tick(now) {
  raf = 0;
  if (!X) return;
  const t = (now - X.t0) / 1000;
  if (t >= X.dur) { land(); return; }
  draw(X.frame(t));
  raf = requestAnimationFrame(tick);
}
function land() {
  if (!X) return;
  X = null;
  if (raf) cancelAnimationFrame(raf);
  raf = 0;
  draw(landed());
}
// move: change: the cursor, the step or the screen, at once; the pane
// moving there from what it shows, forward (1) or back (-1).
function move(change, dir) {
  land();
  const was = scr, fp = scr.page(), from = split(fp, scr.hfix);
  from.poff = scr.poff;
  change();
  const tp = scr.page();
  if (scr === was && tp === fp) return;
  if (scr !== was) showList();
  cursor();
  const to = split(tp, scr.hfix);
  if (scr.poff < 0) scr.poff = to.NL;
  to.poff = scr.poff;
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) { draw(landed()); return; }
  X = (fp.path && tp.path && fp.path === tp.path && code(from, to, fp.line, tp.line, crumbOf(fp), crumbOf(tp))) || push(from, to, dir, crumbOf(fp), crumbOf(tp));
  X.t0 = performance.now();
  raf = requestAnimationFrame(tick);
}
// row: the cursor down (1) or up (-1) to the next row it can be on.
function row(dir, to) {
  let i = to === undefined ? scr.row + dir : to;
  while (i >= 0 && i < scr.list.length && !selectable(scr.list[i])) i += dir;
  if (i < 0 || i >= scr.list.length || i === scr.row) return;
  move(function () { scr.row = i; scr.poff = -1; }, i > scr.row ? 1 : -1);
}
// step: a walk's j (over), l (into), h (out) and k (back).
function step(key) {
  const n = scr.w.nav[scr.k];
  if (!n) return;
  const j = key === "j" ? n[1] : key === "l" ? (n[2] >= 0 ? n[2] : n[1]) : key === "h" ? n[3] : scr.hist.length ? scr.hist[scr.hist.length - 1] : -1;
  if (j < 0) {
    flash({ j: "that was its last line in this call; h goes out", l: "that was its last line in this call; h goes out", h: "the test called this one", k: "nowhere to go back to" }[key], true);
    return;
  }
  move(function () { if (key === "k") scr.hist.pop(); else scr.hist.push(scr.k); scr.k = j; scr.poff = -1; }, key === "j" || key === "l" ? 1 : -1);
}
function enter(s) { move(function () { stack.push(scr); scr = s; }, 1); }
function back() { if (stack.length) move(function () { scr = stack.pop(); }, -1); }
function scroll(n) {
  if (X) land();
  const v = split(scr.page(), scr.hfix), max = Math.max(0, v.body.length - (ph - 2 - v.head.length));
  const p = Math.max(0, Math.min(max, scr.poff + n));
  if (p !== scr.poff) { scr.poff = p; draw(landed()); }
}
let flashT = 0;
function flash(t, warn) {
  flashEl.textContent = "   " + t;
  flashEl.className = warn ? "m-at" : "m-good";
  clearTimeout(flashT);
  flashT = setTimeout(function () { flashEl.textContent = ""; }, 2000);
}
function openLine() {
  const p = scr.page();
  if (D.blob && p.open) open(D.blob + "/" + p.open[0] + "#L" + p.open[1], "_blank");
}
document.addEventListener("keydown", function (e) {
  if (e.metaKey || e.altKey || (e.ctrlKey && !/^[du]$/.test(e.key))) return;
  const half = Math.floor((ph - 2) / 2), k = e.key, walk = scr.kind === "walk";
  let done = true;
  if (e.ctrlKey) scroll(k === "d" ? half : -half);
  else if (walk && /^[jklh]$/.test(k)) step(k);
  else if (walk && (k === "ArrowDown" || k === "ArrowUp")) step(k === "ArrowDown" ? "j" : "k");
  else if (!walk && (k === "j" || k === "ArrowDown")) row(1);
  else if (!walk && (k === "k" || k === "ArrowUp")) row(-1);
  else if (!walk && (k === "g" || k === "Home")) row(1, 0);
  else if (!walk && (k === "G" || k === "End")) row(-1, scr.list.length - 1);
  else if (k === "PageDown") scroll(half);
  else if (k === "PageUp") scroll(-half);
  else if (k === "q" || k === "Escape") back();
  else if (k === "y") navigator.clipboard.writeText(location.href).then(function () { flash("a link to this is copied"); });
  else if (scr.kind === "tour" && k === "a") enter(testsScreen(firstRow(D.tests.list, 0)));
  else if (scr.kind === "tour" && k === "s") {
    const p = scr.page();
    if (p.ti === undefined) flash("s steps through a stop's test; this one is the overview", true);
    else if (p.ti < 0) flash("no test stops here, so there is nothing to step through", true);
    else enter(walkScreen(p.ti, p.k));
  } else if (k === "Enter") {
    const id = scr.kind === "tests" ? scr.list[scr.row].id : "";
    if (id.indexOf("t:") === 0) enter(walkScreen(+id.slice(2), 0));
    else openLine();
  } else done = false;
  if (done) e.preventDefault();
});
rowsEl.addEventListener("click", function (e) {
  const d = e.target.closest(".lr");
  if (!d) return;
  const i = +d.dataset.i;
  if (scr.kind !== "walk") { if (selectable(scr.list[i]) && i !== scr.row) row(i > scr.row ? 1 : -1, i); return; }
  const k = scr.w.nav.findIndex(function (n) { return n[0] === i; });
  if (k >= 0 && k !== scr.k) move(function () { scr.hist.push(scr.k); scr.k = k; scr.poff = -1; }, k > scr.k ? 1 : -1);
});
let wheel = 0;
$("#pane").addEventListener("wheel", function (e) {
  e.preventDefault();
  wheel += e.deltaY;
  const n = Math.trunc(wheel / rowPx);
  if (n) { wheel -= n * rowPx; scroll(n); }
}, { passive: false });
addEventListener("resize", function () { land(); measure(); scr.poff = -1; draw(landed()); });
function firstRow(list, i) { while (i < list.length && !selectable(list[i])) i++; return i < list.length ? i : 0; }
// Where the address says: a tour row (its id), a's row (a:<id>), a step of
// a test's walk (w<test>:<step>), each with what q goes back to under it.
function open0() {
  const h = decodeURIComponent(location.hash.slice(1));
  const tr = D.tour.list.findIndex(function (x) { return x.id === h; });
  scr = tourScreen(tr >= 0 ? tr : 0);
  let m = /^a:(.*)$/.exec(h);
  if (m) { const i = D.tests.list.findIndex(function (x) { return x.id === m[1]; }); stack.push(scr); scr = testsScreen(i >= 0 ? i : firstRow(D.tests.list, 0)); }
  m = /^w(\d+):(\d+)$/.exec(h);
  if (m && D.walks[+m[1]]) {
    const ti = +m[1], i = D.tests.list.findIndex(function (x) { return x.id === "t:" + ti; });
    stack.push(scr); stack.push(testsScreen(i >= 0 ? i : firstRow(D.tests.list, 0)));
    scr = walkScreen(ti, Math.min(+m[2], Math.max(0, D.walks[ti].pages.length - 1)));
  }
}
measure();
open0();
showList();
cursor();
draw(landed());
})();
`;
const TOUR_CSS = `
:root { --ground: #f7f7f5; --ink: #1d2126; --soft: #4d5560; --faint: #8a919c; --rule: #d9dcdf; --sel: #ebe7da;
  --pass: #1b7a47; --fail: #bb2d23; --open: #946300; --link: #1f5fbf; --else: #0b6e79; --yours: #7b3fb3;
  --add: #e3f1e5; --del: #f8e5e2; --here: #f6e2a8;
  --k1: #b3261e; --k2: #1b7a3a; --k3: #8a5f00; --k4: #1f5fbf; --k5: #8f3db8; --k6: #0b6e79; --k7: #6f7682;
  --mono: "SF Mono", ui-monospace, Menlo, "JetBrains Mono", Consolas, monospace; }
@media (prefers-color-scheme: dark) { :root {
  --ground: #16181b; --ink: #e3e1da; --soft: #a9adb4; --faint: #6c717a; --rule: #2c3036; --sel: #2a2a25;
  --pass: #8fc47a; --fail: #ef7a6c; --open: #e0b24e; --link: #86b1f5; --else: #6fc6cf; --yours: #c79bf2;
  --add: #1d2e22; --del: #3a211e; --here: #4a3a12;
  --k1: #ef7a6c; --k2: #9fcf7c; --k3: #e0b24e; --k4: #86b1f5; --k5: #d59cf5; --k6: #6fc6cf; --k7: #8a919c; } }
* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; overflow: hidden; background: var(--ground); color: var(--ink); }
body { font: var(--font, 13px)/var(--row, 20px) var(--mono); font-variant-ligatures: none; -webkit-font-smoothing: antialiased; }
#screen { position: fixed; inset: 0; display: grid; grid-template: calc(var(--row) * var(--ph)) 1fr / calc(var(--listw) + 2ch) 1fr; }
#list { display: flex; flex-direction: column; min-height: 0; border-right: 1px solid var(--rule); }
.lh { height: calc(var(--row) * 2); padding: calc(var(--row) * 0.5) 2ch 0; white-space: pre; overflow: hidden; text-overflow: ellipsis; }
#rows { flex: 1; min-height: 0; overflow: hidden; padding-top: var(--row); }
.lr { height: var(--row); white-space: pre; overflow: hidden; cursor: pointer; padding-right: 1ch; }
.lr .bar { visibility: hidden; color: var(--open); }
.lr.on { background: var(--sel); }
.lr.on .bar { visibility: visible; }
.lr.gk { cursor: default; }
.lr:hover:not(.on):not(.gk) { background: color-mix(in srgb, var(--sel) 45%, transparent); }
#pane { position: relative; min-width: 0; overflow: hidden; padding-left: 2ch; }
#crumb { position: relative; height: var(--row); }
#crumb .c { position: absolute; inset: 0; white-space: pre; }
#stage { position: absolute; left: 2ch; top: calc(var(--row) * 2); height: calc(var(--row) * (var(--ph) - 2)); width: var(--w); overflow: hidden; }
#head, #code { position: absolute; left: 0; right: 0; }
#head { top: 0; height: 100%; }
#code { bottom: 0; overflow: hidden; }
.r { position: absolute; top: 0; left: 0; width: var(--w); height: var(--row); white-space: pre; will-change: transform, opacity; }
.r > span { display: inline-block; height: 100%; vertical-align: top; }
#foot { grid-column: 1 / -1; border-top: 1px solid var(--rule); padding: calc(var(--row) * 0.25) 2ch 0; white-space: pre; overflow: hidden; }
#foot a { text-decoration: none; } #foot a:hover { text-decoration: underline; }
.b { font-weight: 700; } .dim { opacity: 0.55; } .it { font-style: italic; }
.bg-add { background: var(--add); } .bg-del { background: var(--del); } .bg-here { background: var(--here); }
.m-at { color: var(--open); } .m-good { color: var(--pass); } .m-bad { color: var(--fail); } .m-yours { color: var(--yours); }
.m-text { color: var(--ink); } .m-ctx { color: var(--soft); } .m-faint { color: var(--faint); } .m-else { color: var(--else); }
.c31, .c91 { color: var(--k1); } .c32, .c92 { color: var(--k2); } .c33, .c93 { color: var(--k3); } .c34, .c94 { color: var(--k4); }
.c35, .c95 { color: var(--k5); } .c36, .c96 { color: var(--k6); } .c30, .c90, .c37, .c97 { color: var(--k7); }
body.narrow #screen { grid-template-columns: 0 1fr; }
body.narrow #list { display: none; }
body.narrow #pane { overflow-x: auto; }
`;
// tourText: a chapter as its reader sees it, stop after stop, plain.
function tourText(r, ci) {
  const tour = readTour(r);
  tourPrep(r, 100);
  const c = tour.chapters[ci];
  const page = (id) => readFileSync(join(r.dir, "tour-100", id), "utf8").replace(/\x1b\[[0-9;]*[mK]/g, "").replace(/^\x1epin \d+\n/, "");
  const out = [`What ${tour.chapters.length > 1 ? "this part of the change" : "the change"} sets out to do\n\n${c.intent}\n\n${c.stops.map((x, i) => `${String(i + 1).padStart(3)}  ${x.title}`).join("\n")}\n`];
  c.stops.forEach((x, si) => out.push(`=== stop ${si + 1} ===\n` + page(`${ci + 1}-${si + 1}`)));
  return out.join("\n");
}
// tourMissing: a chapter's files' added lines no stop of it shows, a run a
// line, as path:first-last and its first line; not blank lines.
function tourMissing(r, ci) {
  const c = readTour(r).chapters[ci];
  const out = [];
  for (const f of c.files) {
    const src = text(r.rev.head, f), shown = new Set();
    for (const x of c.stops) if (x.path === f) for (let n = x.start; n <= x.end; n++) shown.add(n);
    const left = [...hunks(r.rev, f).added].filter((n) => !shown.has(n) && (src[n - 1] || "").trim()).sort((a, b) => a - b);
    for (let i = 0; i < left.length; ) {
      let j = i;
      while (j + 1 < left.length && left[j + 1] - left[j] <= 2) j++;
      out.push(`${f}:${left[i]}-${left[j]}  ${(src[left[i] - 1] || "").trim().slice(0, 80)}`);
      i = j + 1;
    }
  }
  return out.join("\n") + (out.length ? "\n" : "");
}
// plain: a stop's lines with no test at them: the code, the change's lines marked.
function plain(r, x, w, around = 0) {
  const paint = painted(r.rev.head, x.path), hk = hunks(r.rev, x.path);
  // The code as the file draws it, the stop's line marked: {body, at}.
  const rows = codeRows(r, "head", x.path, w, Math.min(x.start, x.focus) - around, x.focus);
  const num = (hk.added.has(x.focus) ? C.good : C.faint) + String(x.focus).padStart(5) + C.r;
  rows[rows.length - 1] = under(`${num} ${C.at}\x1b[1m▶${C.r} ` + cutA(paint[x.focus - 1] ?? "", w - 9), HERE) + "\x1b[0K" + C.r;
  const at = rows.length;
  rows.push(...codeRows(r, "head", x.path, w, x.focus + 1, Math.max(x.end, x.focus) + around));
  return { body: rows.join("\n") + "\n", at };
}

// --- targets ---------------------------------------------------------------------------
function targets(tbl, side) {
  const by = new Map();
  for (const d of defs(table(tbl))) {
    const rr = range(d, side || "head");
    if (!rr) continue;
    const s = by.get(d.path) || new Set();
    for (let n = rr[0]; n <= rr[1]; n++) s.add(n);
    by.set(d.path, s);
  }
  console.log(JSON.stringify([...by].map(([src, s]) => ({ src, lines: [...s].sort((a, b) => a - b) }))));
}

switch (cmd) {
  case "targets": targets(args[0], args[1]); break;
  case "cover": cover(run(args[0])); break;
  case "split": split(run(args[0]), args[1] || "head"); break;
  case "rows": rows(run(args[0])); break;
  case "preview": process.stdout.write(preview(run(args[0]), args[1] || "")); break;
  case "previews": previews(run(args[0]), args[1]); break;
  case "walk-rows": walkRows(run(args[0]), args[1], args[2] || "head"); break;
  case "walk-prep": walkPrep(run(args[0]), args[1], args[2] || "head", +args[3] || 100); break;
  case "tour-size": console.log(tourSize(run(args[0]))); break;
  case "tour-plan-prompt": process.stdout.write(tourPlanPrompt(run(args[0]))); break;
  case "tour-plan-default": process.stdout.write(tourPlanDefault(run(args[0]))); break;
  case "tour-prompt": process.stdout.write(tourPrompt(run(args[0]), +args[1] || 0)); break;
  case "tour-assemble": tourAssemble(run(args[0])); break;
  case "tour-prep": tourPrep(run(args[0]), +args[1] || 100); break;
  case "tour-html": process.stdout.write(tourHtml(run(args[0]), args[1] || "", args[2] || "")); break;
  case "tour-text": process.stdout.write(tourText(run(args[0]), +args[1] || 0)); break;
  case "tour-missing": process.stdout.write(tourMissing(run(args[0]), +args[1] || 0)); break;
  default: process.stderr.write("walk.mjs: targets, cover, rows, preview, walk-rows, walk-prep or a tour-* command\n"); process.exit(2);
}
