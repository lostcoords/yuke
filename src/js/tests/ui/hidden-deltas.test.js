import { check } from "yuke:internal/test";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";

registerRender(defaultRender);
// A folded read shows only its header, so an output delta keeps the rows and the selection, and the field still reads fresh.
let part = { type: "tool", id: 7, name: "read", arguments: '{"path":"a.txt"}', state: { type: "completed", duration_ms: 1, output: "old" } };
const copy = (p) => JSON.parse(JSON.stringify(p));
const t = new Transcript({ partsOf: () => [copy(part)], partOf: () => ({ part: copy(part) }) });
t.setOutline([], { id: 1, type: "assistant" });
const rows = () => t.rows(80, 0, t.rowCount(80));
const text = () => rows().map((r) => r.text || (r.segments || []).map((s) => s.text).join("")).join("\n");
rows();
const source = t._sourceOf(1);
t.select(t.posAtSource(1, 0), t.posAtSource(1, source.length));
const initial = JSON.stringify(rows());
part.state.output = "fresh hidden output";
t.setActive(1, 7);
check("hidden-rows", JSON.stringify(rows()) === initial);
check("hidden-selection", t.selectedText(true) === source);
check("hidden-field", t.readField(1, 7, "output") === "fresh hidden output");
t.togglePart(1, 7);
check("expand-fresh", text().includes("fresh hidden output"));
part.state.output = "visible delta";
t.setActive(1, 7);
check("visible-rows", text().includes("visible delta") && !text().includes("fresh hidden output"));

// A header change, an error, and a new part kind each rebuild the rows.
part.name = "exec";
part.arguments = '{"command":"ls -la"}';
t.setActive(1, 7);
check("header-fields", text().includes("$ ls -la"));
part.state = { type: "error", duration_ms: 2400, error: "failed" };
t.setActive(1, 7);
check("error-block", text().includes("failed") && rows().some((r) => r.bg === "TxToolErrorBg"));
part = { type: "reasoning", id: 7, text: "new thought" };
t.setActive(1, 7);
check("new-kind", text().includes("new thought") && !text().includes("ls -la"));
