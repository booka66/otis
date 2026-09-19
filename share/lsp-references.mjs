// lsp-references.mjs: where a symbol is used, from tsgo, for git-callers.
//
// A job on stdin, JSON: the repo root, the files to open (each with the path
// the text is read from, or nothing for the file as it is on disk) and the
// queries, each a symbol's id, file, the line its keyword is on and its name.
// One tsgo --lsp session: every file opened loads its project, and a
// references query searches every project loaded, so opening the job's
// importers, a few packages at a time, is what finds the callers in them.
// Out: one line a reference, tab separated: R, the query's id, the path,
// the line and the column, both counted from 1. With check set, the files
// the references are in, and the job's importers, are checked twice, with
// the changed files first at their base text (the job's base list) and then
// as the change leaves them, and each error the change brings, one the base
// text did not have, is a line: D, the path, the line, the message.
//
// tsgo answers nothing until its own requests to the client (registering
// capabilities) are answered, so every server request gets a null reply.
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";

const job = JSON.parse(readFileSync(0, "utf8"));
const root = job.root;
const lsp = spawn("tsgo", ["--lsp", "--stdio"], { stdio: ["pipe", "pipe", "ignore"] });
let buf = Buffer.alloc(0);
let nextId = 1;
const waiting = new Map();

function send(msg) {
  const body = Buffer.from(JSON.stringify(msg));
  lsp.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]));
}
function request(method, params) {
  const id = nextId++;
  return new Promise((ok) => {
    waiting.set(id, ok);
    send({ jsonrpc: "2.0", id, method, params });
  });
}
lsp.stdout.on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  for (;;) {
    const sep = buf.indexOf("\r\n\r\n");
    if (sep < 0) return;
    const len = Number(/content-length:\s*(\d+)/i.exec(buf.subarray(0, sep).toString())[1]);
    if (buf.length < sep + 4 + len) return;
    const msg = JSON.parse(buf.subarray(sep + 4, sep + 4 + len).toString());
    buf = buf.subarray(sep + 4 + len);
    if (msg.id !== undefined && msg.method) send({ jsonrpc: "2.0", id: msg.id, result: null });
    else if (msg.id !== undefined && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
  }
});

const uri = (p) => "file://" + resolve(root, p);
const open = (p, text) => send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: uri(p), languageId: p.endsWith("x") ? "typescriptreact" : "typescript", version: 1, text } } });
const close = (p) => send({ jsonrpc: "2.0", method: "textDocument/didClose", params: { textDocument: { uri: uri(p) } } });
const texts = new Map();
const out = [];
// No answer from tsgo in five minutes is a hung tsgo; a long run that keeps
// answering is not.
let die;
const alive = () => { clearTimeout(die); die = setTimeout(() => { process.stderr.write("tsgo: no answer in time\n"); lsp.kill(); process.exit(1); }, 300000); };
alive();
const ask = (method, params) => request(method, params).then((r) => { alive(); return r; });

await ask("initialize", { processId: process.pid, rootUri: "file://" + root, capabilities: {}, workspaceFolders: [{ uri: "file://" + root, name: "root" }] });
send({ jsonrpc: "2.0", method: "initialized", params: {} });
// tsgo asks the client to register capabilities once it is initialized and
// reads no more of its input until that is answered. So the answer must
// never be queued behind a flood: a change touching a hundred files, opened
// one after another, leaves tsgo waiting on an answer it will not read, and
// the session hangs for good. A round trip before the first open is
// answered only once tsgo has had its own answer, and one every so often
// after that is proof it has drained what came before. A method tsgo has
// never heard of is an error to it and a round trip to us, which is all
// this asks of it.
const drained = () => ask("$/otis/ping", {});
await drained();
// The changed files stay open, as the change leaves them, the whole session.
let since = 0;
for (const f of job.open) {
  let text;
  try { text = readFileSync(resolve(root, f.from || f.path), "utf8"); } catch { continue; }
  texts.set(f.path, text);
  open(f.path, text);
  if (++since >= 20) { since = 0; await drained(); }
}
// Each query's position: the name's column, on the keyword's line or the
// next few (export on one line, the declaration on the next is rare, but
// happens).
const queries = [];
for (const q of job.queries) {
  const lines = (texts.get(q.path) || "").split("\n");
  const re = new RegExp("(^|[^A-Za-z0-9_$])" + q.name.replace(/\$/g, "\\$") + "(?![A-Za-z0-9_$])");
  for (let l = q.line - 1; l < Math.min(q.line + 3, lines.length); l++) {
    const m = re.exec(lines[l]);
    if (m) { queries.push({ ...q, line: l, col: m.index + m[1].length }); break; }
  }
}
const base = [];
for (const b of job.base || []) {
  if (!texts.has(b.path)) continue;
  try { base.push([b.path, readFileSync(resolve(root, b.from), "utf8")]); } catch {}
}
const versions = new Map();
const swap = (path, text) => {
  const v = (versions.get(path) || 1) + 1;
  versions.set(path, v);
  send({ jsonrpc: "2.0", method: "textDocument/didChange", params: { textDocument: { uri: uri(path), version: v }, contentChanges: [{ text }] } });
};
const errors = async (files) => new Map(await Promise.all(files.map(async (p) => {
  const d = await ask("textDocument/diagnostic", { textDocument: { uri: uri(p) } });
  return [p, (d.result?.items || []).filter((it) => it.severity === 1)];
})));

