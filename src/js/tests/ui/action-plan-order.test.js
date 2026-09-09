import { equal } from "yuke:test";
import { Transcript } from "yuke:transcript";
const parts = id => [{ type: "ignored", id: 0 }, { type: "text", id: 1, text: "" }, { type: "tool", id: 2, name: "tool" + id, arguments: "{}", state: { type: "completed", duration_ms: 1, output: "output" } }];
let outline = Array.from({ length: 40 }, (_, i) => ({ id: i + 1, type: "assistant" }));
const t = new Transcript({ partsOf: parts });
t.setOutline(outline, null);
const render = t => JSON.stringify(t.rows(60, 0, t.rowCount(60)));
render(t);
for (const next of [[{ id: 99, type: "assistant" }, ...outline], outline.slice(10), [outline[25], { id: 100, type: "user" }, ...outline.slice(0, 25)]]) {
  t.setOutline(next, null);
  const fresh = new Transcript({ partsOf: parts });
  fresh.setOutline(next, null);
  equal(render(t), render(fresh));
}
