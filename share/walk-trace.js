// node --require walk-trace.js: P's tracer (git-trace). Every hit of the
// lines OTIS_TRACE_TARGETS names ([{src, lines}], src a path suffix of a
// TypeScript or JavaScript source) goes to OTIS_TRACE_OUT, a JSON line a hit:
// the Jest test it ran under and its file, where it is, the traced frames under it, and
// its locals, an object's fields a level down.
//
// A worker attaches to this thread's inspector: a session on the same thread
// cannot take breakpoints, since the thread they pause is its own. Nothing
// waits for it (a thread blocked in a wait cannot answer the worker's
// inspector either); Jest takes far longer to reach a test than the worker
// takes to be ready. A script is matched to a target by its name and then its
// source map as it is parsed, since where a build puts it is known only then.
const { isMainThread, Worker, workerData, parentPort } = require("node:worker_threads");
const fs = require("node:fs");
const path = require("node:path");

if (isMainThread) {
  if (!process.env.OTIS_TRACE_TARGETS || !process.env.OTIS_TRACE_OUT) return;
  // Jest and its workers, and Vitest's workers (a fork a pool slot, where the
  // tests run), alone: NODE_OPTIONS reaches every node a test starts, a
  // database its setup runs among them, whose paths can say jest too.
  const jest = /(\/\.?bin\/jest(\.js)?|\/jest-worker\/build\/workers\/\w+\.js)$/.test(process.argv[1] || "");
  const vitest = /vitest[^/]*\/(files\/)?dist\/workers\/forks\.js$/.test(process.argv[1] || "") || !!process.env.VITEST_POOL_ID;
  if (process.env.OTIS_TRACE_DEBUG) try { fs.appendFileSync(process.env.OTIS_TRACE_DEBUG, `${process.pid} ${jest ? "jest" : vitest ? "vitest" : "-"} ${process.argv.slice(1, 3).join(" ")} pool=${process.env.VITEST_POOL_ID || ""}\n`); } catch {}
  if (!jest && !vitest) return;
  const w = new Worker(__filename, { workerData: { otisTrace: true } });
  w.unref();
  // With --inspect on, Node waits at exit for every session to go, the
  // worker's too: it is told to.
  process.on("exit", () => w.postMessage("exit"));
  return;
}
// Other threads preload this too (Node's ESM loader hooks run on one); only
// the worker made above traces.
if (!workerData || !workerData.otisTrace) return;

const inspector = require("node:inspector");
const s = new inspector.Session();
s.connectToMainThread();
// The listener also keeps the worker's loop alive while it waits for pauses;
// the worker is unref'd, so it does not keep the process up.
parentPort.on("message", () => {
  if (process.env.OTIS_TRACE_DEBUG) try { fs.appendFileSync(process.env.OTIS_TRACE_DEBUG, `${process.pid} pauses ${JSON.stringify(stat)}\n`); } catch {}
  s.disconnect(); process.exit(0);
});
// Where a pause's time goes, in ms, for OTIS_TRACE_DEBUG.
const stat = { n: 0, all: 0, scopes: 0, values: 0, test: 0, resume: 0 };
const ms = () => Number(process.hrtime.bigint() / 1000n) / 1000;
const post = (m, p) => new Promise((ok, no) => s.post(m, p || {}, (e, r) => (e ? no(e) : ok(r))));
// Where the trace goes; a sandboxed test cannot write outside itself, so
// there it goes to the test's own outputs (a runner copies it out). Never a
// reason for a test to fail: with nowhere to write, nothing is traced.
let out = null;
for (const f of [process.env.OTIS_TRACE_OUT, process.env.TEST_UNDECLARED_OUTPUTS_DIR && path.join(process.env.TEST_UNDECLARED_OUTPUTS_DIR, "otis-trace.jsonl")]) {
  if (!f) continue;
  try { out = fs.openSync(f, "a"); break; } catch {}
}
if (out === null) process.exit(0);
const targets = JSON.parse(fs.readFileSync(process.env.OTIS_TRACE_TARGETS, "utf8"));