// The importers by package, a batch of packages at a time. Every package
// tsgo has loaded is a program over its dependencies' source, a gigabyte or
// more each, so a batch's files are closed once it is done, which lets
// tsgo drop its projects: what the session holds stays a batch, however
// many packages import the change. The base and the head are the same
// swap for every project loaded, so a batch is checked in step; within
// one, its requests are in flight together.
const BATCH = 8;
const pkg = (p) => {
  let d = dirname(p);
  while (d !== "." && d !== "/" && !existsSync(resolve(root, d, "package.json"))) d = dirname(d);
  return d;
};
const byPkg = new Map();
for (const im of job.importers || []) {
  const f = typeof im === "string" ? { path: im, of: [] } : im;
  const k = pkg(f.path);
  if (!byPkg.has(k)) byPkg.set(k, []);
  byPkg.get(k).push(f);
}
const pkgs = [...byPkg.values()];
const seenRefs = new Set();
const checked = new Set();
for (let i = 0; i === 0 || i < pkgs.length; i += BATCH) {
  const opened = [];
  const load = (p) => {
    if (texts.has(p) || opened.includes(p)) return;
    let text;
    try { text = readFileSync(resolve(root, p), "utf8"); } catch { return; }
    open(p, text);
    opened.push(p);
  };
  const batch = pkgs.slice(i, i + BATCH).flat();
  const importers = batch.map((f) => f.path);
  for (const p of importers) load(p);
  await drained();
  // A reference searches every project loaded, so every batch would answer
  // every query again. A batch is asked only about the changed files its
  // packages import, which is what it can hold a reference to: a symbol
  // reached through a changed file that re-exports it is missed, and is
  // rare enough against asking every batch about every changed symbol.
  const of = new Set(batch.flatMap((f) => f.of || []));
  const mine = queries.filter((q) => of.has(q.path));
  const refFiles = new Set();
  for (const r of await Promise.all(mine.map((q) => ask("textDocument/references", { textDocument: { uri: uri(q.path) }, position: { line: q.line, character: q.col }, context: { includeDeclaration: false } }).then((r) => [q, r])))) {
    const [q, res] = r;
    for (const ref of res.result || []) {
      const p = relative(root, decodeURIComponent(ref.uri.replace(/^file:\/\//, "")));
      if (p.startsWith("..")) continue;
      const row = ["R", q.id, p, ref.range.start.line + 1, ref.range.start.character + 1].join("\t");
      if (seenRefs.has(row)) continue;
      seenRefs.add(row);
      out.push(row);
      refFiles.add(p);
    }
  }
  if (job.check) {
    const files = [...new Set([...importers, ...refFiles])].filter((p) => !checked.has(p));
    for (const p of files) { checked.add(p); load(p); }
    // The base: the changed files as they were, and what the callers had wrong then.
    for (const [p, text] of base) swap(p, text);
    const before = await errors(files);
    for (const [p] of base) swap(p, texts.get(p));
    const after = await errors(files);
    // A caller's file is the same text in both passes, so an error is the same
    // error by its line; its message may name the types, which the change
    // may have renamed.
    for (const [p, items] of after) {
      const had = new Map();
      for (const it of before.get(p) || []) had.set(it.range.start.line, (had.get(it.range.start.line) || 0) + 1);
      for (const it of items) {
        const n = had.get(it.range.start.line) || 0;
        if (n > 0) { had.set(it.range.start.line, n - 1); continue; }
        out.push(["D", p, it.range.start.line + 1, it.message.split("\n")[0]].join("\t"));
      }
    }
  }
  for (const p of opened) close(p);
}
clearTimeout(die);
process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
lsp.kill();
