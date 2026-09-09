import { check } from "yuke:test";
import { root } from "yuke:core";
import { Transcript } from "yuke:transcript";
const rowText = (row) => row.text || (row.segments || []).map((segment) => segment.text).join("");
const sourceSpan = (source, rows, needle) => {
  const segment = rows.flatMap((row) => row.segments || []).find((entry) => entry.text.indexOf(needle) >= 0);
  return !!segment && segment.src >= 0 && segment.srcEnd > segment.src && source.slice(segment.src, segment.srcEnd) === segment.text;
};
const report = Array.from({ length: 256 }, (_, i) => "report-line-" + i + " with stable context").join("\n");
const reasoning = ["reason-first", ...Array.from({ length: 254 }, (_, i) => "reason-middle-" + i), "reason-last"].join("\n");
const plainOutput = Array.from({ length: 128 }, (_, i) => "plain-line-" + i).join("\n");
const plain = { type: "tool", id: 1, name: "plain", arguments: '{"path":"plain.txt"}', state: { type: "completed", output: plainOutput, duration_ms: 1 } };
const viewed = { type: "tool", id: 2, name: "view", arguments: '{"path":"view.md"}', state: { type: "completed", output: "", duration_ms: 2, view: [
  { type: "markdown", text: "view-first\n\nview-second" }, { type: "text", text: "view-tail" },
] } };
const tools = [plain, viewed];
for (let i = 2; i < 8; i++) tools.push({ ...plain, id: i + 1, name: "plain-" + i, arguments: '{"path":"plain-' + i + '.txt"}' });
const parts = tools.concat([{ type: "reasoning", id: 9, text: reasoning, signature: "" }]);
const t = new Transcript({
  textOf: (id) => id === "report" ? report : "",
  partsOf: (id) => id === "answer" ? parts : [],
});
t.setOutline([
  { id: "report", type: "user", source: { type: "child_report", session_id: "s", run_id: 1, name: "agent", outcome: { type: "turn", finish: "stop", rounds: 1 }, partial: false, truncated: false, usage: { rounds: 1, tool_calls: 0, tokens: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 } } } },
  { id: "answer", type: "assistant" },
], null);
const width = 100;
t.rowCount(width);
const publicRows = (id) => t.rows(width, 0, t.rowCount(width)).filter((row) => String(row.key) === String(id));
const reportRows = publicRows("report");
check("report-row-cap", reportRows.length === 11);
check("report-first-eight", reportRows.slice(1, 9).every((row, i) => rowText(row) === "report-line-" + i + " with stable context"));
check("report-footer", rowText(reportRows[9]).indexOf("click the header") >= 0);
check("report-source", sourceSpan(t._sourceOf("report"), reportRows, "report-line-0"));
for (const part of parts) t.togglePart("answer", part.id);
const rows = t.rows(width, 0, t.rowCount(width));
const toolRows = publicRows("answer");
check("eight-tools", toolRows.filter((row) => row.kind === "tool-header").length === 8);
for (const part of tools) {
  const bodyRows = toolRows.filter((row) => row.kind === "tool-body" && row.partId === part.id);
  check("tool-preview-cap-" + part.id, bodyRows.length === 3);
}
const plainRows = toolRows.filter((row) => row.kind === "tool-body" && row.partId === 1);
check("plain-first-three", plainRows.length === 3 && plainRows.every((row, i) => row.segments?.some((segment) => segment.text === "plain-line-" + i)));
const viewRows = toolRows.filter((row) => row.kind === "tool-body" && row.partId === 2);
check("view-first-three", viewRows.length === 3 && viewRows.some((row) => row.segments?.some((segment) => segment.text === "view-first")));
check("plain-source", sourceSpan(t._sourceOf("answer"), toolRows, "plain-line-0"));
const reasoningRows = toolRows.filter((row) => row.kind === "reasoning-body");
check("reasoning-first-ellipsis-last", reasoningRows.length === 3 && rowText(reasoningRows[0]).indexOf("reason-first") >= 0 && rowText(reasoningRows[1]) === "…" && rowText(reasoningRows[2]).indexOf("reason-last") >= 0);
check("reasoning-source", sourceSpan(t._sourceOf("answer"), reasoningRows, "reason-first") && sourceSpan(t._sourceOf("answer"), reasoningRows, "reason-last"));
check("rows-visible", rows.some((row) => rowText(row).indexOf("plain-line-0") >= 0));
check("plain-details", t.openTool("answer", 1) && root.overlays[0].content.sections[0].text === '{"path":"plain.txt"}' && root.overlays[0].content.sections[1].text === plainOutput);
root.popOverlay(root.overlays[0]);
check("view-details", t.openTool("answer", 2) && root.overlays[0].content.sections[2].text.indexOf("view-first") >= 0 && root.overlays[0].content.sections[2].text.indexOf("view-tail") >= 0);
root.popOverlay(root.overlays[0]);
check("reasoning-details", t.openReasoning("answer", 9) && root.overlays[0].content.sections[0].text === reasoning);
root.popOverlay(root.overlays[0]);
