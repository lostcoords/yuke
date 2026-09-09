import { check } from "yuke:test";
import { term } from "yuke:term";
import { Transcript } from "yuke:transcript";
const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0) || (r.text || "").indexOf(want) >= 0);
const markerOf = (rs) => ((rs.find((r) => r.kind === "reasoning-header") || {}).marker || "").trimStart();
// A collapsed thought keeps its title on the header row, so the body rows report the fold.
const hasBody = (rs) => rs.some((r) => r.kind === "reasoning-body");

const parts = {};
const t = new Transcript({ textOf: (id) => (id === "u" ? "ask" : ""), partsOf: (id) => parts[id] || [] });

parts.r1 = [{ type: "reasoning", id: 0, text: "because why" }];
t.setOutline([], { id: "r1", type: "assistant" });
term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: 10 }); term.endFrame();
let rs = t.rows(40, 0, 10);
check("live-name", rowsHave(rs, "thinking"));
check("live-body", rowsHave(rs, "because") && markerOf(rs) === "└─");
check("thought-style", rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf("because") >= 0 && sg.group === "TxThought")));

parts.r1 = [{ type: "reasoning", id: 0, text: "because why" }, { type: "text", id: 1, text: "hello" }];
t.setActive("r1");
rs = t.rows(40, 0, 10);
check("text-collapses-thought", rowsHave(rs, "thought") && rowsHave(rs, "· because why") && !rowsHave(rs, "thinking") && !hasBody(rs) && rowsHave(rs, "hello") && markerOf(rs) === "└─");

t.setOutline([{ id: "r1", type: "assistant" }], null);
rs = t.rows(40, 0, 10);
check("commit-hides", rowsHave(rs, "thought") && !rowsHave(rs, "thinking") && markerOf(rs) === "└─" && !hasBody(rs));

t.togglePart("r1", 0);
rs = t.rows(40, 0, 10);
check("override-holds", markerOf(rs) === "└─" && hasBody(rs));

t.setOutline([{ id: "u", type: "user" }, { id: "r1", type: "assistant" }, { id: "u2", type: "user" }], { id: "r2", type: "assistant" });
rs = t.rows(40, t._globalRow({ id: "r1", row: 0, col: 0 }), 8);
check("later-send-keeps-override", markerOf(rs) === "└─" && hasBody(rs));

const num = new Transcript({ textOf: () => "", partsOf: () => [{ type: "reasoning", id: 0, text: "because why" }] });
num.setOutline([{ id: 2, type: "assistant" }], null);
term.beginFrame(); num.draw({ x: 0, y: 0, w: 40, h: 10 }); term.endFrame();
num.togglePart(2, 0);
num.setOutline([{ id: 2, type: "assistant" }, { id: 3, type: "user" }], { id: 4, type: "assistant" });
check("num-id-later-send", hasBody(num.rows(40, num._globalRow({ id: 2, row: 0, col: 0 }), 8)));

const committed = new Transcript({ textOf: () => "", partsOf: () => [{ type: "reasoning", id: 0, text: "later" }] });
committed.setOutline([{ id: "c", type: "assistant" }], null);
term.beginFrame(); committed.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
check("commit-collapsed", markerOf(committed.rows(40, 0, 6)) === "└─" && rowsHave(committed.rows(40, 0, 6), "thought") && rowsHave(committed.rows(40, 0, 6), "· later") && !hasBody(committed.rows(40, 0, 6)));

const titled = new Transcript({ textOf: () => "", partsOf: () => [{ type: "reasoning", id: 0, text: "**Clarifying the constraints**\n\nthe body" }] });
titled.setOutline([{ id: "tt", type: "assistant" }], null);
term.beginFrame(); titled.draw({ x: 0, y: 0, w: 60, h: 8 }); term.endFrame();
check("bold-title", rowsHave(titled.rows(60, 0, 6), "\u00b7 Clarifying the constraints") && !hasBody(titled.rows(60, 0, 6)));

