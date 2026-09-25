import { check } from "yuke:internal/test";
import { term } from "yuke:internal/native/term";
import { plugins } from "yuke:internal/ext";
import { Transcript } from "yuke:internal/transcript";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);
const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0) || (r.text || "").indexOf(want) >= 0);
const png = { hash: "a".repeat(64), mime: "image/png", bytes: 2048 };
const jpg = { hash: "b".repeat(64), mime: "image/jpeg", bytes: 3 * 1024 * 1024 };

// A tool image shows as a label after the output, and a result of images alone still shows its labels.
const parts = {
  shot: [{ type: "tool", id: 0, name: "read", arguments: '{"path":"shot.png"}', state: { type: "completed", output: "PNG image, 2 KiB", media: [png, jpg], duration_ms: 1 } }],
  bare: [{ type: "tool", id: 0, name: "read", arguments: '{"path":"x.png"}', state: { type: "completed", output: "", media: [png], duration_ms: 1 } }],
};
const t = new Transcript({ partsOf: (id) => parts[id] || [] });
t.setOutline([{ id: "shot", type: "assistant" }, { id: "bare", type: "assistant" }], null);
term.beginFrame(); t.draw({ x: 0, y: 0, w: 60, h: 12 }); term.endFrame();
t.pager.toTop();
for (const id of ["shot", "bare"]) t.togglePart(id, 0);
term.beginFrame(); t.draw({ x: 0, y: 0, w: 60, h: 12 }); term.endFrame();
const rows = t.rows(60, 0, 12);
check("output", rowsHave(rows, "PNG image, 2 KiB"));
check("png-label", rowsHave(rows, "[PNG #1 · 2 KiB]"));
check("jpeg-label", rowsHave(rows, "[JPEG #2 · 3.0 MiB]"));
check("bare-label", rows.filter((r) => (r.segments || []).some((sg) => sg.text === "[PNG #1 · 2 KiB]")).length === 2);
