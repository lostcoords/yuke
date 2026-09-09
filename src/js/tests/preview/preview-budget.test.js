import { equal } from "yuke:test";
import { Transcript } from "yuke:transcript";
const line = (prefix, i) => prefix + "-" + i + " with enough context to wrap";
const large = Array.from({ length: 4096 }, (_, i) => line("preview-budget", i)).join("\\n");
const tools = [
  { type: "tool", id: 1, name: "large", arguments: "{}", state: { type: "completed", output: large } },
  { type: "reasoning", id: 2, text: large, signature: "" },
];
const t = new Transcript({
  textOf: (id) => id === "report" ? large : "",
  partsOf: (id) => id === "answer" ? tools : [],
});
t.setOutline([
  { id: "report", type: "user", source: { type: "child_report", session_id: "s", run_id: 1, name: "agent", outcome: { type: "turn", finish: "stop", rounds: 1 }, partial: false, truncated: false } },
  { id: "answer", type: "assistant" },
], null);
for (const part of tools) t.togglePart("answer", part.id);
const rows = t.rows(100, 0, t.rowCount(100));
const body = (kind, partId) => rows.filter((row) => row.kind === kind && row.partId === partId);
equal(body("report-body", -1).length, 8);
equal(body("tool-body", 1).length, 3);
equal(body("reasoning-body", 2).length, 3);
