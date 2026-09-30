import { term } from "yuke:internal/native/term";
import { Composer } from "yuke:internal/ui";

/** @param {number} y @param {number} w @param {boolean} focused */
const draw = (y, w, focused) => {
  const c = new Composer({ placeholder: "ask" });
  c.rect = { x: 0, y, w, h: 1 };
  c.draw(focused);
};

term.beginFrame();
draw(0, 7, true);
draw(1, 7, false);
// The input lane keeps one cell at each narrow width, so the placeholder starts in the last cell.
draw(2, 1, false);
draw(3, 2, false);
draw(4, 3, false);
term.endFrame();
