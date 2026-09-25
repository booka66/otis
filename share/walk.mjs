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
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

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
  console.log(out.join("\n"));
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
    } else if (!g.mocked) out.push(`${C.faint}w: Claude writes an input into a spec that reaches this, and P traces it. It only has to run.${C.r}`);
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
// rows, nav (a line a step: the step, its call, and where j, l and h go, -1
// for nowhere) and a preview a step, so moving is a cat and nothing else.
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
function render(ctx, k, w, win) {
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
  const body = [], hk = hunks(r.rev, s.path);
  const paint = painted(side === "base" ? r.rev.base : r.rev.head, s.path);
  const oldPaint = side === "head" ? painted(r.rev.base, s.path) : null;
  const gut = (num, mark) => `${num} ${mark}${C.r} `;
  // A definition the change wrote whole is all new: no ground to tell it by,
  // its line numbers say so.
  const whole = side === "head" && Array.from({ length: s.def[1] - s.def[0] + 1 }, (_, i) => s.def[0] + i).every((n) => hk.added.has(n) || !(src[n - 1] || "").trim());
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
    if (cur) body.push(under(gut(num, mark) + line, HERE) + "\x1b[0K" + C.r);
    else if (add && !whole) body.push(gut(num, mark) + under(line, side === "base" ? MINUS : PLUS) + "\x1b[0K" + C.r);
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
  return `\x1epin ${head.length}\n` + head.join("\n") + "\n" + body.join("\n") + "\n";
}

