import { style } from "yuke:internal/core";
import { term } from "yuke:internal/native/term";
import { Pager } from "yuke:internal/pager";

style.set({
  TestRowBg: { bg: "#203020" },
  TestRowText: { fg: "#ffffff", bg: "#ff0000", bold: true },
  TxSelect: { bg: "#445566", reverse: false },
  TestReverseRow: { reverse: true },
  TestMeta: { fg: "#aaaaaa", dim: true },
}, { default: true });

const pager = new Pager();
const list = [
  { bg: "TestRowBg", marker: ">", markerGroup: "TestRowText", indent: 1, text: "abc", group: "TestRowText" },
  { bg: "TestRowBg", text: "abcdef", group: "TestRowText" },
  { bg: "TestReverseRow", text: "meta", group: "TestMeta" },
];
// The first two rows carry a selection of their first three characters.
pager.setSource({
  rowCount: () => list.length,
  rows: (_w, top, height, out, sel) => {
    for (let i = top; i < Math.min(list.length, top + height); i++) {
      out.push(list[i]);
      if (i < 2) sel.push(out.length - 1, 0, 3);
    }
  },
});
pager.stuck = false;
term.beginFrame();
pager.draw({ x: 0, y: 0, w: 5, h: 3 });
term.endFrame();

// A redraw after a layer change must not reuse a composite with the old background.
style.set({ TestRowBg: { bg: "#304030" } });
term.beginFrame();
pager.draw({ x: 0, y: 0, w: 5, h: 3 });
term.endFrame();
