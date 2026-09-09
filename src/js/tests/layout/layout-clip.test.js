import { equal } from "yuke:test";
import { column, child, fixed, solve, clipRect } from "yuke:layout";
const tree = column([child("too-tall", fixed(5))], { padding: 2 });
const clipped = solve(tree, { x: 0, y: 0, w: 5, h: 3 }).children[0].rect;
equal(JSON.stringify([clipped, clipRect({ x: -2, y: 1, w: 8, h: 4 }, { x: 0, y: 0, w: 4, h: 3 })]), "[{\"x\":2,\"y\":2,\"w\":1,\"h\":0},{\"x\":0,\"y\":1,\"w\":4,\"h\":2}]");