// segments: a source map's mappings as [genLine, genCol, origLine, source].
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function segments(map) {
  const segs = [];
  let src = 0, oLine = 0, oCol = 0;
  map.mappings.split(";").forEach((line, gLine) => {
    let gCol = 0;
    for (const seg of line.split(",")) {
      if (!seg) continue;
      const v = [];
      let shift = 0, val = 0;
      for (const ch of seg) {
        const d = B64.indexOf(ch);
        val += (d & 31) << shift;
        if (d & 32) { shift += 5; continue; }
        v.push(val & 1 ? -(val >> 1) : val >> 1);
        val = 0; shift = 0;
      }
      gCol += v[0];
      if (v.length < 4) continue;
      src += v[1]; oLine += v[2]; oCol += v[3];
      segs.push([gLine, gCol, oLine, src]);
    }
  });
  return segs;
}

// show: a value as a debugger's preview has it, short.
function show(o) {
  if (!o || o.type === "undefined") return "undefined";
  if (o.subtype === "null") return "null";
  if (o.type === "string") return JSON.stringify(o.value.length > 200 ? o.value.slice(0, 200) + "…" : o.value);
  if (o.type === "number" || o.type === "boolean" || o.type === "bigint") return String(o.value ?? o.description);
  if (o.type === "function") return "ƒ";
  const p = o.preview;
  if (!p) return o.description;
  return (o.className && o.className !== "Object" && p.subtype !== "array" ? o.className + " " : "") + preview(p);
}
// preview: V8's preview of a value, its nested ones too (not "Object").
function preview(p) {
  const one = (x) => (x.type === "string" ? JSON.stringify(x.value) : x.type === "function" ? "ƒ" : x.valuePreview ? preview(x.valuePreview) : x.value);
  if (p.subtype === "array") return "[" + p.properties.map(one).join(", ") + (p.overflow ? ", …" : "") + "]";
  if (p.subtype === "date" || p.subtype === "null") return p.description || "null";
  if (!p.properties.length && !p.overflow) return "{}";
  return "{ " + p.properties.map((x) => x.name + ": " + one(x)).join(", ") + (p.overflow ? ", …" : "") + " }";
}

// value: a value kept as structure, to depth levels: an object or array as
// {c: its class, a: an array, p: [[name, value]...], m: more left out}, the
// rest as show has them. A Mongoose document is its fields (_doc); names
// that start with $ or __ are machinery.
async function value(o, depth) {
  if (!o || !o.objectId || o.type !== "object" || depth <= 0 || /^(null|date|regexp|map|set|weakmap|weakset|promise|error|typedarray|arraybuffer)$/.test(o.subtype || "")) return show(o);
  let { result } = await post("Runtime.getProperties", { objectId: o.objectId, ownProperties: true, generatePreview: true });
  const doc = result.find((p) => p.name === "_doc" && p.value && p.value.objectId);
  if (doc) ({ result } = await post("Runtime.getProperties", { objectId: doc.value.objectId, ownProperties: true, generatePreview: true }));
  const isArray = o.subtype === "array";
  const props = result.filter((p) => p.enumerable && p.value && p.value.type !== "function" && !/^(\$|__)/.test(p.name) && (!isArray || /^\d+$/.test(p.name)));
  // Nothing of its own to show (private fields, a Temporal value): as the
  // debugger previews it.
  if (!props.length) return show(o);
  const keep = props.slice(0, 40);
  const p = await Promise.all(keep.map(async (x) => [x.name, await value(x.value, depth - 1)]));
  return { c: isArray ? `Array(${props.length})` : o.className && o.className !== "Object" ? o.className : "", a: isArray, p, m: props.length > keep.length };
}

// url -> {g2o: generated line -> source line, src}: a frame's source and line.
const back = new Map();
// A function's last pause at a depth: each local's preview, to tell what moved.
const seen = new Map();
const urls = new Map();

