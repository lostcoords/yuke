import { style } from "yuke:internal/core";
import { term } from "yuke:internal/native/term";
import { Composer } from "yuke:internal/ui";

style.setPalette({ bg: "#112233" });

const c = new Composer();
c.rect = { x: 0, y: 0, w: 7, h: 2 };
c.text = "hello world";
const empty = new Composer({ placeholder: "ask" });
empty.rect = { x: 0, y: 2, w: 7, h: 1 };
const narrow = new Composer({ placeholder: "x" });
narrow.rect = { x: 0, y: 3, w: 1, h: 1 };

term.beginFrame();
c.draw(true);
const cur = c.cursor();
empty.draw(false);
narrow.draw(true);
term.endFrame();

globalThis.result = cur.x === 2 + 5 - 1 && cur.y === 1 && cur.visible ? "ok" : "x=" + cur.x + " y=" + cur.y;
