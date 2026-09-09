import { equal } from "yuke:test";
import { column, child, grow, solve } from "yuke:layout";
const tree = column([
  child("a", grow(Number.MAX_VALUE)),
  child("b", grow(Number.MAX_VALUE)),
], { padding: 20 });
const got = solve(tree, { x: 3, y: 4, w: 2, h: 1 });
equal(got.children.every((item) => item.rect.x >= 3 && item.rect.x <= 5 && item.rect.y >= 4 && item.rect.y <= 5 && item.rect.w >= 0 && item.rect.h >= 0 && Number.isFinite(item.rect.x + item.rect.y + item.rect.w + item.rect.h)) ? "ok" : JSON.stringify(got.children), "ok");