// The targets' file names, to pass over every other script without reading
// its source map: a test loads thousands.
const stems = new Set(targets.map((t) => t.src.split("/").pop().replace(/\.[cm]?[jt]sx?$/, "")));
s.on("Debugger.scriptParsed", ({ params }) => {
  urls.set(params.scriptId, params.url);
  if (!params.url || /node_modules/.test(params.url)) return;
  if (!stems.has(params.url.split("/").pop().replace(/\.[cm]?[jt]sx?$/, "").replace(/\?.*$/, ""))) return;
  if (process.env.OTIS_TRACE_DEBUG) try { fs.appendFileSync(process.env.OTIS_TRACE_DEBUG, `script ${params.url} map=${(params.sourceMapURL || "").slice(0, 60)}\n`); } catch {}
  if (!params.sourceMapURL) return;
  let map, dir;
  try {
    const js = params.url.replace(/^file:\/\//, "");
    if (params.sourceMapURL.startsWith("data:")) {
      map = JSON.parse(Buffer.from(params.sourceMapURL.split(",")[1], "base64").toString());
      dir = path.dirname(js);
    } else {
      const f = path.resolve(path.dirname(js), params.sourceMapURL);
      map = JSON.parse(fs.readFileSync(f, "utf8"));
      dir = path.dirname(f);
    }
  } catch { return; }
  const srcs = map.sources.map((x) => path.resolve(dir, map.sourceRoot || "", x));
  const mine = targets.map((t) => [t, srcs.findIndex((x) => x.endsWith("/" + t.src))]).filter(([, i]) => i >= 0);
  if (!mine.length) return;
  const segs = segments(map);
  const g2o = new Map();
  for (const [gl, , ol] of segs) if (!g2o.has(gl)) g2o.set(gl, ol + 1);
  back.set(params.url, { g2o, src: mine[0][0].src, byLine: null });
  const byLine = new Map();
  for (const x of segs) { const l = byLine.get(x[0]) || []; l.push(x); byLine.set(x[0], l); }
  back.get(params.url).byLine = byLine;
  // A breakpoint at the first place on each target line, straight from the
  // map, sent at once: a script runs as soon as it is parsed, so waiting on
  // anything first loses its first lines. V8 moves one that is not on a
  // statement to the next that is.
  for (const [t, si] of mine) {
    const want = new Set(t.lines), first = new Map();
    for (const x of segs) if (x[3] === si && want.has(x[2] + 1)) { const f = first.get(x[2]); if (!f || x[0] < f[0] || (x[0] === f[0] && x[1] < f[1])) first.set(x[2], x); }
    for (const x of first.values()) post("Debugger.setBreakpoint", { location: { scriptId: params.scriptId, lineNumber: x[0], columnNumber: x[1] } }).catch(() => {});
  }
  // Where V8 can stop, as source lines, written down after: a line a test
  // skipped is told from one nothing could stop on (a parameter, a key of an
  // object literal).
  // And a breakpoint at each place a target function returns, where the
  // pause has the value it returns (P's behavior diff compares what goes
  // into a function and what comes out, not the names it uses on the way).
  post("Debugger.getPossibleBreakpoints", { start: { scriptId: params.scriptId, lineNumber: 0, columnNumber: 0 }, restrictToFunction: false }).then(({ locations }) => {
    for (const [t, si] of mine) {
      const want = new Set(t.lines), can = new Set();
      for (const loc of locations) {
        let seg = null;
        for (const x of byLine.get(loc.lineNumber) || []) if (x[1] <= (loc.columnNumber || 0) && (!seg || x[1] > seg[1])) seg = x;
        if (seg && seg[3] === si && want.has(seg[2] + 1)) {
          can.add(seg[2] + 1);
          if (loc.type === "return") post("Debugger.setBreakpoint", { location: { scriptId: params.scriptId, lineNumber: loc.lineNumber, columnNumber: loc.columnNumber } }).catch(() => {});
        }
      }
      fs.writeSync(out, JSON.stringify({ breakable: t.src, lines: [...can].sort((a, b) => a - b) }) + "\n");
    }
  }).catch(() => {});
});

// settled: once the pause has resumed, the promise's value, when it settles,
// for pause id (a hit's ret, walk.mjs puts it there). One that never settles
// before the test ends is left out.
let pauses = 0;
function settled(objectId, id, test, file) {
  setImmediate(async () => {
    try {
      const { result, exceptionDetails } = await post("Runtime.awaitPromise", { promiseObjectId: objectId, generatePreview: true });
      if (!exceptionDetails) fs.writeSync(out, JSON.stringify({ test, file, retOf: id, ret: await value(result, 3) }) + "\n");
    } catch {}
    post("Runtime.releaseObject", { objectId }).catch(() => {});
  });
}
s.on("Debugger.paused", async ({ params }) => {
  const t0 = ms(); let t = t0;
  const lap = (k) => { const x = ms(); stat[k] += x - t; t = x; };
  stat.n++;
  try {
    const f = params.callFrames[0];
    const locals = {};
    // A value opened only when its preview moved since this function's last
    // pause at this depth; else "=", the one before (share/walk.mjs carries
    // it). Opening every value at every pause made traces of tens of MB.
    const fl = f.functionLocation || f.location;
    const fk = `${fl.scriptId}:${fl.lineNumber}:${fl.columnNumber}:${params.callFrames.length}:${params.asyncStackTrace ? 1 : 0}`;
    const before = seen.get(fk) || {}, now = {};
    // The function's own names, a block's, a named closure's; not the module's.
    // Asked for at once: a pause is as long as its slowest answer, not their sum.
    const scopes = f.scopeChain.filter((sc) => (sc.type === "local" || sc.type === "block" || (sc.type === "closure" && sc.name)));
    const got = await Promise.all(scopes.map((sc) => post("Runtime.getProperties", { objectId: sc.object.objectId, ownProperties: true, generatePreview: true })));
    lap("scopes");
    const todo = [];
    for (const { result } of got) for (const p of result) {
      if (p.name in locals || !p.value || p.value.type === "function" || p.name === "exports") continue;
      const pv = show(p.value);
      now[p.name] = pv;
      locals[p.name] = "=";
      // An object opened three levels (then previews), when it moved.
      if (before[p.name] !== pv) todo.push(value(p.value, 3).then((v) => { locals[p.name] = v; }));
    }
    // At a return, what it returns. An async function's is the promise it
    // will settle, whose value is not there yet: it is kept past the pause
    // (a pause's objects go when it resumes) and its value written once it
    // settles, as a line of its own naming this pause (retOf).
    const rv = f.returnValue;
    const later = rv && rv.subtype === "promise" ? await post("Runtime.callFunctionOn", { objectId: rv.objectId, functionDeclaration: "function () { return this; }", objectGroup: "otis-returns" }).catch(() => null) : null;
    const ret = rv && !later ? await value(rv, 3) : undefined;
    // Unique in the trace, which several test processes write to.
    const id = `${process.pid}.${++pauses}`;
    await Promise.all(todo);
    lap("values");
    seen.set(fk, now);
    // The test, and its file: one run can hold several spec files.
    let test = null, file = null;
    try {
      const r = await post("Debugger.evaluateOnCallFrame", { callFrameId: f.callFrameId, expression: "(() => { const s = (globalThis.expect ?? globalThis[Symbol.for('expect-global')]).getState(); return [s.currentTestName, s.testPath]; })()", silent: true, returnByValue: true });
      [test, file] = r.result.value || [];
    } catch {}
    lap("test");
    const url = (c) => c.url || urls.get(c.location ? c.location.scriptId : c.scriptId) || "";
    const where = (c) => {
      const b = back.get(url(c));
      const ln = c.location ? c.location.lineNumber : c.lineNumber;
      const col = (c.location ? c.location.columnNumber : c.columnNumber) || 0;
      // The source line by line and column: a build puts a statement that
      // spans lines on one, and its first line is not where each part is.
      let seg = null;
      for (const x of (b.byLine && b.byLine.get(ln)) || []) if (x[1] <= col && (!seg || x[1] > seg[1])) seg = x;
      return { fn: c.functionName || "(anonymous)", src: b.src, line: seg ? seg[2] + 1 : b.g2o.get(ln) ?? null };
    };
    // Callers across an await are in the async stack, not the frames.
    const frames = params.callFrames.slice();
    for (let a = params.asyncStackTrace; a; a = a.parent) frames.push(...a.callFrames);
    const stack = frames.filter((c) => back.has(url(c))).map(where);
    fs.writeSync(out, JSON.stringify({ test: test ?? null, file: file ?? null, at: where(f), stack: stack.slice(1), locals, ...(ret !== undefined ? { ret } : {}), ...(later ? { id } : {}) }) + "\n");
    if (later) settled(later.result.objectId, id, test ?? null, file ?? null);
  } finally {
    await post("Debugger.resume");
    lap("resume"); stat.all += ms() - t0;
  }
});

(async () => {
  await post("Debugger.enable");
  await post("Debugger.setAsyncCallStackDepth", { maxDepth: 32 });
})();
