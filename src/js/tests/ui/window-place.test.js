import { check } from "yuke:internal/test";
import { Text, Window } from "yuke:internal/ui";

// A placed window stays inside its bounds, and a content height callback reads the content width.
let seen = -1;
const win = new Window({ border: "rounded", padding: { x: 1, y: 0 }, width: 20, contentHeight: (_max, width) => { seen = width; return 2; }, place: () => ({ x: 100, y: -5 }), content: new Text({ text: "x" }) });
win.layout({ x: 2, y: 3, w: 40, h: 10 });
check("width-passed", seen === 16);
check("placed-and-clamped", win.rect.x === 22 && win.rect.y === 3 && win.rect.w === 20 && win.rect.h === 4);
check("padding-inset", win.inner.x === 24 && win.inner.y === 4 && win.inner.w === 16 && win.inner.h === 2);

// A padding that would put the content outside the border is refused.
let refused = false;
try { new Window({ padding: { x: -1, y: 0 } }); } catch { refused = true; }
check("padding-validated", refused);
