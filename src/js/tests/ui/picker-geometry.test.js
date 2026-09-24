import { Picker, Prompt, Window } from "yuke:ui";
import { term } from "yuke:term";
const check = (ok, message) => { if (!ok) throw new Error(message); };
const p = new Picker({ body: "one two three four five six seven eight nine ten eleven twelve", filter: false, items: ["Yes", "No"] });
const w = new Window({ border: "rounded", width: 16, height: 6, content: p });
p.win = w;
const draw = () => { w.layout({ x: 0, y: 0, w: term.width, h: term.height }); term.beginFrame(); w.draw(); term.endFrame(); };
draw();
let r = p.list._rect;
check(r.x === w.rect.x + 3 && r.w === 10 && r.h === 2 && p.cursor() === null, "small padding/actions");
check(!p.onMouse({ event: "press", button: "left", col: r.x - 1, row: r.y }), "padding accepted click");
check(p.onMouse({ event: "press", button: "left", col: r.x, row: r.y + 1 }) && p.list.selected() === "No", "action mouse target");
w.opts.height = 10;
draw();
r = p.list._rect;
const body = p._bodyRows;
draw();
check(p._bodyRows === body, "wrap cache");
check(p.onMouse({ event: "press", button: "wheel_down", col: r.x, row: w.rect.y + 2, count: 1 }) && p._bodyScroll > 1, "body scroll steps scrollLines");
check(p.list.selected() === "No", "body wheel moved action");
p.onKey({ type: "key", code: "page_down", mods: 0 });
check(p._bodyScroll > 1 && p.list.selected() === "No", "body keyboard scroll");
w.opts.width = 60; w.opts.height = p.preferredHeight(60);
draw();
check(p._bodyRows !== body && p._bodyScroll === 0, "resize wrap/scroll");
check(p._bodyLayout(w.inner).height === p._bodyRows.length, "body clipped at normal size");
check(p.list._rect.h === 2, "preferred height action rows");
w.border = "none"; w.opts.height = p.preferredHeight(60);
draw();
check(p.list._rect.x === w.rect.x && p.list._rect.w === w.rect.w && p.list._rect.h === 2, "borderless preferred height");
const finder = new Picker({ body: "help text", items: ["one"] });
const fw = new Window({ border: "rounded", width: 16, height: 6, content: finder });
finder.win = fw; fw.layout({ x: 0, y: 0, w: term.width, h: term.height });
const cursor = finder.cursor(), inner = fw.inner;
check(cursor.x >= inner.x && cursor.x < inner.x + inner.w && cursor.y >= inner.y && cursor.y < inner.y + inner.h, "cursor outside content");

// The footer owns a row outside the content and leaves the bottom border intact.
const prompt = new Prompt({ settle() {} });
const dialog = new Window({ border: "rounded", width: 30, contentHeight: 1, footer: "esc close", content: prompt });
const painted = [];
const originalText = term.text;
term.text = (x, y, s, group) => { painted.push({ x, y, s }); originalText(x, y, s, group); };
try {
  dialog.layout({ x: 0, y: 0, w: 40, h: 12 });
  term.beginFrame(); dialog.draw(); term.endFrame();
  const footer = painted.find(row => row.s === "esc close");
  check(prompt.rect.h === 1 && prompt.rect.x === dialog.rect.x + 3, "shared prompt padding");
  check(footer && footer.x === prompt.rect.x && footer.y > prompt.rect.y && footer.y === dialog.rect.y + dialog.rect.h - 2, "footer content row");
  check(painted.some(row => row.y === footer.y + 1 && row.s.startsWith("╰─") && row.s.endsWith("─╯")), "continuous bottom border");
  prompt.onMouse = () => { throw new Error("footer reached content"); };
  check(!dialog.onMouse({ event: "press", button: "wheel_down", col: footer.x, row: footer.y }), "footer mouse boundary");
  dialog.border = "none";
  dialog.opts.anchor = () => ({ x: 3, y: 8, w: 30, h: 1 });
  dialog.layout({ x: 0, y: 0, w: 40, h: 12 });
  check(dialog.rect.y + dialog.rect.h === 8 && prompt.rect.h === 1 && dialog.rect.h === 2, "compact footer size");
  painted.length = 0;
  term.beginFrame(); dialog.draw(); term.endFrame();
  check(painted.some(row => row.s === "esc close" && row.y === 7), "borderless footer");
  for (let height = 0; height < 6; height++) {
    dialog.border = "rounded"; dialog.opts.anchor = null;
    dialog.layout({ x: 0, y: 0, w: 4, h: height });
    check(prompt.rect.w === 0 && prompt.rect.h === 0 && !prompt.cursor().visible, "tiny dialog cursor");
  }
} finally { term.text = originalText; }
