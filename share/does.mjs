#!/usr/bin/env node
// does.mjs [--json] [<base> <head> | <range> | <branch>]: what a change does, and when, read from
// the syntax trees. Nothing runs and no model is asked: the same change gives the same answer.
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { basename } from "node:path";

const started = Date.now();
const run = (command, args) => execFileSync(command, args, { encoding: "utf8", maxBuffer: 1 << 28, stdio: ["ignore", "pipe", "ignore"] });
const git = (...args) => run("git", args).trim();
const words = process.argv.slice(2).filter((word) => word !== "--json");
const json = process.argv.includes("--json");

/** No argument is this branch since it left main; one is a branch or a range; two are before and after. */
const [base, head] = (() => {
  const [one, two] = words;
  if (two) return [one, two];
  const trunk = (() => { try { return git("rev-parse", "--verify", "--quiet", "origin/main"); } catch { return git("rev-parse", "main"); } })();
  if (!one) return [git("merge-base", trunk, "HEAD"), "HEAD"];
  if (one.includes("...")) return [git("merge-base", ...one.split("...").map((rev) => rev || "HEAD")), one.split("...")[1] || "HEAD"];
  if (one.includes("..")) return one.split("..").map((rev) => rev || "HEAD");
  return [git("merge-base", trunk, one), one];
})();

// The theme otis has loaded, else gruvbox dark, which is what seam's page is in.
const theme = (name, rgb) => process.env[name] || `38;2;${rgb}`;
const HUES = {
  fg: theme("OTIS_T_TEXT", "235;219;178"), red: theme("OTIS_T_BAD", "251;73;52"), green: theme("OTIS_T_GOOD", "184;187;38"),
  yellow: theme("OTIS_T_ATTENTION", "250;189;47"), gray: theme("OTIS_T_CONTEXT", "146;131;116"), purple: "38;2;211;134;155", aqua: "38;2;142;192;124",
};
const colored = json || process.stdout.isTTY || process.env.FORCE_COLOR;
const paint = (codes, text) => (colored ? `\x1b[${codes}m${text}\x1b[0m` : text);
const hue = Object.fromEntries(Object.entries(HUES).map(([name, codes]) => [name, (text) => paint(codes, text)]));
const strong = (name, text) => paint(`1;${HUES[name]}`, text);

/** A line of code in the theme's hues: keywords red, strings green, constants purple, what is called aqua. */
const TOKEN = /("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)|\b(return|throw|if|else|switch|case|while|await|new|typeof|not|is|calls)\b|\b(null|undefined|true|false|\d+(?:\.\d+)?)\b|([A-Za-z_$][\w$]*)(?=\()/g;
function code(text) {
  let out = "";
  let at = 0;
  for (const match of text.matchAll(TOKEN)) {
    out += hue.fg(text.slice(at, match.index));
    out += match[1] ? hue.green(match[0]) : match[2] ? hue.red(match[0]) : match[3] ? hue.purple(match[0]) : hue.aqua(match[0]);
    at = match.index + match[0].length;
  }
  return out + hue.fg(text.slice(at));
}

const squeeze = (text) => text.replace(/\s+/g, " ").replace(/,\s*([)\]}])/g, " $1").replace(/\(\s+/g, "(").replace(/\s+\)/g, ")").trim();
const clip = (text, most = 140) => (text.length > most ? `${text.slice(0, most - 1)}…` : text);

/** The repo's own TypeScript reads the code, where it has one. */
const ts = (() => {
  try {
    return createRequire(`${git("rev-parse", "--show-toplevel")}/`)("typescript");
  } catch {
    return null;
  }
})();

const parsed = new Map();
function source(rev, path) {
  const key = `${rev}:${path}`;
  if (!parsed.has(key)) parsed.set(key, ts.createSourceFile(path, run("git", ["show", key]), ts.ScriptTarget.Latest, true));
  return parsed.get(key);
}

