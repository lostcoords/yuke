// The tree example rebuilds the grouped look through the render API alone. The Zig case imports it as globalThis.treeLook.
import { check, equal, detailSections } from "yuke:internal/test";
import { root } from "yuke:internal/core";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";

registerRender(defaultRender);
registerRender(globalThis.treeLook);

const rowText = (r) => r.text || (r.segments || []).map((s) => s.text).join("");
const tool = (id, name) => ({ type: "tool", id, name, arguments: '{"value":"' + name + '"}', state: { type: "completed", output: name + " output", duration_ms: id } });

// Consecutive tool calls and thoughts group across messages under one header, and text closes the group.
const parts = {
  a: [tool(1, "one"), tool(2, "two")],
  b: [{ type: "reasoning", id: 3, text: "**Continued analysis**\n\nbody", title: "Continued analysis", duration_ms: 4000 }, tool(4, "three")],
  c: [{ type: "text", id: 5, text: "visible answer" }, tool(6, "four")],
};
const t = new Transcript({ partsOf: (id) => parts[id] || [] });
t.setOutline([{ id: "a", type: "assistant" }, { id: "b", type: "assistant" }, { id: "c", type: "assistant" }], null);
const rows = t.rows(60, 0, t.rowCount(60));
const tools = rows.filter((r) => r.kind === "tool-header");
check("one-group", rows.filter((r) => rowText(r) === "4 actions").length === 1 && rows.filter((r) => rowText(r) === "1 action").length === 1);
check("tree", tools.map((r) => r.marker).join(",") === "  ├─,  ├─,  └─,  └─" && tools.every((r) => r.indent === 5));
check("reasoning-action", rows.some((r) => r.kind === "reasoning-header" && r.marker === "  ├─" && rowText(r) === "thought for 4s · Continued analysis"));
const aRows = t.rows(60, t._globalRow({ id: "a", row: 0, col: 0 }), t.rowCountOf("a"));
check("joined-messages", aRows.length > 0 && rowText(aRows[aRows.length - 1]) !== "");

// A streamed part joins the open group, and an output delta keeps the tree.
const liveParts = { first: [tool(10, "before")], next: [{ type: "reasoning", id: 11, text: "working" }] };
const live = new Transcript({ partsOf: (id) => liveParts[id] || [], partOf: (id, partId) => {
  const part = (liveParts[id] || []).find((p) => p.id === partId);
  return part ? { part } : null;
} });
live.setOutline([{ id: "first", type: "assistant" }], { id: "next", type: "assistant" });
check("reasoning-counts", live.rows(60, 0, live.rowCount(60)).some((r) => rowText(r) === "2 actions"));
// A thought that still streams stays folded to its header.
check("live-thought-folded", live.rows(60, 0, live.rowCount(60)).filter((r) => r.kind === "reasoning-header" || r.kind === "reasoning-body").map((r) => r.kind).join() === "reasoning-header");
liveParts.next.push(tool(12, "after"));
live.setActive("next");
let liveRows = live.rows(60, 0, live.rowCount(60));
check("stream-joins-tail", liveRows.some((r) => rowText(r) === "3 actions") && liveRows.filter((r) => r.kind === "tool-header").map((r) => r.marker).join(",") === "  ├─,  └─");
liveParts.next[1].state.output += " more";
live.setActive("next", 12);
liveRows = live.rows(60, 0, live.rowCount(60));
check("output-keeps-tree", liveRows.some((r) => rowText(r) === "3 actions") && liveRows.filter((r) => r.kind === "tool-header").map((r) => r.marker).join(",") === "  ├─,  └─");

// The group plan stays aligned after the outline gains, loses, and reorders messages.
const planParts = (id) => [{ type: "ignored", id: 0 }, { type: "text", id: 1, text: "" }, { type: "tool", id: 2, name: "tool" + id, arguments: "{}", state: { type: "completed", duration_ms: 1, output: "output" } }];
const outline = Array.from({ length: 40 }, (_, i) => ({ id: i + 1, type: "assistant" }));
const planned = new Transcript({ partsOf: planParts });
planned.setOutline(outline, null);
const render = (x) => JSON.stringify(x.rows(60, 0, x.rowCount(60)));
render(planned);
for (const next of [[{ id: 99, type: "assistant" }, ...outline], outline.slice(10), [outline[25], { id: 100, type: "user" }, ...outline.slice(0, 25)]]) {
  planned.setOutline(next, null);
  const fresh = new Transcript({ partsOf: planParts });
  fresh.setOutline(next, null);
  equal(render(planned), render(fresh));
}

// A detail row opens the whole fields, and a cut field reads its rest page by page.
const paged = [{ type: "tool", id: 7, name: "paged", arguments: '{"a":', state: { type: "error", error: "head", duration_ms: 1 }, cut: [{ field: "arguments", next: 5 }, { field: "error", next: 4 }] }];
const reads = [];
const detail = new Transcript({
  partsOf: () => paged,
  partTextPage: (_id, _part, field, offset) => { reads.push(field + ":" + offset); return field === "arguments" ? { text: '"b"}', next: null } : { text: " tail", next: null }; },
});
detail.setOutline([{ id: "p", type: "assistant" }], null);
const detailRows = detail.rows(60, 0, detail.rowCount(60));
const more = detailRows.findIndex((r) => rowText(r).indexOf("view all") >= 0);
check("details-open", more > 0 && detail.activate({ id: "p", row: more, col: 0 }) !== null && root.overlays.length === 1);
const sections = detailSections(root.overlays[0].content);
check("whole-fields", sections[0].text === '{"a":"b"}' && sections[1].text === "head tail");
check("paged-fields", reads.join(",") === "arguments:5,error:4");
root.popOverlay(root.overlays[0]);
