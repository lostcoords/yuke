// The text functions of the terminal interface: cells, graphemes, fit, and wrap, in UTF-16 units. They need no display.

import { equal, test } from "yuke:test";
import { fit, graphemes, measure, wrap } from "yuke:tui";

test("text functions count utf16 units and cells", () => {
  const text = "a\u4e2de\u0301\ud834\udd1e";
  equal([measure(""), measure("a\tb"), measure("\u4e2d"), measure("\ud834")], [0, 2, 2, 1]);
  equal(graphemes(text), new Int32Array([0, 1, 1, 1, 1, 2, 2, 2, 1, 4, 2, 1]));
  equal(fit(text, 3), 2);
  equal(wrap("hello world", 5), new Int32Array([0, 6, 1, 6, 11, 0]));
});
