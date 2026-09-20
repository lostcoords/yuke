import { equal } from "yuke:test";
import { column, row, child, fixed, fit, grow, solve, clipRect } from "yuke:layout";

// A column fits fixed content and gives the remainder to grow.
const col = column([
  child("fixed", fixed(2)),
  child("fit", fit(), { intrinsic: { w: 20, h: 3 } }),
  child("grow", grow()),
], { gap: 1, padding: 1 });
equal(JSON.stringify(solve(col, { x: 0, y: 0, w: 20, h: 12 }).children.map((x) => [x.value, x.rect])), "[[\"fixed\",{\"x\":1,\"y\":1,\"w\":18,\"h\":2}],[\"fit\",{\"x\":1,\"y\":4,\"w\":18,\"h\":3}],[\"grow\",{\"x\":1,\"y\":8,\"w\":18,\"h\":3}]]");

// A row splits an odd remainder in source order.
const three = row([child("a", grow()), child("b", grow()), child("c", grow())], { gap: 1 });
equal(JSON.stringify(solve(three, { x: 0, y: 0, w: 10, h: 4 }).children.map((x) => [x.value, x.rect])), "[[\"a\",{\"x\":0,\"y\":0,\"w\":3,\"h\":4}],[\"b\",{\"x\":4,\"y\":0,\"w\":3,\"h\":4}],[\"c\",{\"x\":8,\"y\":0,\"w\":2,\"h\":4}]]");

// The solver honors min and max and centers a non-stretch child.
const limits = row([
  child("fixed", fixed(3), { align: "center", intrinsic: { w: 3, h: 2 } }),
  child("grow", grow(1, { min: 2, max: 4 })),
], { gap: 1 });
equal(JSON.stringify(solve(limits, { x: 0, y: 0, w: 12, h: 6 }).children.map((x) => [x.value, x.rect])),
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

// An over-constrained child clips to the available bounds.
const tall = column([child("too-tall", fixed(5))], { padding: 2 });
const clipped = solve(tall, { x: 0, y: 0, w: 5, h: 3 }).children[0].rect;
equal(JSON.stringify([clipped, clipRect({ x: -2, y: 1, w: 8, h: 4 }, { x: 0, y: 0, w: 4, h: 3 })]), "[{\"x\":2,\"y\":2,\"w\":1,\"h\":0},{\"x\":0,\"y\":1,\"w\":4,\"h\":2}]");

// Empty padding and huge grow weights stay inside the parent rect.
const bounded = column([
  child("a", grow(Number.MAX_VALUE)),
  child("b", grow(Number.MAX_VALUE)),
], { padding: 20 });
const got = solve(bounded, { x: 3, y: 4, w: 2, h: 1 });
equal(got.children.every((item) => item.rect.x >= 3 && item.rect.x <= 5 && item.rect.y >= 4 && item.rect.y <= 5 && item.rect.w >= 0 && item.rect.h >= 0 && Number.isFinite(item.rect.x + item.rect.y + item.rect.w + item.rect.h)) ? "ok" : JSON.stringify(got.children), "ok");
