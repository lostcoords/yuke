import { fuzzyRank } from "yuke:internal/fzy";

// A picker source: session titles, commands, and paths, with capitals, separators, and non-ASCII text.
/** @type {string[]} */
const items = [];
for (let i = 0; i < 100; i++) {
  items.push("Fix the render loop in session " + i + " after a resize");
  items.push("session:interrupt-" + i);
  items.push("src/js/app/" + ["fzy", "transcript", "ChatView", "café", "日本語"][i % 5] + "_" + i + ".js");
}
// One query per keystroke, so the ranks cover both the wide early matches and the narrow late rejections.
const queries = ["f", "fi", "fix", "fixr", "fixre", "fixren"];
let expected = -1, steps = 0;

function rankAll() {
  let matched = 0;
  for (const query of queries) matched += fuzzyRank(items, query, (text) => text).length;
  return matched;
}

function start() {
  expected = rankAll();
  steps = 0;
  return expected;
}

function step() {
  const matched = rankAll();
  if (matched !== expected) throw Error("fuzzy rank changed between steps");
  steps++;
  return matched;
}

function verify() { return steps; }
globalThis.bench = { start, step, verify };
