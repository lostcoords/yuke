import { equal } from "yuke:test";
import { column, child, fixed, fit, grow, solve } from "yuke:layout";
const tree = column([
  child("fixed", fixed(2)),
  child("fit", fit(), { intrinsic: { w: 20, h: 3 } }),
  child("grow", grow()),
], { gap: 1, padding: 1 });
const got = solve(tree, { x: 0, y: 0, w: 20, h: 12 });
equal(JSON.stringify(got.children.map((x) => [x.value, x.rect])), "[[\"fixed\",{\"x\":1,\"y\":1,\"w\":18,\"h\":2}],[\"fit\",{\"x\":1,\"y\":4,\"w\":18,\"h\":3}],[\"grow\",{\"x\":1,\"y\":8,\"w\":18,\"h\":3}]]");
