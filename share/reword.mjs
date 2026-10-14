#!/usr/bin/env node
// reword.mjs <outline.json> <n> [<state> <word> [note]]: case n of a change (sentences.mjs) told again for you:
// the same case, every claim in it kept, in words that leave alone the things you know and say the ones you
// don't from the code (otis-words). Given a word you just marked there (known, learning or noted), Claude
// also reads which thing it names in this case's code, and that is placed in your words. Written beside the
// outline as <outline>.reader.<n>.json, which the pane (story-pane.mjs) reads over the case;
// <outline>.reader.<n>.running while Claude writes it.
import { execFile, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [file, which, state = "", word = "", note = ""] = process.argv.slice(2);
const outline = JSON.parse(readFileSync(file, "utf8"));
const part = outline.sentences[Number(which) - 1];
const words = (args) => { try { return execFileSync("otis-words", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }); } catch { return ""; } };
// A word marked and not placed is not lost: it holds wherever the word comes up.
const unplaced = () => { if (word) words(["place", state, word, "", "", note]); };
if (!part || !part.stops) { unplaced(); process.exit(0); }
const out = file.replace(/\.json$/, `.reader.${which}.json`), running = out.replace(/\.json$/, ".running");
const reader = words(["--reader"]).trim();
const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const marked = !word ? "" : `The reader just marked "${word}" in this case: ${state === "known" ? "they know what it names here; do not explain it" : state === "noted" ? `in their own words it is: ${note}; take that as true` : "they do not know what it names here; say what it is from the code"}. In marked, say which thing "${word}" names in this case's code: thing, a few plain words that pick it out from other things the same word could name (like "the SQS queue customer events wait on"), and where, the folder or file of the code that defines or holds it.`;
if (!reader && !marked) process.exit(0);

const said = {
  text: part.text, setup: part.setup, where: part.where, ends: part.ends, stopped: part.stopped,
  facts: part.facts.map(({ what, before, after }) => ({ what, before, after })),
  stops: part.stops.map((stop) => ({ name: stop.name, path: stop.path, is: stop.is, values: stop.lines.map((line) => line.value) })),
};
const prompt = [
  "Below is one case from a code review: a situation the changed code meets, how it ends, and the route through the code (each stop with the file it is in), as JSON. Tell it again for one reader. Keep every claim, number and name exactly as it is; change only the words, so the reader understands it on the first read.",
  "",
  ...(reader ? [reader, ""] : []),
  ...(marked ? [marked, ""] : []),
  "To tell which thing a word names here, and what a thing the reader does not know is, read the code this case runs through (one command per call, no pipes):",
  `  git -C ${root} grep -n -e <pattern> ${outline.head} -- <paths>`,
  `  git -C ${root} show ${outline.head}:<path>`,
  "Say what such a thing is right where it first comes up, woven into the sentence: the concrete thing in this case's code, by what it is built on and its name there (a cloud service, a table, a library, a workflow, a task queue), and what puts things into it or reads from it, in plain words. Never a general definition, and never what the word names somewhere else in the codebase. A thing the reader knows: leave it as it is, with no explanation. Every other word, as plain as the case has it now.",
  "",
  "Return the same fields: text (the situation, at most 10 words), setup, where, ends and stopped (each \"\" when it is \"\" now), facts (as many, in the same order: what, before, after), stops (as many, in the same order: is, and values as many as now, each \"\" when it is \"\" now), and marked (thing and where, both \"\" when no word was marked). Names from the code stay in backticks.",
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
  marked: object({ thing: text, where: text }),
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
// The word placed: the thing it names here, where that lives; else it holds wherever it comes up.
if (word && told?.marked?.thing) words(["place", state, word, told.marked.thing, told.marked.where, note]);
else unplaced();
// Only an answer that fits the case goes over it: as many facts, stops and values as the case has.
const fits = told && told.facts?.length === said.facts.length && told.stops?.length === said.stops.length
  && told.stops.every((stop, i) => stop.values?.length === said.stops[i].values.length);
if (fits) {
  // What the case was told from, with the word just placed, so the pane lays it over this case and no other
  // and knows which of your words it was told with.
  const { marked: _, ...rest } = told;
  writeFileSync(out + ".new", JSON.stringify({ of: part.text, reader: words(["--reader"]).trim(), ...rest }));
  renameSync(out + ".new", out);
}
rmSync(running, { force: true });