/** The function a definition names, by its name and the lines seam says it is on. */
function find(file, name, range) {
  let found = null;
  const visit = (node) => {
    if (found) return;
    const line = file.getLineAndCharacterOfPosition(node.getStart(file)).line + 1;
    if (line >= range.start && line <= range.end) {
      if ((ts.isFunctionDeclaration(node) || ts.isMethodDeclaration(node)) && node.name?.getText(file) === name && node.body) found = node;
      else if (ts.isVariableDeclaration(node) && node.name.getText(file) === name && node.initializer && (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer))) found = node.initializer;
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  return found;
}

const FLIP = { "===": "!==", "!==": "===", "==": "!=", "!=": "==", "<": ">=", ">=": "<", ">": "<=", "<=": ">" };

/** Everything a function does, each with the conditions that lead to it: [{key, text, when, notes, detail}]. */
function deeds(fn, file) {
  const out = [];
  const locals = new Map();
  const text = (node) => squeeze(node.getText(file));
  const bare = (node) => (ts.isParenthesizedExpression(node) ? bare(node.expression) : node);

  // A condition as the things that must all hold: a && b is two of them, and so is not (a || b).
  const holds = (node) => {
    node = bare(node);
    if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) return [...holds(node.left), ...holds(node.right)];
    if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.ExclamationToken) return fails(node.operand);
    return [text(node)];
  };
  const fails = (node) => {
    node = bare(node);
    if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.BarBarToken) return [...fails(node.left), ...fails(node.right)];
    if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.ExclamationToken) return holds(node.operand);
    if (ts.isBinaryExpression(node) && FLIP[node.operatorToken.getText(file)]) return [`${text(node.left)} ${FLIP[node.operatorToken.getText(file)]} ${text(node.right)}`];
    return [`not ${ts.isBinaryExpression(node) ? `(${text(node)})` : text(node)}`];
  };
  const exits = (statement) =>
    !statement ? false
      : ts.isReturnStatement(statement) || ts.isThrowStatement(statement) || ts.isContinueStatement(statement) || ts.isBreakStatement(statement) ? true
      : ts.isBlock(statement) ? exits(statement.statements[statement.statements.length - 1])
      : ts.isIfStatement(statement) ? exits(statement.thenStatement) && exits(statement.elseStatement)
      : false;

  const deed = (key, shown, when, detail = "") => {
    // A condition that is a local name says what the name stands for.
    const notes = when.map((item) => item.replace(/^not /, "")).filter((item) => locals.has(item)).map((item) => `${item} = ${locals.get(item)}`);
    out.push({ key, text: shown, when, notes, detail });
  };
  const inside = (callback) => `inside ${clip(text(callback.parent.expression ?? callback.parent), 40)}(…)`;
  // The calls an expression makes when it runs, and what any callback handed to them does.
  const calls = (node, when) => {
    const visit = (child) => {
      if (ts.isFunctionLike(child)) {
        if (child.body && ts.isBlock(child.body)) block(child.body.statements, [...when, inside(child)]);
        return;
      }
      if (ts.isCallExpression(child)) deed(`calls ${text(child.expression)}`, `calls ${text(child.expression)}`, when, clip(text(child), 170));
      ts.forEachChild(child, visit);
    };
    visit(node);
  };
  const leave = (statement, when) => {
    const word = ts.isReturnStatement(statement) ? "return" : "throw";
    const value = statement.expression && bare(ts.isAwaitExpression(statement.expression) ? statement.expression.expression : statement.expression);
    if (value && ts.isConditionalExpression(value)) {
      // The outcome that is something comes first, so one choice written the other way round still pairs.
      const nothing = (node) => /^(null|undefined|false)$/.test(text(node));
      const flip = nothing(value.whenTrue) && !nothing(value.whenFalse);
      const [yes, no] = (flip ? [value.whenFalse, value.whenTrue] : [value.whenTrue, value.whenFalse]).map(text);
      deed(`${word} ${yes} | ${no}`, `${word} ${yes}  else  ${no}`, [...when, ...(flip ? fails(value.condition) : holds(value.condition))]);
      return;
    }
    if (value && ts.isBinaryExpression(value) && value.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
      deed(`${word} true | false`, `${word} true  else  false`, [...when, ...holds(value)]);
      return;
    }
    if (value) {
      // What a callback handed to the returned call decides is the function's own deciding.
      const visit = (child) => {
        if (ts.isFunctionLike(child) && child.body && ts.isBlock(child.body)) block(child.body.statements, [...when, inside(child)]);
        else ts.forEachChild(child, visit);
      };
      visit(value);
    }
    const shown = value ? clip(text(value).replace(/=> \{.*\}/, "=> { … }"), 110) : "";
    deed(`${word} ${shown}`, `${word} ${shown}`.trim(), when);
  };
  const statementOf = (statement, when) => {
    if (ts.isBlock(statement)) return block(statement.statements, when);
    if (ts.isIfStatement(statement)) {
      statementOf(statement.thenStatement, [...when, ...holds(statement.expression)]);
      if (statement.elseStatement) statementOf(statement.elseStatement, [...when, ...fails(statement.expression)]);
      return;
    }
    if (ts.isSwitchStatement(statement)) {
      let labels = [];
      for (const clause of statement.caseBlock.clauses) {
        labels.push(ts.isDefaultClause(clause) ? "anything else" : text(clause.expression));
        if (clause.statements.length === 0) continue;
        block(clause.statements, [...when, `${text(statement.expression)} is ${labels.join(" | ")}`]);
        labels = [];
      }
      return;
    }
    if (ts.isReturnStatement(statement) || ts.isThrowStatement(statement)) return leave(statement, when);
    if (ts.isTryStatement(statement)) {
      block(statement.tryBlock.statements, when);
      if (statement.catchClause) block(statement.catchClause.block.statements, [...when, "after an error"]);
      if (statement.finallyBlock) block(statement.finallyBlock.statements, when);
      return;
    }
    if (ts.isIterationStatement(statement, false)) {
      const header = squeeze(statement.getText(file).slice(0, statement.statement.getStart(file) - statement.getStart(file)));
      return statementOf(statement.statement, [...when, `in ${clip(header, 60)}`]);
    }
    if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        if (!declaration.initializer) continue;
        if (ts.isIdentifier(declaration.name)) locals.set(declaration.name.text, clip(text(declaration.initializer), 150));
        calls(declaration.initializer, when);
        // A name given one call's answer is that call. Any other value is a thing it sets.
        const value = bare(ts.isAwaitExpression(declaration.initializer) ? declaration.initializer.expression : declaration.initializer);
        if (!ts.isCallExpression(value)) deed(`sets ${text(declaration.name)}`, `sets ${text(declaration.name)}`, when, clip(text(declaration), 170));
      }
      return;
    }
    if (ts.isExpressionStatement(statement)) {
      calls(statement.expression, when);
      const set = bare(statement.expression);
      const assigns = ts.isBinaryExpression(set) && set.operatorToken.kind >= ts.SyntaxKind.FirstAssignment && set.operatorToken.kind <= ts.SyntaxKind.LastAssignment;
      if (assigns) deed(`sets ${text(set.left)}`, `sets ${text(set.left)}`, when, clip(text(set), 170));
      else if (ts.isPrefixUnaryExpression(set) || ts.isPostfixUnaryExpression(set) || ts.isDeleteExpression(set)) deed(`sets ${text(set)}`, `sets ${text(set)}`, when, text(set));
    }
  };
  // After an if that always leaves, the rest of the block runs only when its condition failed.
  const block = (statements, when) => {
    let since = [];
    for (const statement of statements) {
      statementOf(statement, [...when, ...since]);
      if (ts.isIfStatement(statement) && !statement.elseStatement && exits(statement.thenStatement)) since = [...since, ...fails(statement.expression)];
    }
  };
  if (ts.isBlock(fn.body)) block(fn.body.statements, []);
  else deed(`return ${text(fn.body)}`, `return ${clip(text(fn.body), 110)}`, []);
  return out;
}

