// lsp-hover.mjs: the declared type of names at lines, from tsgo, for
// git-symbols-walk's values.
//
// A job on stdin, JSON: the repo root, the files to open (each with the path
// the text is read from), and the queries, each an id, a file, a line
// (counted from 1) and a name. Each name is looked for on its line, then on
// the lines nearest it, up to ten either way, and tsgo is asked what it is
// there. Out: one line a query answered, tab separated: the id and the type,
// as tsgo's hover says it after the name, on one line.
//
// One tsgo --lsp session, as share/lsp-references.mjs runs it: every server
// request gets a null reply, and a round trip after the opens proves tsgo
// has read them. The whole session has two minutes.
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { cpus, totalmem } from "node:os";
import { resolve } from "node:path";

const job = JSON.parse(readFileSync(0, "utf8"));
const root = job.root;
const lsp = spawn("tsgo", ["--lsp", "--stdio"], {
  stdio: ["pipe", "pipe", "ignore"],
  env: {
    GOMAXPROCS: String(Math.max(1, Math.floor(cpus().length / 2))),
    GOMEMLIMIT: `${Math.floor(totalmem() / 4 / 2 ** 20)}MiB`,
    ...process.env,
  },
});
setTimeout(() => { lsp.kill(); process.exit(0); }, 120000).unref();
let buf = Buffer.alloc(0);
let nextId = 1;
const waiting = new Map();
const send = (msg) => {
  const body = Buffer.from(JSON.stringify(msg));
  lsp.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]));
};
const ask = (method, params) => {
  const id = nextId++;
  return new Promise((ok) => { waiting.set(id, ok); send({ jsonrpc: "2.0", id, method, params }); });
};
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

await ask("initialize", { processId: process.pid, rootUri: "file://" + root, capabilities: {}, workspaceFolders: [{ uri: "file://" + root, name: "root" }] });
send({ jsonrpc: "2.0", method: "initialized", params: {} });
await ask("$/otis/ping", {});
const texts = new Map();
for (const f of job.open) {
  let text;
  try { text = readFileSync(resolve(root, f.from || f.path), "utf8"); } catch { continue; }
  texts.set(f.path, text.split("\n"));
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: uri(f.path), languageId: f.path.endsWith("x") ? "typescriptreact" : "typescript", version: 1, text } } });
}
await ask("$/otis/ping", {});

// The name's last part (args.teamId is teamId), on the line or the nearest.
const place = (q) => {
  const lines = texts.get(q.path);
  const name = q.name.split(".").pop();
  if (!lines || !/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name)) return null;
  const re = new RegExp("(^|[^A-Za-z0-9_$])" + name.replace(/\$/g, "\\$") + "(?![A-Za-z0-9_$])");
  for (let d = 0; d <= 10; d++) {
    for (const l of d ? [q.line - 1 - d, q.line - 1 + d] : [q.line - 1]) {
      const m = l >= 0 && l < lines.length ? re.exec(lines[l]) : null;
      if (m) return { line: l, character: m.index + m[1].length, name };
    }
  }
  return null;
};
// Hover says "(parameter) args: SendRecipientArgs" in a code block: what is
// after the name and its colon, the first line of it.
const typeOf = (hover, name) => {
  const c = hover?.result?.contents;
  const text = typeof c === "string" ? c : Array.isArray(c) ? c.map((x) => x.value ?? x).join("\n") : c?.value ?? "";
  const code = (/```\w*\n([\s\S]*?)```/.exec(text)?.[1] ?? text).split("\n")[0];
  const at = code.indexOf(name + ":");
  if (at < 0) return null;
  // An object type goes on over lines; its first is only the brace.
  let t = code.slice(at + name.length + 1).trim();
  if (t.endsWith("{")) t += " … }";
  // A type worth a glance: short, and not a list of every literal a union
  // allows ("attentive" | "contactForm" | ...), which says less than the value.
  if (!t || t.length > 50 || (t.match(/\|/g) || []).length > 3) return null;
  return t;
};
const out = [];
await Promise.all(job.queries.map(async (q) => {
  const at = place(q);
  if (!at) return;
  const t = typeOf(await ask("textDocument/hover", { textDocument: { uri: uri(q.path) }, position: { line: at.line, character: at.character } }), at.name);
  if (t) out.push(`${q.id}\t${t.replace(/\s+/g, " ")}`);
}));
process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
lsp.kill();
process.exit(0);
