import { check, textParts } from "yuke:internal/test";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";

registerRender(defaultRender);
const rowText = (row) => row.text || (row.segments || []).map((segment) => segment.text).join("");
// A wrapped row carries its source offset, and its text is the source text.
const sourceSpan = (source, rows, needle) => {
  const row = rows.find((entry) => entry.src != null && entry.text.indexOf(needle) >= 0);
  return !!row && source.slice(row.src, row.src + row.text.length) === row.text;
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
  partsOf: (id) => id === "answer" ? parts : textParts((key) => key === "report" ? report : "")(id),
});
t.setOutline([
  { id: "report", type: "user", source: { type: "child_report", session_id: "s", run_id: 1, name: "agent", outcome: { type: "turn", finish: "stop", rounds: 1 }, partial: false, truncated: false, usage: { rounds: 1, tool_calls: 0, tokens: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 }, duration_ms: 1500 } } },
  { id: "answer", type: "assistant" },
], null);
const width = 100;
t.rowCount(width);
const publicRows = (id) => t.rows(width, 0, t.rowCount(width)).filter((row) => String(row.key) === String(id));
const reportRows = publicRows("report");
// A folded report shows its label, ten lines, and a hint; the separator row closes the message.
check("report-row-cap", reportRows.length === 13 && reportRows[0].header === true);
check("report-first-ten", reportRows.slice(1, 11).every((row, i) => rowText(row) === "report-line-" + i + " with stable context"));
check("report-hint", rowText(reportRows[11]).indexOf("expands") >= 0);
check("report-source", sourceSpan(t._sourceOf("report"), reportRows, "report-line-0"));
// A folded tool shows its first ten output rows and a count of the rest; a thought shows in full.
const folded = publicRows("answer");
check("eight-tools", folded.filter((row) => row.header).length === 8);
const bodyOf = (rows, id) => rows.filter((row) => row.partId === id && !row.header && row.src != null);
check("plain-first-ten", bodyOf(folded, 1).length === 10 && bodyOf(folded, 1).every((row, i) => rowText(row) === "plain-line-" + i));
check("plain-hint", folded.some((row) => row.partId === 1 && rowText(row) === "… (more lines, ctrl+o to expand)"));
check("view-cap", bodyOf(folded, 2).length <= 10 && folded.some((row) => row.partId === 2 && rowText(row) === "view-first"));
check("plain-source", sourceSpan(t._sourceOf("answer"), folded, "plain-line-0"));
check("reasoning-whole", folded.some((row) => rowText(row) === "reason-first") && folded.some((row) => rowText(row) === "reason-last"));
check("reasoning-source", sourceSpan(t._sourceOf("answer"), folded, "reason-first") && sourceSpan(t._sourceOf("answer"), folded, "reason-last"));
// An open tool shows its whole output.
for (const part of tools) t.togglePart("answer", part.id);
const open = publicRows("answer");
check("plain-open", bodyOf(open, 1).length === 128 && rowText(bodyOf(open, 1)[127]) === "plain-line-127");
check("view-open", open.some((row) => rowText(row) === "view-tail"));

{
  const rowsOf = (error) => { const e = new Transcript({}); e.setOutline([{ id: 1, type: "assistant", error }], null); return e.rows(160, 0, e.rowCount(160)).map(rowText).join("\n"); };
  check("error-row-every-part", rowsOf({ type: "provider", message: "the provider returned an unexpected status", status: 400, request_id: "req_1", detail: "invalid_request_error: too long" }).includes("⚠ the provider returned an unexpected status · HTTP 400 · invalid_request_error: too long · request req_1"));
  check("error-row-sentence-only", rowsOf({ type: "provider", message: "the provider stream timed out" }).includes("⚠ the provider stream timed out") && !rowsOf({ type: "provider", message: "x" }).includes("HTTP"));
}
