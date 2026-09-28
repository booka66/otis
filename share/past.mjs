// past.mjs <base> <table>: where the changed definitions broke before.
//
// For each definition the change touches that the base has (body, signature
// or removed), the commits of the last 18 months that touched its lines (git
// log -L, which follows them as they move), and of those the fixes: a
// subject that says fix, revert, hotfix, bug or regression. A fix is laid at
// the door of the commit that wrote most of the lines it took out (git blame
// of the fix's parent), when that was within 60 days of it: that change broke
// this code, and a change here now can break it the same way. A fix that only
// added lines, or took out old ones, is laid at no one: a bug fixed here.
//
// Out, a line a definition with a history worth saying, tab separated: its
// key (path#name, path#Class+member, as the table's rows are keyed), how many
// changes it had, how many fixes, and up to three, newest first, each as fix
// sha, fix date, fix subject and, when laid at a change, its sha, date,
// subject and the days between, joined by \x1f, fixes by \x1e. Four git log -L at a time.
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";

const [base, table] = process.argv.slice(2);
const FIX = /^(revert|hotfix)\b|\bfix(e[sd])?\b|\bbug\b|\bregression\b/i;
// A fix of the build, not of what the code does.
const CHORE = /\bfix(e[sd])?:? (the )?(types?|lint|format(ting)?|typos?|tests?|build|imports?|ci)\b/i;
const git = (args) => new Promise((ok) => execFile("git", args, { maxBuffer: 1 << 28 }, (e, out) => ok(e ? "" : out)));

const defs = [];
for (const l of readFileSync(table, "utf8").split("\n")) {
  const f = l.split("\t");
  if (f.length < 15 || f[1] === "file" || !["body", "signature", "removed"].includes(f[5])) continue;
  const bs = +f[13], be = +f[14];
  if (!bs || !be) continue;
  defs.push({ key: `${f[0]}#${f[3] ? f[3] + "+" : ""}${f[2]}`, path: f[0], bs, be });
}

// One definition: its commits, each with the old lines it took out of it.
async function one(d) {
  const out = await git(["log", "-L", `${d.bs},${d.be}:${d.path}`, "--no-merges", "--since=18.months", "--format=\x01%H %ct %s", base]);
  const commits = [];
  for (const part of out.split("\x01").slice(1)) {
    const nl = part.indexOf("\n"), head = part.slice(0, nl), m = /^(\S+) (\d+) (.*)$/.exec(head);
    if (!m) continue;
    const c = { sha: m[1], at: +m[2], subject: m[3], from: "", removed: [] };
    let o = 0;
    for (const l of part.slice(nl + 1).split("\n")) {
      if (l.startsWith("--- a/")) c.from = l.slice(6);
      else if (l.startsWith("@@")) o = +/^@@ -(\d+)/.exec(l)[1];
      else if (l.startsWith("-") && !l.startsWith("---")) c.removed.push(o++);
      else if (l.startsWith(" ")) o++;
    }
    commits.push(c);
  }
  const breaks = [];
  let n = 0;
  for (let i = 0; i < commits.length; i++) {
    const f = commits[i];
    if (!FIX.test(f.subject) || CHORE.test(f.subject)) continue;
    // Who wrote what the fix took out: the newest of them, the likeliest culprit.
    let x = null;
    if (f.removed.length && f.from) {
      const lo = Math.min(...f.removed), hi = Math.max(...f.removed);
      const bl = await git(["blame", "--porcelain", "-L", `${lo},${hi}`, f.sha + "^", "--", f.from]);
      const seen = new Map();
      for (const m of bl.matchAll(/^([0-9a-f]{40}) \d+ (\d+)/gm)) if (f.removed.includes(+m[2])) seen.set(m[1], (seen.get(m[1]) || 0) + 1);
      const shas = [...seen.keys()];
      if (shas.length) {
        const info = await git(["show", "-s", "--format=%H %ct %s", ...shas]);
        // Not a merge: its lines are a conflict's resolution, not a change.
        // The one that wrote most of them, the newer on a tie.
        x = info.split("\n").filter(Boolean).map((l) => { const m = /^(\S+) (\d+) (.*)$/.exec(l); return { sha: m[1], at: +m[2], subject: m[3] }; })
          .filter((c) => !/^Merge /.test(c.subject)).sort((a, b) => (seen.get(b.sha) || 0) - (seen.get(a.sha) || 0) || b.at - a.at)[0] || null;
      }
    }
    // A fix that only added lines, or took out what was written long before
    // it, is a bug fixed here with no change to lay it on.
    const days = x ? Math.round((f.at - x.at) / 86400) : -1;
    if (++n > 3) continue;
    breaks.push((days >= 0 && days <= 60 ? [f.sha.slice(0, 11), day(f.at), f.subject, x.sha.slice(0, 11), day(x.at), x.subject, days] : [f.sha.slice(0, 11), day(f.at), f.subject]).join("\x1f"));
  }
  return breaks.length ? `${d.key}\t${commits.length}\t${n}\t${breaks.join("\x1e")}` : null;
}
const day = (t) => new Date(t * 1000).toISOString().slice(0, 10);

const lines = [];
for (let i = 0; i < defs.length; i += 4) lines.push(...(await Promise.all(defs.slice(i, i + 4).map(one))));
process.stdout.write(lines.filter(Boolean).map((l) => l + "\n").join(""));