/** Deeds that are in one side and not the other, paired by what they do: [{before, after}], either one absent. */
function compare(before, after) {
  const cases = (deed) => deed.when.join("\n");
  const same = (a, b) => a.key === b.key && cases(a) === cases(b) && a.detail === b.detail;
  const left = before.filter((deed) => !after.some((other) => same(deed, other)));
  const right = after.filter((deed) => !before.some((other) => same(deed, other)));
  const pairs = [];
  const word = (deed) => deed.key.split(" ")[0];
  for (const deed of right) {
    // The same deed in the same cases first, then the same deed, then another answer in the same cases.
    let at = left.findIndex((other) => other.key === deed.key && cases(other) === cases(deed));
    if (at < 0) at = left.findIndex((other) => other.key === deed.key);
    if (at < 0 && word(deed) !== "calls") at = left.findIndex((other) => word(other) === word(deed) && cases(other) === cases(deed));
    pairs.push({ before: at >= 0 ? left.splice(at, 1)[0] : null, after: deed });
  }
  return [...pairs, ...left.map((deed) => ({ before: deed, after: null }))];
}

const minus = hue.red("-");
const plus = hue.green("+");
const when = (items) => items.map((item) => clip(item, 110)).join("  ·  ");

/** Two lines with what differs between them on a ground of its own, as delta does. */
function marked(before, after) {
  let same = 0;
  while (same < before.length && same < after.length && before[same] === after[same]) same++;
  while (same > 0 && /[\w$.]/.test(before[same - 1])) same--;
  let tail = 0;
  while (tail < before.length - same && tail < after.length - same && before[before.length - 1 - tail] === after[after.length - 1 - tail]) tail++;
  while (tail > 0 && /[\w$.]/.test(before[before.length - tail])) tail--;
  const cut = (text, ground) => code(text.slice(0, same)) + paint(`1;${HUES.fg};48;2;${ground}`, text.slice(same, text.length - tail)) + code(text.slice(text.length - tail));
  return [cut(before, "110;38;30"), cut(after, "66;72;30")];
}
const pair = (out, gone, added, indent) => {
  const [was, now] = gone.length === 1 && added.length === 1 ? marked(clip(gone[0], 170), clip(added[0], 170)) : [null, null];
  gone.forEach((item) => out.push(`${indent}${minus} ${was ?? code(clip(item, 170))}`));
  added.forEach((item) => out.push(`${indent}${plus} ${now ?? code(clip(item, 170))}`));
};

