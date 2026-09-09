import { check } from "yuke:test";
import { root, Node, slot } from "yuke:core";
import { term } from "yuke:term";
import { ChatView } from "yuke:chat-view";
const body = { a1: "alpha bravo charlie\nsecond line here\nthird line xx" };
const v = new ChatView({ textOf: (id) => body[id] || "" });
v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
root.setRoot(Node.leaf(v));
v.rect = { x: 0, y: 0, w: 40, h: 18 }; v.layout(v.rect);
term.beginFrame(); v.draw(true); term.endFrame();
const r = v.transcript.pager.rect();
const mouse = (row, event, button) => v.onMouse({ type: "mouse", col: r.x + 2, row, button: button || "left", event, mods: 0 });

mouse(r.y, "press");
check("press-starts-drag", v.transcript._dragging === true);
mouse(v.composer.rect.y, "drag");
check("drag-outside-still-drags", v.transcript._dragging === true);
mouse(v.composer.rect.y, "release");
check("release-outside-ends-drag", v.transcript._dragging === false);

// A non-left button never reaches the press slot.
let calls = 0;
const off = slot.add(ChatView, "press", () => { calls++; return true; });
mouse(r.y, "press", "right");
check("right-button-skips-slot", calls === 0);
mouse(r.y, "drag");
check("drag-skips-slot", calls === 0);
mouse(r.y, "press");
check("left-press-reaches-slot", calls === 1);
off();

// The pane claims the press only for a literal true, so a truthy value does not.
const offTruthy = slot.add(ChatView, "press", () => "yes");
check("truthy-does-not-claim", v.onMouse({ type: "mouse", col: r.x + 2, row: v.composer.rect.y, button: "left", event: "press", mods: 0 }) === false);
offTruthy();