const blank = new Transcript({ textOf: () => "answer", partsOf: () => [{ type: "reasoning", id: 0, text: "" }, { type: "text", id: 1, text: "answer" }] });
blank.setOutline([{ id: "bl", type: "assistant" }], null);
term.beginFrame(); blank.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
const blankRows = blank.rows(40, 0, 8);
check("empty-reasoning-skipped", !blankRows.some((r) => r.kind === "reasoning-header") && rowsHave(blankRows, "answer"));

parts.hid = [{ type: "redacted_reasoning", id: 0 }, { type: "text", id: 1, text: "visible" }];
const hid = new Transcript({ textOf: () => "visible", partsOf: (id) => parts[id] || [] });
hid.setOutline([{ id: "hid", type: "assistant" }], null);
term.beginFrame(); hid.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
const hrs = hid.rows(40, 0, 8);
check("redacted-skip", rowsHave(hrs, "visible") && !rowsHave(hrs, "thought") && !rowsHave(hrs, "thinking"));

parts.walk = [
  { type: "reasoning", id: 0, text: "why" },
  { type: "tool", id: 1, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "x", duration_ms: 1 } },
  { type: "text", id: 2, text: "hello" },
];
const w = new Transcript({ textOf: (id) => (id === "u" ? "ask" : ""), partsOf: (id) => parts[id] || [] });
w.setOutline([{ id: "u", type: "user" }, { id: "walk", type: "assistant" }], null);
term.beginFrame(); w.draw({ x: 0, y: 0, w: 40, h: 16 }); term.endFrame();
const p0 = { id: "u", row: 0, col: 0 };
const p1 = w.partStep(p0, 1);
check("jk-reason", p1 && w.partAt(p1) && w.partAt(p1).kind === "reasoning-header");
const p2 = w.partStep(p1, 1);
check("jk-tool", p2 && w.partAt(p2) && w.partAt(p2).kind === "tool-header");
const p3 = w.partStep(p2, 1);
check("jk-text", p3 && w.partAt(p3) && w.partAt(p3).kind === "text");
const back = w.partStep(p3, -1);
check("jk-back", back && back.id === p2.id && back.row === p2.row);

const pack = new Transcript({ textOf: (id) => (id === "k" ? "kept the tail" : ""), partsOf: () => [] });
pack.setOutline([{ id: "k", type: "compaction" }], null);
term.beginFrame(); pack.draw({ x: 0, y: 0, w: 40, h: 6 }); term.endFrame();
check("compaction", rowsHave(pack.rows(40, 0, 6), "kept the tail"));

t.setOutline([{ id: "r1", type: "assistant" }], { id: "r2", type: "assistant" });
rs = t.rows(40, t._globalRow({ id: "r1", row: 0, col: 0 }), 8);
check("expand-survives-outline", markerOf(rs) === "└─" && hasBody(rs));

const mix = new Transcript({ textOf: () => "hello", partsOf: () => [{ type: "text", id: 0, text: "hello" }, { type: "tool", id: 1, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "ok", duration_ms: 1 } }] });
mix.setOutline([{ id: "m1", type: "assistant" }], { id: "m1", type: "assistant" });
term.beginFrame(); mix.draw({ x: 0, y: 0, w: 40, h: 10 }); term.endFrame();
mix.select({ id: "m1", row: 0, col: 0 }, mix.posAtSource("m1", mix._sourceOf("m1").length));
check("mix-had-sel", mix.selectedText() !== "");
mix.setActive("m1");
check("mix-sel-lives", mix.selection != null && mix.selectedText() !== "");

const et = new Transcript({ textOf: () => "hi", partsOf: () => [{ type: "text", id: 0, text: "hi" }] });
et.setOutline([{ id: "e1", type: "assistant", error: { type: "x", message: "boom" } }], null);
term.beginFrame(); et.draw({ x: 0, y: 0, w: 40, h: 10 }); term.endFrame();
let er = -1;
const en = et.rowCountOf("e1");
for (let i = 0; i < en; i++) if (et.rowTextAt("e1", i).indexOf("boom") >= 0) er = i;
check("err-row", er >= 0);
et.select({ id: "e1", row: er, col: 0 }, { id: "e1", row: er, col: et.rowTextAt("e1", er).length });
check("err-sel", et.selectedText().indexOf("boom") >= 0);
check("err-src", et.sourceAt({ id: "e1", row: er, col: 1 }) >= 0);
