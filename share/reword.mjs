#!/usr/bin/env node
// reword.mjs <outline.json> <n>: case n of a change (sentences.mjs) told again for you: the same case, every claim
// in it kept, in words that leave alone the ones you know and explain the ones you are learning (otis-words).
// Written beside the outline as <outline>.reader.<n>.json, which the pane (story-pane.mjs) reads over the case;
// <outline>.reader.<n>.running while Claude writes it. What a word you are learning means goes into your words.
import { execFile, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [file, which] = process.argv.slice(2);
const outline = JSON.parse(readFileSync(file, "utf8"));
const part = outline.sentences[Number(which) - 1];
if (!part || !part.stops) process.exit(0);
const out = file.replace(/\.json$/, `.reader.${which}.json`), running = out.replace(/\.json$/, ".running");
const words = (args) => { try { return execFileSync("otis-words", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }); } catch { return ""; } };
const reader = words(["--reader"]).trim();
if (!reader) process.exit(0);
const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();

const said = {
  text: part.text, setup: part.setup, where: part.where, ends: part.ends, stopped: part.stopped,
  facts: part.facts.map(({ what, before, after }) => ({ what, before, after })),
  stops: part.stops.map((stop) => ({ name: stop.name, is: stop.is, values: stop.lines.map((line) => line.value) })),
};
const prompt = [
  "Below is one case from a code review: a situation the changed code meets, how it ends, and the route through the code, as JSON. Tell it again for one reader. Keep every claim, number and name exactly as it is; change only the words, so the reader understands it on the first read.",
  "",
  reader,
  "",
  "For each word the reader is learning that comes up in the case, check in the code what it is here (one per call, no pipes):",
  `  git -C ${root} grep -n -e <pattern> ${outline.head} -- <paths>`,
  `  git -C ${root} show ${outline.head}:<path>`,
  "and say what it is in plain words the first time it comes up. Leave the words the reader knows as they are, with no explanation. Every other word, as plain as the case has it now.",
  "",
  "Return the same fields: text (the situation, at most 10 words), setup, where, ends and stopped (each \"\" when it is \"\" now), facts (as many, in the same order: what, before, after), stops (as many, in the same order: is, and values as many as now, each \"\" when it is \"\" now). Names from the code stay in backticks. meanings: for each word the reader is learning that the case uses, what it means here, in one or two plain sentences.",
  "",
  JSON.stringify(said, null, 1),
].join("\n");
const text = { type: "string" };
const object = (properties) => ({ type: "object", additionalProperties: false, required: Object.keys(properties), properties });
const list = (items) => ({ type: "array", items });
const schema = object({
  text, setup: text, where: text, ends: text, stopped: text,
  facts: list(object({ what: text, before: text, after: text })),
  stops: list(object({ is: text, values: list(text) })),
  meanings: list(object({ word: text, meaning: text })),
});

writeFileSync(running, String(process.pid));
const empty = mkdtempSync(join(tmpdir(), "otis-reword-"));
const model = (() => { try { return execFileSync("git", ["config", "--get", "otis.sentencesModel"], { encoding: "utf8" }).trim(); } catch { return ""; } })() || "claude-sonnet-5-5";
const answer = await new Promise((done) => {
  execFile(process.env.SEAM_CLAUDE || "claude", [
    "-p", "--model", model, "--restricted", "--tools", "Bash", "--add-dir", root,
    "--allowedTools", `Bash(git -C ${root} grep:*)`, `Bash(git -C ${root} show:*)`,
    "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--permission-prompts", "none",
    "--max-budget-usd", "1", "--output-format", "json", "--json-schema", JSON.stringify(schema),
  ], { cwd: empty, encoding: "utf8", maxBuffer: 1 << 26, timeout: 300000 }, (error, stdout) => done(stdout || null)).stdin.end(prompt);
});
rmSync(empty, { recursive: true, force: true });
let told = null;
try { told = JSON.parse(answer).structured_output; } catch { told = null; }
// Only an answer that fits the case goes over it: as many facts, stops and values as the case has.
const fits = told && told.facts?.length === said.facts.length && told.stops?.length === said.stops.length
  && told.stops.every((stop, i) => stop.values?.length === said.stops[i].values.length);
if (fits) {
  // What the case was told from, so the pane lays it over this case and no other.
  writeFileSync(out + ".new", JSON.stringify({ of: part.text, reader, ...told }));
  renameSync(out + ".new", out);
  for (const { word, meaning } of told.meanings ?? []) if (word && meaning) words(["mean", word, meaning]);
}
rmSync(running, { force: true });
