import { check } from "yuke:internal/test";
import { term } from "yuke:internal/native/term";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";

registerRender(defaultRender);
const parts = {
  old: [{ type: "text", id: 0, text: "old committed" }],
  gone: [{ type: "text", id: 0, text: "truncated" }],
  live: [{ type: "reasoning", id: 0, text: "live thought" }],
};
const t = new Transcript({ partsOf: (id) => parts[id] || [] });
const draw = () => { term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: 12 }); term.endFrame(); };
const shows = (text) => t.rows(40, 0, 12).some((r) => (r.segments || []).map(s => s.text).join("").includes(text));
t.setOutline([{ id: "old", type: "assistant" }, { id: "gone", type: "assistant" }], { id: "live", type: "assistant" });
draw();
const oldRows = JSON.stringify(t.rows(40, 0, t.rowCountOf("old")));
const rebuilt = [];
const rowsOf = t._rowsOf;
t._rowsOf = function(m, w, i) { rebuilt.push(String(m.id)); return rowsOf.call(this, m, w, i); };

// A commit reloads the outline: the committed render stays, and only the former draft rebuilds.
t.setOutline([{ id: "old", type: "assistant" }, { id: "gone", type: "assistant" }, { id: "live", type: "assistant" }], null);
const committedCount = t.rowCount(40);
t._rowsOf = rowsOf;
check("old-render-kept", JSON.stringify(t.rows(40, 0, t.rowCountOf("old"))) === oldRows);
check("only-draft-rebuilt", rebuilt.join(",") === "live");

// A truncation removes the rows of the message it cut.
const goneCount = t.rowCountOf("gone");
t.setOutline([{ id: "old", type: "assistant" }, { id: "live", type: "assistant" }], null);
check("truncated-removed", t.rowCountOf("gone") === 0 && t.rowCount(40) === committedCount - goneCount && !shows("truncated"));