/** What a changed function does differently, as lines: each deed, when, and what about the when moved. */
function differing(pairs) {
  const out = [];
  // Calls that came or went in the same cases are one entry.
  const entries = [];
  for (const each of pairs) {
    const deed = each.after ?? each.before;
    const last = entries[entries.length - 1];
    const lone = !(each.before && each.after) && deed.key.startsWith("calls ");
    if (lone && last?.lone && !last.before === !each.before && last.deed.when.join() === deed.when.join()) last.names.push(deed.key.slice(6));
    else entries.push({ ...each, deed, lone, names: [deed.key.slice(6)] });
  }
  for (const { before, after, deed, lone, names } of entries) {
    const both = before && after;
    const shared = both ? after.when.filter((item) => before.when.includes(item)) : deed.when;
    const retold = both && before.key !== after.key;
    const title = lone ? `calls ${[...new Set(names)].join(", ")}` : retold ? deed.key.split(" ")[0] : deed.text;
    const lead = !before ? `${plus} ` : !after ? `${minus} ` : "  ";
    const said = !before ? "   new" : !after ? "   no longer" : retold ? "   gives something else" : "";
    out.push(`${lead}${code(title)}${hue.gray(said)}`);
    if (shared.length > 0) out.push(`    ${hue.gray(`when  ${when(shared)}`)}`);
    if (both) {
      if (retold) pair(out, [before.text.replace(/^\w+ /, "")], [after.text.replace(/^\w+ /, "")], "      ");
      pair(out, before.when.filter((item) => !after.when.includes(item)), after.when.filter((item) => !before.when.includes(item)), "      ");
      if (before.detail !== after.detail && !retold) pair(out, [before.detail], [after.detail], "      ");
      // What a name stands for, only for the conditions that differ.
      const differs = [...before.when, ...after.when].filter((item) => !(before.when.includes(item) && after.when.includes(item))).map((item) => item.replace(/^not /, ""));
      for (const note of new Set([...before.notes, ...after.notes])) {
        if (differs.includes(note.split(" = ")[0])) out.push(`        ${hue.gray(clip(note, 150))}`);
      }
    }
    out.push("");
  }
  out.pop();
  return out;
}

