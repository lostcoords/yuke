import { check, textParts } from "yuke:internal/test";
import { term } from "yuke:internal/native/term";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";

registerRender(defaultRender);
const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0) || (r.text || "").indexOf(want) >= 0);
const draw = (x, w, h) => { term.beginFrame(); x.draw({ x: 0, y: 0, w, h }); term.endFrame(); };

// A thought folds to one header while it streams, and a thought that the user opens stays open across the commit.
const thought = { type: "reasoning", id: 0, text: "**Plan**\n\nbecause why", title: "Plan" };
const parts = { u: [{ type: "text", id: 0, text: "ask" }], r1: [thought] };
const t = new Transcript({ partsOf: (id) => parts[id] || [] });
t.setOutline([], { id: "r1", type: "assistant" });
draw(t, 40, 10);
check("thought-folded", rowsHave(t.rows(40, 0, 10), "thinking: Plan") && !rowsHave(t.rows(40, 0, 10), "because why"));
t.togglePart("r1", 0);
check("thought-opens", t.rows(40, 0, 10).some((r) => r.text === "because why" && r.group === "TxThought"));
// A block stops before the next part starts, so its duration ends the live label in the draft.
parts.r1 = [{ ...thought, duration_ms: 1500 }];
t.setActive("r1");
check("stopped-in-draft", rowsHave(t.rows(40, 0, 10), "thought for 1.5s: Plan"));
parts.r1 = [{ ...thought, duration_ms: 1500 }, { type: "text", id: 1, text: "hello" }];
t.setActive("r1");
t.setOutline([{ id: "r1", type: "assistant" }], null);
check("commit-keeps-open", rowsHave(t.rows(40, 0, 10), "thought for 1.5s: Plan") && rowsHave(t.rows(40, 0, 10), "because why"));

// A fold choice holds across a later send, for string and number ids.
parts.r3 = [{ type: "tool", id: 2, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "file body", duration_ms: 1 } }];
t.setOutline([{ id: "r1", type: "assistant" }, { id: "r3", type: "assistant" }], null);
check("read-folded", !rowsHave(t.rows(40, 0, 20), "file body"));
t.togglePart("r3", 2);
t.setOutline([{ id: "u", type: "user" }, { id: "r1", type: "assistant" }, { id: "r3", type: "assistant" }, { id: "u2", type: "user" }], { id: "r2", type: "assistant" });
check("later-send-keeps-choice", rowsHave(t.rows(40, 0, t.rowCount(40)), "file body"));
const num = new Transcript({ partsOf: () => [{ type: "tool", id: 0, name: "read", arguments: "{}", state: { type: "completed", output: "num body", duration_ms: 1 } }] });
num.setOutline([{ id: 2, type: "assistant" }], null);
draw(num, 40, 10);
num.togglePart(2, 0);
num.setOutline([{ id: 2, type: "assistant" }, { id: 3, type: "user" }], { id: 4, type: "assistant" });
check("num-id-later-send", rowsHave(num.rows(40, 0, num.rowCount(40)), "num body"));

// A hidden thought with a duration shows the duration on a row that does not fold. A hidden thought with no duration shows nothing.
const blank = new Transcript({ partsOf: () => [
  { type: "reasoning", id: 0, text: "", duration_ms: 2000 },
  { type: "reasoning", id: 1, text: "" },
  { type: "text", id: 2, text: "answer" },
] });
blank.setOutline([{ id: "bl", type: "assistant" }], null);
draw(blank, 40, 8);
const blankRows = blank.rows(40, 0, 8);
check("hidden-thought-row", rowsHave([blankRows[0]], "thought for 2.0s") && !blankRows[0].header && blankRows.filter((r) => rowsHave([r], "thought")).length === 1 && rowsHave(blankRows, "answer"));

// J and K walk the parts: the thought, the tool header, then the text.
parts.walk = [
  { type: "reasoning", id: 0, text: "why" },
  { type: "tool", id: 1, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "x", duration_ms: 1 } },
  { type: "text", id: 2, text: "hello" },
];
const w = new Transcript({ partsOf: (id) => parts[id] || [] });
w.setOutline([{ id: "u", type: "user" }, { id: "walk", type: "assistant" }], null);
draw(w, 40, 16);
const p1 = w.partStep({ id: "u", row: 0, col: 0 }, 1);
check("jk-reason", p1 && w.partAt(p1)?.partId === 0);
const p2 = w.partStep(p1, 1);
check("jk-tool", p2 && w.partAt(p2)?.partId === 1 && w.partAt(p2)?.row.header === true);
const p3 = w.partStep(p2, 1);
check("jk-text", p3 && w.partAt(p3)?.row.kind === "text");
const back = w.partStep(p3, -1);
check("jk-back", back && back.id === p2.id && back.row === p2.row);

const pack = new Transcript({ partsOf: textParts((id) => (id === "k" ? "kept the tail" : "")) });
pack.setOutline([{ id: "k", type: "compaction" }], null);
draw(pack, 40, 6);
check("compaction", rowsHave(pack.rows(40, 0, 6), "kept the tail"));

// A selection lives through a streamed delta.
const mix = new Transcript({ partsOf: () => [{ type: "text", id: 0, text: "hello" }, { type: "tool", id: 1, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "ok", duration_ms: 1 } }] });
mix.setOutline([{ id: "m1", type: "assistant" }], { id: "m1", type: "assistant" });
draw(mix, 40, 10);
mix.select({ id: "m1", row: 0, col: 0 }, mix.posAtSource("m1", mix._sourceOf("m1").length));
check("mix-had-sel", mix.selectedText() !== "");
mix.setActive("m1");
check("mix-sel-lives", mix.selection != null && mix.selectedText() !== "");

// An error row selects and maps to source.
const et = new Transcript({ partsOf: () => [{ type: "text", id: 0, text: "hi" }] });
et.setOutline([{ id: "e1", type: "assistant", error: { type: "x", message: "boom" } }], null);
draw(et, 40, 10);
let er = -1;
for (let i = 0; i < et.rowCountOf("e1"); i++) if (et.rowTextAt("e1", i).indexOf("boom") >= 0) er = i;
check("err-row", er >= 0);
et.select({ id: "e1", row: er, col: 0 }, { id: "e1", row: er, col: et.rowTextAt("e1", er).length });
check("err-sel", et.selectedText().indexOf("boom") >= 0);
check("err-src", et.sourceAt({ id: "e1", row: er, col: 1 }) >= 0);
