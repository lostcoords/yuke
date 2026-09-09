import { check } from "yuke:test";
import { root } from "yuke:core";
import { Transcript } from "yuke:transcript";
const tool = (id, name) => ({ type: "tool", id, name, arguments: '{"value":"' + name + '"}', state: { type: "completed", output: name + " output", duration_ms: id } });
const parts = {
  a: [tool(1, "one"), tool(2, "two")],
  b: [{ type: "reasoning", id: 3, text: "continued analysis" }, tool(4, "three")],
  c: [{ type: "text", id: 5, text: "visible answer" }, tool(6, "four")],
};
const t = new Transcript({ partsOf: (id) => parts[id] || [] });
t.setOutline([{ id: "a", type: "assistant" }, { id: "b", type: "assistant" }, { id: "c", type: "assistant" }], null);
const rows = t.rows(60, 0, t.rowCount(60));
const rowText = (r) => r.text || (r.segments || []).map((s) => s.text).join("");
const tools = rows.filter((r) => r.kind === "tool-header");
const groupHeader = rows.find((r) => r.kind === "action-group-header");
check("one-group", rows.filter((r) => r.kind === "action-group-header" && rowText(r) === "4 actions").length === 1);
check("single-group", rows.filter((r) => r.kind === "action-group-header" && rowText(r) === "1 action").length === 1);
check("tree", tools.map((r) => r.marker).join(",") === "  ├─,  ├─,  └─,  └─");
check("tree-alignment", !!groupHeader && groupHeader.indent === 2 && tools.every((r) => r.marker.startsWith("  ") && r.indent === 5));
check("reasoning-action", rows.some((r) => r.kind === "reasoning-header" && r.marker === "  ├─" && rowText(r) === "thought"));
const aRows = t.rows(60, t._globalRow({ id: "a", row: 0, col: 0 }), t.rowCountOf("a"));
check("joined-messages", aRows.length > 0 && rowText(aRows[aRows.length - 1]) !== "");
check("text-breaks", tools.length === 4 && tools[3].marker === "  └─" && rows.some((r) => rowText(r).indexOf("visible answer") >= 0));

const liveParts = { first: [tool(10, "before")], next: [{ type: "reasoning", id: 11, text: "working" }] };
const live = new Transcript({ partsOf: (id) => liveParts[id] || [], partOf: (id, partId) => (liveParts[id] || []).find((part) => part.id === partId) || null });
live.setOutline([{ id: "first", type: "assistant" }], { id: "next", type: "assistant" });
check("reasoning-counts", live.rows(60, 0, live.rowCount(60)).some((r) => r.kind === "action-group-header" && rowText(r) === "2 actions"));
liveParts.next.push(tool(12, "after"));
live.setActive("next");
let liveRows = live.rows(60, 0, live.rowCount(60));
check("stream-joins-tail", liveRows.some((r) => r.kind === "action-group-header" && rowText(r) === "3 actions") && liveRows.filter((r) => r.kind === "tool-header").map((r) => r.marker).join(",") === "  ├─,  └─");
liveParts.next[1].state.output += " more";
live.setActive("next", 12);
liveRows = live.rows(60, 0, live.rowCount(60));
check("output-keeps-tree", liveRows.some((r) => r.kind === "action-group-header" && rowText(r) === "3 actions") && liveRows.filter((r) => r.kind === "tool-header").map((r) => r.marker).join(",") === "  ├─,  └─");

const paged = [{ type: "tool", id: 7, name: "paged", arguments: '{"a":', state: { type: "completed", output: "head", duration_ms: 1 }, cut: [{ field: "arguments", next: 5 }, { field: "output", next: 4 }] }];
const reads = [];
const detail = new Transcript({
  partsOf: () => paged,
  partTextPage: (_id, _part, field, offset) => { reads.push(field + ":" + offset); return field === "arguments" ? { text: '"b"}', next: null } : { text: " tail", next: null }; },
});
detail.setOutline([{ id: "p", type: "assistant" }], null);
check("details-open", detail.openTool("p", 7) && root.overlays.length === 1);
const content = root.overlays[0].content;
check("whole-input", content.sections[0].text === '{"a":"b"}');
check("whole-output", content.sections[1].text === "head tail");
check("paged-fields", reads.join(",") === "arguments:5,output:4");
root.popOverlay(root.overlays[0]);
const broken = new Transcript({ partsOf: () => paged, partTextPage: () => { throw new Error("read failed"); } });
broken.setOutline([{ id: "p", type: "assistant" }], null);
check("page-failure-safe", broken.openTool("p", 7) && root.overlays[0].content.sections.every((section) => section.text.indexOf("could not be read") >= 0));
root.popOverlay(root.overlays[0]);
const viewed = [{ type: "tool", id: 9, name: "viewed", arguments: "{}", state: { type: "completed", output: "", duration_ms: 1, view: [{ type: "markdown", text: "formatted view" }] } }];
const viewDetail = new Transcript({ partsOf: () => viewed });
viewDetail.setOutline([{ id: "view", type: "assistant" }], null);
check("view-details", viewDetail.openTool("view", 9) && root.overlays[0].content.sections[2].text === "formatted view");
root.popOverlay(root.overlays[0]);
parts.reason = [{ type: "reasoning", id: 8, text: "one two three four five six seven eight nine ten eleven twelve" }];
const reason = new Transcript({ partsOf: (id) => parts[id] || [] });
reason.setOutline([], { id: "reason", type: "assistant" });
const reasonRows = reason.rows(12, 0, reason.rowCount(12));
check("reasoning-preview-cap", reasonRows.filter((r) => r.kind === "reasoning-body").length === 3);
check("reasoning-label", reasonRows.some((r) => r.kind === "reasoning-header" && rowText(r) === "thinking") && !reasonRows.some((r) => rowText(r).indexOf("resumed") >= 0));
check("reasoning-details", reason.openReasoning("reason", 8) && root.overlays.length === 1 && root.overlays[0].content.sections[0].text === parts.reason[0].text);
root.popOverlay(root.overlays[0]);