/** What one changed definition does, as {state, lines}: differs, same, new, gone, types or unread. */
function read(definition) {
  if (definition.kind === "type" || definition.kind === "interface") return { state: "types", lines: [hue.gray("a type: it cannot change what runs")] };
  if (!ts || !/\.[cm]?[jt]sx?$/.test(definition.path)) return { state: "unread", lines: [hue.gray(ts ? "not read: no rules for this language yet" : "not read: this repo has no typescript package to read it with")] };
  const here = { start: definition.start, end: definition.end };
  if (definition.change === "removed") return { state: "gone", lines: [hue.gray("gone: nothing does this any more")] };
  const nowFile = source(head, definition.path);
  const now = find(nowFile, definition.name, here);
  if (definition.change === "added") {
    const list = now ? deeds(now, nowFile) : [];
    const lines = list.filter((deed) => !deed.key.startsWith("calls ")).map((deed) => `${code(deed.text)}${deed.when.length ? hue.gray(`   when  ${when(deed.when)}`) : ""}`);
    const called = [...new Set(list.filter((deed) => deed.key.startsWith("calls ")).map((deed) => deed.key.slice(6)))];
    if (called.length > 0) lines.push(`${hue.gray("calls")}  ${called.map((name) => hue.aqua(name)).join("  ")}`);
    return { state: "new", lines: lines.length > 0 ? lines : [hue.gray("new, and not a function: read its lines")] };
  }
  const same = { state: "same", lines: [hue.gray("only its comments or layout changed: the code is the same, token for token")] };
  const unread = { state: "unread", lines: [hue.gray("it changed in a way this does not read: read its lines")] };
  // Every token of a piece of code, comments left out: equal lists are the same code.
  const tokens = (node, file) => {
    if (node.kind >= ts.SyntaxKind.FirstJSDocNode && node.kind <= ts.SyntaxKind.LastJSDocNode) return [];
    const parts = node.getChildren(file);
    return parts.length > 0 ? parts.flatMap((part) => tokens(part, file)) : [node.getText(file)];
  };
  const wasFile = source(base, definition.path);
  const was = find(wasFile, definition.name, definition.base);
  if (!now || !was) {
    // Not a function: a value. Its lines, less the comments.
    const lines = (rev, range) => run("git", ["show", `${rev}:${definition.path}`]).split("\n").slice(range.start - 1, range.end)
      .filter((line) => !/^\s*(\/\/|\/\*|\*)/.test(line)).map(squeeze).filter(Boolean);
    const [old, fresh] = [lines(base, definition.base), lines(head, here)];
    const out = [];
    pair(out, old.filter((line) => !fresh.includes(line)), fresh.filter((line) => !old.includes(line)), "");
    return out.length > 0 ? { state: "differs", lines: out } : old.join("\n") === fresh.join("\n") ? same : unread;
  }
  const pairs = compare(deeds(was, wasFile), deeds(now, nowFile));
  if (pairs.length > 0) return { state: "differs", lines: differing(pairs) };
  return tokens(was, wasFile).join(" ") === tokens(now, nowFile).join(" ") ? same : unread;
}

const seam = JSON.parse(run("seam", [`${base}..${head}`, "--json"]));
const isTest = (definition) => definition.box?.kind !== "source" || /(\.spec\.|\.test\.|test-utils|__tests__)/.test(definition.path);
const results = seam.definitions.map((definition) => ({ definition, ...read(definition) }));
const counted = (state) => results.filter((result) => result.state === state && !isTest(result.definition));
const summary = `${counted("differs").length} do something different · ${counted("new").length} new · ${counted("gone").length} gone · ${counted("unread").length} to read by hand · ${counted("same").length + counted("types").length} that cannot change what runs`;

if (json) {
  const definitions = Object.fromEntries(results.map(({ definition, state, lines }) => [definition.id, { state, lines }]));
  console.log(JSON.stringify({ summary, definitions }));
} else {
  const out = [strong("yellow", summary)];
  out.push(hue.gray("Each entry is one thing the code does, then when it does it. Gray conditions are the same as before;"));
  out.push(hue.gray("a - condition is no longer needed, and a + condition is needed now."));
  const title = ({ definition }) => `${strong("fg", definition.name)}  ${hue.gray(`${basename(definition.path)}:${definition.start}`)}`;
  for (const result of counted("differs")) out.push("", `  ${title(result)}`, "", ...result.lines.map((line) => `    ${line}`));
  if (counted("new").length > 0) out.push("", strong("yellow", "new"));
  for (const result of counted("new")) out.push("", `  ${plus} ${title(result)}`, ...result.lines.map((line) => `      ${line}`));
  if (counted("gone").length > 0) out.push("", strong("yellow", "gone"), `  ${counted("gone").map(({ definition }) => `${minus} ${hue.fg(definition.name)}`).join("   ")}`);
  out.push("");
  const names = (state) => counted(state).map(({ definition }) => definition.name).join(", ");
  if (counted("unread").length > 0) out.push(hue.yellow(`changed in a way this does not read, so read their lines: ${names("unread")}`));
  if (counted("same").length > 0) out.push(hue.gray(`only comments or layout changed, the code is the same: ${names("same")}`));
  if (counted("types").length > 0) out.push(hue.gray(`types only: ${names("types")}`));
  const tests = new Set(seam.definitions.filter(isTest).map((definition) => definition.path));
  if (tests.size > 0) out.push(hue.gray(`tests, not listed here: ${tests.size} files`));
  out.push(hue.gray(`${Date.now() - started}ms, of which seam took most`));
  console.log(out.join("\n"));
}
