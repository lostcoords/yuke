import { equal } from "yuke:test";
import { row, child, fixed, grow, solve } from "yuke:layout";
const tree = row([
  child("fixed", fixed(3), { align: "center", intrinsic: { w: 3, h: 2 } }),
  child("grow", grow(1, { min: 2, max: 4 })),
], { gap: 1 });
equal(JSON.stringify(solve(tree, { x: 0, y: 0, w: 12, h: 6 }).children.map((x) => [x.value, x.rect])),
  JSON.stringify([["fixed", { x: 0, y: 2, w: 3, h: 2 }], ["grow", { x: 4, y: 0, w: 4, h: 6 }]]));
const cases = [
  [[[1, 0, 2], [1, 0, 100]], [2, 9]],
  [[[1, 2, 4], [2, 0, 100]], [4, 7]],
  [[[2, 0, 3], [1, 0, 100], [1, 0, 100]], [3, 4, 4]],
  [[[Number.MIN_VALUE, 0, 100], [Number.MAX_VALUE, 0, 100]], [0, 11]],
];
for (const [specs, expected] of cases) {
  const items = specs.map(([weight, min, max], i) => child(i, grow(weight, { min, max })));
  const widths = solve(row(items), { x: 0, y: 0, w: 11, h: 1 }).children.map(item => item.rect.w);
  equal(JSON.stringify(widths), JSON.stringify(expected));
}
