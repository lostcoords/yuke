import { check } from "yuke:test";
import { term } from "yuke:term";
import { Transcript } from "yuke:transcript";
const messages = [];
const parts = {};
for (let i = 0; i < 120; i++) {
  const id = "m" + i;
  messages.push({ id, type: "assistant" });
  parts[id] = [{ type: "text", id: 0, text: "alpha " + i + " bravo charlie delta ".repeat(4) + "\n```zig\nconst x = " + i + ";\n```" }];
}
parts.m0 = [{ type: "reasoning", id: 1, text: "old thought" }, { type: "text", id: 2, text: "old answer" }];
parts.m40 = [{ type: "reasoning", id: 1, text: "middle thought" }, { type: "text", id: 2, text: "middle answer" }];
parts.m119 = [{ type: "tool", id: 3, name: "exec", arguments: '{"command":"old"}', state: { type: "completed", output: "old output" } }];
const make = () => new Transcript({ partsOf: (id) => parts[id] || [] });
const t = make();
t.setOutline(messages, null);
const frame = (w, h) => { term.beginFrame(); t.draw({ x: 0, y: 0, w, h }); term.endFrame(); };
// Each reference message renders alone, so the index under test never checks itself.
const folds = { m0: 1, m119: 3 };
const reference = (w) => messages.flatMap((m) => {
  const one = make();
  one.setOutline([m], null);
  if (folds[m.id] != null) one.togglePart(m.id, folds[m.id]);
  return one.rows(w, 0, one.rowCount(w));
});
let builds = 0;
const rowsOf = t._rowsOf;
t._rowsOf = function(m, w, i) { const c = this._rows.get(String(m.id)); if (!c || c.w !== w) builds++; return rowsOf.call(this, m, w, i); };

for (const id in folds) t.togglePart(id, folds[id]);
const wide = reference(32);
check("total", t.rowCount(32) === wide.length);
frame(32, 8);
check("tail-rows", JSON.stringify(t.rows(32, wide.length - 8, 8)) === JSON.stringify(wide.slice(-8)));
check("tail-sticks", t.pager.atBottom() && t.pager.stuck);
builds = 0;
t.rowCount(32);
t.rows(32, wide.length - 8, 8);
check("warm-tail-builds-nothing", builds === 0);
check("tail-position", t.posAt(4, 7, false)?.id === "m119");

// A selection spans evicted history, and survives an eviction and a resize.
t.select(t.posAtSource("m0", 0), t.posAtSource("m119", 1000000));
const selected = t.selectedText();
const source = t.selectedSource();
check("selection", selected.includes("old thought") && selected.includes("old output") && source.includes("middle answer"));
t.rows(32, 0, 8);
t.rows(32, wide.length - 8, 8);
check("selection-after-eviction", t.selectedText() === selected && t.selectedSource() === source);
const narrow = reference(18);
check("resize-total", t.rowCount(18) === narrow.length);
const plain = (rows) => rows.map(({ sel, ...row }) => row); // the reference holds no selection
check("resize-tail-rows", JSON.stringify(plain(t.rows(18, narrow.length - 8, 8))) === JSON.stringify(narrow.slice(-8)));
check("selection-after-resize", t.selectedSource() === source);

// A fold on an evicted message changes the count and shows at its own location.
t.clearSelection();
t.rows(18, narrow.length - 8, 8);
check("middle-evicted", !t._rows.has("m40"));
const before = t.rowCount(18);
t.togglePart("m40", 1);
check("fold-count", t.rowCount(18) > before);
check("fold-marker", t.rows(18, t._globalRow({ id: "m40", row: 0, col: 0 }), 4).some((r) => r.kind === "reasoning-body"));

// The viewport stays cached whole, and a part motion reads only its neighbours.
t.rows(18, 0, 8);
builds = 0;
t.rows(18, 0, 8);
check("viewport-cached", builds === 0);
builds = 0;
const next = t.partStep({ id: "m50", row: 0, col: 0 }, 1);
const previous = t.partStep(next, -1);
check("part-motion-local", next?.id === "m51" && previous?.id === "m50" && builds <= 4);

// A code-block query over plain text parses on demand and leaves the row index alone.
const code = new Transcript({ textOf: (id) => "```zig\nconst x = " + id + ";\n```" });
code.setOutline(messages, null);
const codeTotal = code.rowCount(32);
builds = 0;
const codeRowsOf = code._rowsOf;
code._rowsOf = function(m, w, i) { builds++; return codeRowsOf.call(this, m, w, i); };
check("code-blocks", code.codeBlocks().length === messages.length && code.rowCount(32) === codeTotal && builds === 0);

// Message ids repeat across sessions, so an empty outline clears even a message whose fold moved after its eviction.
parts.m40 = [{ type: "text", id: 2, text: "other session" }];
t.setOutline([], null);
t.setOutline([{ id: "m40", type: "assistant" }], null);
check("switch-clears-parts", t.rows(18, 0, 4).some((r) => (r.segments || []).map(s => s.text).join("").includes("other session")));