function walkPrep(r, ti, side, w) {
  const { t, steps } = walk(r, +ti, side);
  const { vs, out } = callRows(steps);
  const base = join(r.dir, "walks", `${ti}-${side}`);
  mkdirSync(`${base}-${w}`, { recursive: true });
  writeFileSync(`${base}.rows`, out.join("\n") + (out.length ? "\n" : ""));
  // nav: step, its call, and the step j (over), l (into) and h (out) go to.
  const nav = steps.map((s, k) => {
    let over = -1, into = -1, outk = -1;
    for (let i = k + 1; i < steps.length; i++) if (steps[i].depth <= s.depth) { over = i; break; }
    if (k + 1 < steps.length && steps[k + 1].depth > s.depth) into = k + 1;
    for (let i = k + 1; i < steps.length; i++) if (steps[i].depth < s.depth) { outk = i; break; }
    return [k, vs.findIndex((v) => k >= v.first && k <= v.last), over, into, outk].join(" ");
  });
  writeFileSync(`${base}.nav`, nav.join("\n") + "\n");
  const ctx = context(r, t, steps, vs, side);
  steps.forEach((s, k) => writeFileSync(`${base}-${w}/${k}`, render(ctx, k, w)));
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
  for (const x of readdirSync(r.dir)) if (/^tour-\d+(\.done)?$/.test(x)) rmSync(join(r.dir, x), { recursive: true, force: true });
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
// tourPrep: the tour's rows and each row's preview, for a pane w wide.
function tourPrep(r, w) {
  const tour = readTour(r);
  const cover = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
  const dir = join(r.dir, `tour-${w}`);
  mkdirSync(dir, { recursive: true });
  const many = tour.chapters.length > 1, rows = [];
  const names = new Set(defs(r.rows).map((d) => d.name).filter(Boolean));
  const para = (t, c = C.text, ww = w - 2) => prose(t, ww, c, names);
  const one = (t, c) => para(t, c, 10000)[0] || "";
  const state = (c) => c.state === "writing" ? "Claude is writing it; it lands here by itself." : c.state === "checking" ? "A reader is checking it; what it cannot answer lands here as open questions." : "";
  const questions = (c) => c.questions && c.questions.length ? ["", C.at + "Still open after a close read" + C.r, ...c.questions.flatMap((q) => para(q, C.text, w - 4).map((l, j) => (j ? "  " : C.at + "? " + C.r) + l))] : [];
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
      const { ti, k, body } = stopOf(x, w);
      if (k >= 0 && x.proves) head.push(...para(x.proves, C.text, w - 4).map((l, j) => (j ? "  " : C.good + "✓ " + C.r) + l), ...wrap(`from the test "${cover.tests[ti].name}"`, w - 4).map((l) => C.faint + "  " + l + C.r));
      else if (k >= 0) head.push(C.faint + `values from the test "${cover.tests[ti].name}"` + C.r);
      else head.push(C.faint + "no test stops here, so no values" + C.r);
      head.push(C.faint + "─".repeat(w) + C.r);
      writeFileSync(join(dir, id), `\x1epin ${head.length}\n` + head.join("\n") + "\n" + body);
      // What enter and s need: where it is, and the test and step to step from.
      writeFileSync(join(dir, `${id}.at`), `${x.path} ${x.focus} ${k >= 0 ? ti : -1} ${k}\n`);
    });
  });
  writeFileSync(join(r.dir, "tour.rows"), rows.join("\n") + "\n");
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
  return (x, w) => {
    let ti = cover.tests.findIndex((t) => t.name === x.test || (x.test && t.name.endsWith(x.test)));
    let k = ti >= 0 ? stepAt(ti, x) : -1;
    if (k < 0) for (ti = 0; ti < cover.tests.length && (k = stepAt(ti, x)) < 0; ti++);
    if (k < 0) return { ti: -1, k: -1, body: plain(r, x, w) };
    const out = render(walkOf(ti).ctx, k, w, [x.start, x.end, x.focus]).split("\n");
    const pinned = +(/^\x1epin (\d+)/.exec(out[0]) || [0, 0])[1];
    return { ti, k, body: out.slice(1 + pinned).join("\n") };
  };
}
// --- the tour as a page ------------------------------------------------------------
// tour-html: the tour as one HTML page, to post on the MR (git-trace
// --attach) or open in a browser: what it sets out to do, its chapters and
// stops in order, each stop's sentences and its code as the walk draws it,
// values and all, and what is still open. One file, nothing loaded from
// elsewhere, light or dark as the reader's system is. The code is drawn by
// the same code as the screen, with the theme's colors swapped for marker
// codes (git-trace sets them: OTIS_T_* as 38;5;201 and on) that become the
// page's classes here.
const esc = (t) => String(t ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
function proseHtml(t, names) {
  return String(t || "").split("`").map((part, i) => i % 2 ? `<code>${esc(part)}</code>` : esc(part).split(/(\s+)/).map((word) => {
    const m = /^([^\w$]*)(.*?)([^\w$()]*)$/.exec(word);
    const core = m[2].replace(/&amp;|&lt;|&gt;|&quot;/g, "x");
    return core && !/^(e\.g|i\.e|etc)$/i.test(core) && (SYMBOL.test(core) || (core.length > 3 && names.has(core.replace(/\(\)$/, "")))) ? `${m[1]}<code>${m[2]}</code>${m[3]}` : word;
  }).join("")).join("");
}
const MARK = { 201: "at", 202: "good", 203: "bad", 204: "yours", 205: "text", 206: "ctx", 207: "faint", 208: "else" };
function ansiHtml(text) {
  return text.split("\n").map((line) => {
    let out = "", open = false, fill = "";
    const st = { fg: "", bg: "", b: false, dim: false, it: false };
    const span = () => { if (open) out += "</span>"; const cls = [st.fg, st.bg, st.b && "b", st.dim && "dim", st.it && "it"].filter(Boolean); open = cls.length > 0; if (open) out += `<span class="${cls.join(" ")}">`; };
    for (const m of line.matchAll(/\x1b\[([0-9;]*)([mK])|([^\x1b]+)/g)) {
      if (m[3]) { out += esc(m[3]); continue; }
      if (m[2] === "K") { fill = st.bg; continue; }
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
    if (open) out += "</span>";
    return fill ? `<span class="row ${fill}">${out}</span>` : `<span class="row">${out}</span>`;
  }).join("");
}
function tourHtml(r, title, url) {
  const tour = readTour(r);
  const cover = JSON.parse(readFileSync(join(r.dir, "cover.json"), "utf8"));
  const names = new Set(defs(r.rows).map((d) => d.name).filter(Boolean));
  const P = (t) => proseHtml(t, names);
  const many = tour.chapters.length > 1, stopOf = stops(r, cover), W = 104;
  const what = /^\d+$/.test(r.dir.split("/").pop()) ? "!" + r.dir.split("/").pop() : r.dir.split("/").pop().replace(/^b-/, "").replace(/%/g, "/");
  const items = (c, ci) => c.stops.map((x, si) => `<li><a href="#s${ci + 1}-${si + 1}">${P(x.title)}</a></li>`).join("");
  const toc = many ? tour.chapters.map((c, ci) => `<li><a href="#c${ci + 1}"><b>${P(c.title)}</b></a><ol>${items(c, ci)}</ol></li>`).join("") : items(tour.chapters[0], 0);
  const chapters = tour.chapters.map((c, ci) => {
    const stopsHtml = c.stops.map((x, si) => {
      const { ti, k, body } = stopOf(x, W);
      const proof = k >= 0 && x.proves ? `<div class="proof"><span class="tick">✓</span><div>${P(x.proves)}<div class="from">from the test “${esc(cover.tests[ti].name)}”</div></div></div>`
        : k >= 0 ? `<div class="from">values from the test “${esc(cover.tests[ti].name)}”</div>` : `<div class="from">no test stops here, so no values</div>`;
      return `<section class="stop" id="s${ci + 1}-${si + 1}">
<div class="num">${many ? `${ci + 1}.${si + 1}` : si + 1}</div>
<div class="body"><h3>${P(x.title)}</h3><p>${P(x.says)}</p>${proof}
<figure class="code"><figcaption><span>${esc(x.path)}</span><span>lines ${x.start}–${x.end}</span></figcaption><pre>${ansiHtml(body.replace(/\n+$/, ""))}</pre></figure></div></section>`;
    }).join("\n");
    const open = c.questions && c.questions.length ? `<div class="open"><b>Still open after a close read</b><ul>${c.questions.map((q) => `<li>${P(q)}</li>`).join("")}</ul></div>` : "";
    return (many ? `<h2 id="c${ci + 1}"><span>Chapter ${ci + 1}</span>${P(c.title)}</h2>${c.intent ? `<p class="lede">${P(c.intent)}</p>` : ""}` : "") + stopsHtml + open;
  }).join("\n");
  const gaps = cover.gaps.length ? `<h2>No test runs these</h2><ul class="gaps">${cover.gaps.map((g) => `<li><code>${esc(g.name)}</code> <span>${esc(g.path)}:${g.start} · ${esc(g.why)}</span></li>`).join("")}</ul>` : "";
  const date = new Date().toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title || "Walkthrough of " + what)}</title>
<style>${TOUR_CSS}</style></head><body><main>
<header><p class="meta">Walkthrough of ${url ? `<a href="${esc(url)}">${esc(what)}</a>` : `<code>${esc(what)}</code>`} at <code>${r.rev.head.slice(0, 10)}</code> · ${date}</p>
<h1>${esc(title || what)}</h1>
<div class="lede">${P(tour.intent)}</div>
<p class="how">Read top to bottom: each stop is one place in the code, in the order it runs. <span class="m-at b">▶</span> marks the line the stop is about, <span class="m-good">●</span> lines a test ran, <span class="m-faint">○</span> lines it skipped; the values beside the code are what a real test run had there.</p>
<nav><h2>${many ? `${tour.chapters.length} chapters` : `${tour.chapters[0].stops.length} stops`}</h2><ol class="toc">${toc}</ol></nav>
</header>
${chapters}
${gaps}
<p class="foot">Made by otis from the change's own tests, run with a tracer: every value shown is one the code really had.</p>
</main><script>
// j and k: the next stop and the one before.
const stops = [...document.querySelectorAll(".stop")];
document.addEventListener("keydown", (e) => {
  if (e.target.closest("input, textarea") || !/^[jk]$/.test(e.key)) return;
  const y = window.scrollY + 8, i = stops.findIndex((s) => s.offsetTop > y);
  const to = e.key === "j" ? stops[i < 0 ? stops.length - 1 : i] : stops[Math.max(0, (i < 0 ? stops.length : i) - 2)];
  if (to) window.scrollTo({ top: to.offsetTop - 12, behavior: "smooth" });
});
</script></body></html>
`;
}
const TOUR_CSS = `
:root { --ground: #f6f7f8; --surface: #ffffff; --ink: #15181d; --soft: #525a66; --faint: #8a919c; --rule: #e2e5e9; --code: #eef0f3;
  --pass: #17784a; --pass-bg: #e2f3e9; --fail: #bb2d23; --fail-bg: #fbe8e5; --open: #8a5f00; --open-bg: #f9efd6; --link: #1f5fbf;
  --pre: #fbfbfc; --add: #e6f4ea; --del: #fbe9e7; --here: #fdf0cc; --else: #0b6e79; --yours: #7b3fb3;
  --k1: #b3261e; --k2: #1b7a3a; --k3: #8a5f00; --k4: #1f5fbf; --k5: #8f3db8; --k6: #0b6e79; --k7: #6f7682; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --ground: #121418; --surface: #1a1d22; --ink: #e8eaee; --soft: #a3aab5; --faint: #6f7682; --rule: #2a2e35; --code: #242830;
  --pass: #5cc98e; --pass-bg: #163326; --fail: #f07b70; --fail-bg: #3a1c19; --open: #e2b24a; --open-bg: #362a10; --link: #86b1f5;
  --pre: #16191e; --add: #15301f; --del: #3a1c19; --here: #3a2f10; --else: #6fd0d8; --yours: #c79bf2;
  --k1: #f07b70; --k2: #7fd49b; --k3: #e2b24a; --k4: #86b1f5; --k5: #d59cf5; --k6: #6fd0d8; --k7: #8a919c; } }
* { box-sizing: border-box; }
html { background: var(--ground); scroll-behavior: smooth; }
body { margin: 0; background: var(--ground); color: var(--ink); font: 16px/1.6 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
main { max-width: 900px; margin: 0 auto; padding: 56px 20px 96px; }
a { color: var(--link); text-decoration-thickness: 1px; text-underline-offset: 2px; }
p { margin: 0 0 10px; }
code { font: 0.86em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: 1px 5px; border-radius: 4px; overflow-wrap: anywhere; }
.meta { color: var(--soft); font-size: 14px; margin: 0 0 8px; }
h1 { font-size: 30px; line-height: 1.2; letter-spacing: -0.015em; margin: 0 0 20px; text-wrap: balance; }
.lede { font-size: 17px; margin-bottom: 12px; }
.how { color: var(--soft); font-size: 14px; }
h2 { font-size: 13px; font-weight: 650; text-transform: uppercase; letter-spacing: 0.08em; color: var(--soft); margin: 56px 0 12px; }
h2 span { display: block; color: var(--faint); font-size: 12px; }
h2[id] { text-transform: none; letter-spacing: -0.01em; font-size: 24px; color: var(--ink); }
h2[id] span { text-transform: uppercase; letter-spacing: 0.08em; }
nav h2 { margin-top: 32px; }
.toc { padding-left: 20px; margin: 0; } .toc ol { padding-left: 22px; margin: 4px 0 12px; } .toc li { margin: 2px 0; } .toc a { text-decoration: none; }
.stop { display: grid; grid-template-columns: 36px 1fr; gap: 12px; margin: 36px 0; scroll-margin-top: 12px; }
.num { width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; font-size: 13px; font-weight: 700; background: var(--open-bg); color: var(--open); margin-top: 2px; }
.body { min-width: 0; }
h3 { font-size: 19px; line-height: 1.35; margin: 2px 0 8px; }
.proof { display: flex; gap: 10px; background: var(--pass-bg); border-radius: 8px; padding: 10px 14px; margin: 12px 0; font-size: 15px; }
.tick { color: var(--pass); font-weight: 700; }
.from { color: var(--faint); font-size: 13px; margin-top: 2px; }
.code { margin: 14px 0 0; background: var(--pre); border: 1px solid var(--rule); border-radius: 8px; overflow: hidden; }
.code figcaption { display: flex; justify-content: space-between; gap: 12px; padding: 6px 12px; border-bottom: 1px solid var(--rule); font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--soft); }
.code figcaption span:last-child { color: var(--faint); font-family: -apple-system, system-ui, sans-serif; }
pre { margin: 0; padding: 8px 0; overflow-x: auto; font: 12.5px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
pre .row { display: block; padding: 0 12px; white-space: pre; min-height: 1.55em; }
.open { background: var(--open-bg); border-radius: 8px; padding: 12px 16px; margin: 24px 0 0 48px; font-size: 15px; }
.open b { color: var(--open); } .open ul { margin: 6px 0 0; padding-left: 18px; }
.gaps { padding-left: 18px; } .gaps span { color: var(--soft); font-size: 14px; }
.foot { color: var(--faint); font-size: 13px; margin-top: 64px; }
.b { font-weight: 700; } .dim { opacity: 0.55; } .it { font-style: italic; }
.bg-add { background: var(--add); } .bg-del { background: var(--del); } .bg-here { background: var(--here); }
.m-at { color: var(--open); } .m-good { color: var(--pass); } .m-bad { color: var(--fail); } .m-yours { color: var(--yours); }
.m-text { color: var(--ink); } .m-ctx { color: var(--soft); } .m-faint { color: var(--faint); } .m-else { color: var(--else); }
.c31, .c91 { color: var(--k1); } .c32, .c92 { color: var(--k2); } .c33, .c93 { color: var(--k3); } .c34, .c94 { color: var(--k4); }
.c35, .c95 { color: var(--k5); } .c36, .c96 { color: var(--k6); } .c30, .c90, .c37, .c97 { color: var(--k7); }
@media (max-width: 640px) { main { padding: 32px 16px 64px; } h1 { font-size: 24px; } .stop { grid-template-columns: 1fr; } .open { margin-left: 0; } }
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
function plain(r, x, w) {
  const paint = painted(r.rev.head, x.path), hk = hunks(r.rev, x.path), out = [];
  for (let n = x.start; n <= x.end; n++) {
    const num = (hk.added.has(n) ? C.good : C.faint) + String(n).padStart(5) + C.r;
    const code = cutA(paint[n - 1] ?? "", w - 9);
    out.push(n === x.focus ? under(`${num} ${C.at}\x1b[1m▶${C.r} ` + code, HERE) + "\x1b[0K" + C.r : `${num}   ` + code + C.r);
  }
  return out.join("\n") + "\n";
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
