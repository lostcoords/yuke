import { Transcript } from "yuke:transcript";
import { rowText } from "yuke:pager";
for (const [reason, label] of [["setup_declined", "Setup declined"], ["setup_dismissed", "Setup incomplete"]]) {
  const t = new Transcript({ textOf: () => "", partsOf: () => [{ type: "tool", id: 0, name: "spawn_agent", arguments: "{}", state: { type: "canceled", reason, duration_ms: 2 } }] });
  t.setOutline([{ id: "one", type: "assistant" }], null);
  const rows = t.rows(100, 0, 10);
  if (!rows.map(rowText).join(" ").includes(label + " · No agent created")) throw new Error("missing outcome");
  if (rows.some(row => row.group === "TxToolError" || row.segments?.some(s => s.group === "TxToolError"))) throw new Error("red cancellation");
}
const t = new Transcript({ textOf: () => "", partsOf: () => [{ type: "tool", id: 0, name: "spawn_agent", arguments: "{}", state: { type: "error", error: "disk full" } }] });
t.setOutline([{ id: "one", type: "assistant" }], null);
if (!t.rows(100, 0, 10).map(rowText).join(" ").includes("disk full")) throw new Error("hidden error");
globalThis.result = "ok";
