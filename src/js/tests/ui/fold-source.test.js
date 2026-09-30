import { check } from "yuke:internal/test";
import { Transcript, registerRender, toggleExpandAll } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";

registerRender(defaultRender);
const lines = (tag, n) => Array.from({ length: n }, (_, i) => tag + "-" + i).join("\n");
// One message holds a shell tail, a folded read, a view preview, and text after them, so each later part depends on the bases before it.
const parts = {
  m: [
    { type: "tool", id: 1, name: "exec", arguments: '{"command":"seq"}', state: { type: "completed", output: lines("line", 12) } },
    { type: "tool", id: 2, name: "read", arguments: '{"path":"a.txt"}', state: { type: "completed", output: "alpha\nbravo" } },
    { type: "tool", id: 3, name: "grep", arguments: "{}", state: { type: "completed", output: "", view: [{ type: "text", text: lines("hit", 15) }] } },
    { type: "text", id: 4, text: "after the tools" },
  ],
};
const t = new Transcript({ partsOf: (id) => parts[id] || [] });
t.setOutline([{ id: "m", type: "assistant" }], null);
const W = 40;
/** @param {number} off */
const textAt = (off) => {
  const pos = t.posAtSource("m", off);
  return pos ? t.rowTextAt(pos.id, pos.row) : null;
};

t.rowCount(W);
const folded = t._sourceOf("m");
const tail = folded.indexOf("line-10");
const after = folded.indexOf("after the tools");
check("folded-tail", textAt(tail) === "line-10");

// A fold changes the rows alone, so a source offset names the same text folded and open.
toggleExpandAll();
t.rowCount(W);
check("same-source", t._sourceOf("m") === folded);
check("open-tail", textAt(tail) === "line-10");
check("open-after", textAt(after) === "after the tools");
