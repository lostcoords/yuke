import { check } from "yuke:test";
import { term } from "yuke:term";
import { Transcript } from "yuke:transcript";
import { Document } from "yuke:md";
import { prevGrapheme, nextGrapheme } from "yuke:text-input";

const body = { a1: "alpha bravo charlie delta echo foxtrot golf hotel india" };
const t = new Transcript({ textOf: (id) => body[id] || "" });
t.setOutline([{ id: "a1", type: "assistant" }], null);
const rect = { x: 0, y: 0, w: 20, h: 2 };
const paint = () => { term.beginFrame(); t.draw(rect); term.endFrame(); };
paint();
const count = t.rowCountOf("a1");
check("wrapped", count > rect.h);

// Every column that carries source maps to an offset that maps back to the same offset.
let bad = 0;
for (let r = 0; r < count; r++) {
  const n = t.rowTextAt("a1", r).length;
  for (let c = 0; c <= n; c++) {
    const off = t.sourceAt({ id: "a1", row: r, col: c });
    if (off < 0) continue;
    const back = t.posAtSource("a1", off);
    if (!back || t.sourceAt(back) !== off) bad++;
  }
}
check("roundtrip", bad === 0);

// An offset past the end takes the last position, so a selection to the end survives.
check("tail", t.posAtSource("a1", body.a1.length + 99) !== null);
check("no-source", t.sourceAt({ id: "a1", row: count + 5, col: 0 }) === -1);

// The screen cell counts the gutter, and a row off the viewport has none.
t.pager.toTop();
paint();
const head = t.screenAt({ id: "a1", row: 0, col: 3 });
// The assistant gutter is two columns wide.
check("screen-at", head && head.y === 0 && head.x === 2 + 3);
const last = { id: "a1", row: count - 1, col: 0 };
check("hidden-before", t.screenAt(last) === null);
t.ensureVisible(last);
check("visible-after", t.screenAt(last) !== null);

// A source offset inside a grapheme snaps to its edge.
{
  const em = new Transcript({ textOf: () => "a😀b" });
  em.setOutline([{ id: "e1", type: "assistant" }], null);
  em.rows(20, 0, 4);
  const p1 = em.posAtSource("e1", 2);
  const line = em.rowTextAt("e1", 0);
  check("grapheme-snap", p1 && (p1.col === line.indexOf("😀") || p1.col === line.indexOf("😀") + 2));
}

// The blocks carry their source span, so a caller can move by markdown structure.
const doc = new Document();
doc.setText("# H\n\npara\n\n```\nx\n```");
const bs = doc.blocks();
check("blocks", bs.length === 3 && bs[0].kind === "heading" && bs[0].at === 0 && bs[2].kind === "code");

// A grapheme step crosses an astral pair whole.
check("grapheme-step", nextGrapheme("a𝄞b", 1) === 3 && prevGrapheme("a𝄞b", 3) === 1);
