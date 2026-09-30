import { style } from "yuke:internal/core";
import { term } from "yuke:internal/native/term";
import { Pager } from "yuke:internal/pager";

style.set({
  TestRowBg: { bg: "#203020" },
  TestRowText: { fg: "#ffffff", bg: "#ff0000", bold: true },
  TestSelect: { bg: "#445566", reverse: false },
  TestSelectPlain: { reverse: true },
  TestReverseRow: { reverse: true },
  TestMeta: { fg: "#aaaaaa", dim: true },
}, { default: true });

const pager = new Pager();
pager.setRows([
  { bg: "TestRowBg", marker: ">", markerGroup: "TestRowText", indent: 1, text: "abc", group: "TestRowText", sel: { from: 0, to: 3 }, selGroup: "TestSelect" },
  { bg: "TestRowBg", text: "abcdef", group: "TestRowText", sel: { from: 0, to: 3 }, selGroup: "TestSelectPlain" },
  { bg: "TestReverseRow", text: "meta", group: "TestMeta" },
]);
pager.stuck = false;
term.beginFrame();
pager.draw({ x: 0, y: 0, w: 5, h: 3 });
term.endFrame();

// A redraw after a layer change must not reuse a composite with the old background.
style.set({ TestRowBg: { bg: "#304030" } });
term.beginFrame();
pager.draw({ x: 0, y: 0, w: 5, h: 3 });
term.endFrame();
