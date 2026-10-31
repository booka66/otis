#!/usr/bin/env node
// leftover.mjs <base> <head>: the lines of a change that only moved or were renamed, found from the diff alone, one a
// line as <new|old>, path, line. The review's nvim leaves them off the green (share/diffmarks.lua) and ] passes them.
// stops.mjs imports the same sorting, for what it leaves out of what Claude reads.
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

// What nobody reads line by line: generated files, translations, lockfiles and build lists.
const SKIP = /(^|\/)i18n\/catalogs\/|BUILD\.bazel$|lock(\.\w+)?$|\.snap$|(^|\/)package\.json$|(^|\/)tsconfig[^/]*\.json$/;
const IDENT = /[A-Za-z_$][A-Za-z0-9_$]*/g;
const MAX = 1 << 30;

// Every added and removed line with where it is: renames off, so a move shows as a delete and an add.
export function changes(base, head) {
  const added = [], removed = [];
  let path = null, n = 0, was = 0, wasPath = null;
  const diff = execFileSync("git", ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-renames", "-U0", base, head], { encoding: "utf8", maxBuffer: MAX, stdio: ["ignore", "pipe", "ignore"] });
  for (const line of diff.split("\n")) {
    if (line.startsWith("+++ ")) path = line.slice(6);
    else if (line.startsWith("--- ")) wasPath = line.slice(6);
    else if (line.startsWith("diff ")) continue;
    else if (line.startsWith("@@")) { const m = /-(\d+)(?:,\d+)? \+(\d+)/.exec(line); was = Number(m[1]); n = Number(m[2]); }
    else if (line.slice(1).trim()) {
      if (line[0] === "+" && !SKIP.test(path)) added.push({ path, n, text: line.slice(1).trim() });
      else if (line[0] === "-" && !SKIP.test(wasPath)) removed.push({ path: wasPath, n: was, text: line.slice(1).trim() });
    }
    if (line[0] === "+" && !line.startsWith("+++ ")) n++;
    else if (line[0] === "-" && !line.startsWith("--- ")) was++;
  }
  return { added, removed };
}

const pools = (ones, keyOf) => { const pool = new Map(); for (const one of ones) { const key = keyOf(one); if (!pool.has(key)) pool.set(key, []); pool.get(key).push(one); } return pool; };
const wordsOf = (ones) => new Set(ones.flatMap((one) => one.text.match(IDENT) ?? []));

// Added lines into those only moved (the same text removed elsewhere), those only renamed (the same once the words
// found on one side alone are blanked) and the fresh ones left; and the removed lines those took.
export function sift({ added, removed }) {
  const taken = [];
  const match = (ones, gone, keyNew, keyOld) => {
    const pool = pools(gone, keyOld);
    return ones.filter((one) => { const old = pool.get(keyNew(one))?.shift(); if (old) taken.push(old); return !old; });
  };
  const unmoved = match(added, removed, (one) => one.text, (one) => one.text);
  const took = new Set(taken);
  const gone = removed.filter((one) => !took.has(one));
  const newWords = wordsOf(unmoved), oldWords = wordsOf(gone);
  const blank = (text, keep) => text.replace(IDENT, (word) => (keep.has(word) ? word : "_"));
  const fresh = match(unmoved, gone, (one) => blank(one.text, oldWords), (one) => blank(one.text, newWords));
  return { fresh, taken };
}

// A lone } or return null; removed elsewhere is no move: as git's --color-moved, a block of them counts once it holds
// 20 letters and digits.
function blocks(ones, side) {
  const out = [];
  let run = [];
  const flush = () => { if (run.map((one) => one.text.replace(/[^A-Za-z0-9]/g, "")).join("").length >= 20) for (const one of run) out.push(`${side}\t${one.path}\t${one.n}`); run = []; };
  for (const one of ones) {
    const last = run[run.length - 1];
    if (last && (last.path !== one.path || last.n + 1 !== one.n)) flush();
    run.push(one);
  }
  flush();
  return out;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const change = changes(process.argv[2], process.argv[3]);
  const { fresh, taken } = sift(change);
  const isFresh = new Set(fresh);
  const lines = [...blocks(change.added.filter((one) => !isFresh.has(one)), "new"), ...blocks(taken.sort((a, b) => (a.path === b.path ? a.n - b.n : a.path < b.path ? -1 : 1)), "old")];
  if (lines.length) console.log(lines.join("\n"));
}
