import { equal, textParts } from "yuke:internal/test";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";

registerRender(defaultRender);
const line = (prefix, i) => prefix + "-" + i + " with enough context to wrap";
const large = Array.from({ length: 4096 }, (_, i) => line("preview-budget", i)).join("\\n");
const tools = [{ type: "tool", id: 1, name: "large", arguments: "{}", state: { type: "completed", output: large } }];
const t = new Transcript({
  partsOf: (id) => id === "answer" ? tools : textParts((key) => key === "report" ? large : "")(id),
});
t.setOutline([
  { id: "report", type: "user", source: { type: "child_report", session_id: "s", run_id: 1, name: "agent", outcome: { type: "turn", finish: "stop", rounds: 1 }, partial: false, truncated: false, usage: { rounds: 1, tool_calls: 0, tokens: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 }, duration_ms: 1500 } } },
  { id: "answer", type: "assistant" },
], null);
// A folded report and a folded tool each build ten rows of a huge text, not the whole text.
const rows = t.rows(100, 0, t.rowCount(100));
const body = (partId) => rows.filter((row) => row.partId === partId && !row.header && row.src != null);
equal(body(-1).length, 10);
equal(body(1).length, 10);
