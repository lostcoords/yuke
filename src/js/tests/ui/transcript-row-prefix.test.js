import { check } from "yuke:test";
import { Transcript } from "yuke:transcript";
let source = "# Prefix\n\nstable 世界 é 👩‍💻\n\n```txt\nbody\n```\n\nTail";
const part = () => ({ type: "text", id: 0, text: source });
const make = () => {
  const t = new Transcript({ partsOf: () => [part()], partOf: part });
  t.setOutline([], { id: 1, type: "assistant" });
  return t;
};
const t = make();
const rows = (view, width) => view.rows(width, 0, view.rowCount(width));
rows(t, 24);
const prefix = t.partStates.get("1").rows.get("0").rows[0];
for (const delta of [" extended", "\r", "\n\r\nNext", "\n===", "\n\n| a | b |\n|---|---|\n| 1 | 2 |", "\n\nEnd"]) {
  source += delta;
  t.setActive(1, 0);
  check("append-output", JSON.stringify(rows(t, 24)) === JSON.stringify(rows(make(), 24)));
  check("prefix-identity", t.partStates.get("1").rows.get("0").rows[0] === prefix);
}
for (const width of [9, 32, 24]) check("resize-output", JSON.stringify(rows(t, width)) === JSON.stringify(rows(make(), width)));
for (source of ["replacement\n\ntext", "", "new text"]) {
  t.setActive(1, 0);
  check("replacement-output", JSON.stringify(rows(t, 24)) === JSON.stringify(rows(make(), 24)));
}
