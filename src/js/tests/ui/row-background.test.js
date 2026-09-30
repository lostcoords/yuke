import { style } from "yuke:internal/core";
import { term } from "yuke:internal/native/term";
import { Pager } from "yuke:internal/pager";

style.set({
  TestRowBg: { bg: "#203020" },
  TestRowText: { fg: "#ffffff", bg: "#ff0000", bold: true },
}, { default: true });

const pager = new Pager();
pager.setRows([
  { bg: "TestRowBg", marker: ">", markerGroup: "TestRowText", indent: 1, text: "abc", group: "TestRowText" },
  { bg: "TestRowBg", text: "abcdef", group: "TestRowText" },
]);
pager.stuck = false;
term.beginFrame();
pager.draw({ x: 0, y: 0, w: 5, h: 2 });
term.endFrame();

// A redraw after a layer change must not reuse a composite with the old background.
style.set({ TestRowBg: { bg: "#304030" } });
term.beginFrame();
pager.draw({ x: 0, y: 0, w: 5, h: 2 });
term.endFrame();
