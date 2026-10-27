// The text functions of the terminal interface: cells, graphemes, fit, and wrap, in UTF-16 units. They need no display.

import { term } from "yuke:internal/term";
import { assert, equal, test, throws } from "yuke:test";
import { fit, graphemes, measure, parseKeys, wrap } from "yuke:tui";

test("text functions count utf16 units and cells", () => {
  const text = "a\u4e2de\u0301\ud834\udd1e";
  equal([term.measure(""), term.measure("a\tb"), term.measure("\u4e2d"), term.measure("\ud834")], [0, 2, 2, 1]);
  equal(term.graphemes(text), new Int32Array([0, 1, 1, 1, 1, 2, 2, 2, 1, 4, 2, 1]));
  equal(term.fit(text, 3), 2);
  equal(term.wrap("hello world", 5), new Int32Array([0, 6, 1, 6, 11, 0]));
  assert(throws(() => term.wrap(text, 2, -1)) instanceof TypeError);
  assert(throws(() => term.wrap(text, 2, 1.5)) instanceof TypeError);
});

test("the public module works without a display", () => {
  equal(measure("a\u4e2d"), 3);
  equal(fit("a\u4e2db", 3), 2);
  equal(wrap("ab cd", 3), new Int32Array([0, 3, 1, 3, 5, 0]));
  equal(graphemes("ab"), new Int32Array([0, 1, 1, 1, 1, 1]));
  equal(parseKeys("ctrl+x s"), ["ctrl+x", "s"]);
});
