import { equal } from "yuke:test";
import { row, child, grow, solve } from "yuke:layout";
const tree = row([child("a", grow()), child("b", grow()), child("c", grow())], { gap: 1 });
equal(JSON.stringify(solve(tree, { x: 0, y: 0, w: 10, h: 4 }).children.map((x) => [x.value, x.rect])), "[[\"a\",{\"x\":0,\"y\":0,\"w\":3,\"h\":4}],[\"b\",{\"x\":4,\"y\":0,\"w\":3,\"h\":4}],[\"c\",{\"x\":8,\"y\":0,\"w\":2,\"h\":4}]]");
