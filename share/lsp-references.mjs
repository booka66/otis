// lsp-references.mjs: where a symbol is used, from tsgo, for git-callers.
//
// A job on stdin, JSON: the repo root, the files to open (each with the path
// the text is read from, or nothing for the file as it is on disk) and the
// queries, each a symbol's id, file, the line its keyword is on and its name.
// One tsgo --lsp session: every file opened loads its project, and a
// references query searches every project loaded, so opening one file from
// each package that imports a changed file is what finds the callers in it.
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
import { readFileSync } from "node:fs";
import { resolve, relative } from "node:path";

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
const texts = new Map();
const out = [];
const refFiles = new Set();
const die = setTimeout(() => { process.stderr.write("tsgo: no answer in time\n"); lsp.kill(); process.exit(1); }, 300000);

await request("initialize", { processId: process.pid, rootUri: "file://" + root, capabilities: {}, workspaceFolders: [{ uri: "file://" + root, name: "root" }] });
send({ jsonrpc: "2.0", method: "initialized", params: {} });
for (const f of job.open) {
  let text;
  try { text = readFileSync(resolve(root, f.from || f.path), "utf8"); } catch { continue; }
  texts.set(f.path, text);
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: uri(f.path), languageId: f.path.endsWith("x") ? "typescriptreact" : "typescript", version: 1, text } } });
}
for (const q of job.queries) {
  const lines = (texts.get(q.path) || "").split("\n");
  // The name's column: on the keyword's line, or the next few (export on
  // one line, the declaration on the next is rare, but happens).
  let line = -1, col = -1;
  const re = new RegExp("(^|[^A-Za-z0-9_$])" + q.name.replace(/\$/g, "\\$") + "(?![A-Za-z0-9_$])");
  for (let l = q.line - 1; l < Math.min(q.line + 3, lines.length); l++) {
    const m = re.exec(lines[l]);
    if (m) { line = l; col = m.index + m[1].length; break; }
  }
  if (line < 0) continue;
  const r = await request("textDocument/references", { textDocument: { uri: uri(q.path) }, position: { line, character: col }, context: { includeDeclaration: false } });
  for (const ref of r.result || []) {
    const p = relative(root, decodeURIComponent(ref.uri.replace(/^file:\/\//, "")));
    if (p.startsWith("..")) continue;
    out.push(["R", q.id, p, ref.range.start.line + 1, ref.range.start.character + 1].join("\t"));
    refFiles.add(p);
  }
}
if (job.check) {
  for (const p of job.importers || []) refFiles.add(p);
  for (const p of refFiles) {
    if (texts.has(p)) continue;
    let text;
    try { text = readFileSync(resolve(root, p), "utf8"); } catch { continue; }
    texts.set(p, text);
    send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: uri(p), languageId: p.endsWith("x") ? "typescriptreact" : "typescript", version: 1, text } } });
  }
  const versions = new Map();
  const swap = (path, text) => {
    const v = (versions.get(path) || 1) + 1;
    versions.set(path, v);
    send({ jsonrpc: "2.0", method: "textDocument/didChange", params: { textDocument: { uri: uri(path), version: v }, contentChanges: [{ text }] } });
  };
  const errors = async () => {
    const seen = new Map();
    for (const p of refFiles) {
      const d = await request("textDocument/diagnostic", { textDocument: { uri: uri(p) } });
      seen.set(p, (d.result?.items || []).filter((it) => it.severity === 1));
    }
    return seen;
  };
  // The base: the changed files as they were, and what the callers had wrong then.
  const base = [];
  for (const b of job.base || []) {
    let text;
    try { text = readFileSync(resolve(root, b.from), "utf8"); } catch { continue; }
    if (!texts.has(b.path)) continue;
    base.push(b.path); swap(b.path, text);
  }
  const before = await errors();
  for (const p of base) swap(p, texts.get(p));
  const after = await errors();
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
clearTimeout(die);
process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
lsp.kill();
