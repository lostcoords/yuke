import { check } from "yuke:test";
import { term } from "yuke:term";
import { Transcript } from "yuke:transcript";
const at = (col, row, event) => ({ type: "mouse", col, row, button: "left", event, mods: 0 });

// Two user turns. A user row is plain text with a two-column gutter.
const body = { u1: "alpha", u2: "bravo" };
let copied = null;
const t = new Transcript({ textOf: (id) => body[id] || "", onSelect: (s) => (copied = s) });
t.setOutline([{ id: "u1", type: "user" }, { id: "u2", type: "user" }], null);
const paint = () => { term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: 12 }); term.endFrame(); };
paint();

// Drag inside one row: the gutter is two columns, so column 2 is the first character.
t.onMouse(at(3, 0, "press"));
t.onMouse(at(5, 0, "drag"));
check("within-row", t.selectedText() === "lp");

// Row 1 is the blank row after "alpha", so the drag crosses into the second message.
t.onMouse(at(4, 2, "drag"));
// The blank row between the turns stays in the copy as a blank line.
check("across-rows", t.selectedText() === "lpha\n\nbr");
t.onMouse(at(4, 2, "release"));
check("copy-on-release", copied === "lpha\n\nbr");

// A drag backwards selects the same text, because the ends are ordered.
t.onMouse(at(4, 2, "press"));
t.onMouse(at(3, 0, "drag"));
check("reverse-drag", t.selectedText() === "lpha\n\nbr");

// The selected part of a visible row carries a range, and the rest of the row does not.
const rows = t.rows(40, 0, 12);
check("row-sel", rows[0].sel && rows[0].sel.from === 1 && rows[0].sel.to === 5);
// The visible row is a copy, so a selection never sticks to the cached row.
t.clearSelection();
check("row-sel-copy", t.rows(40, 0, 12)[0].sel === undefined);

// A bare click drops the selection instead of copying an empty string.
copied = null;
t.onMouse(at(3, 0, "press"));
t.onMouse(at(3, 0, "release"));
check("click-clears", t.selection === null && copied === null);

// A cursor at column 0 of the end row adds no trailing blank line.
t.onMouse(at(3, 0, "press"));
t.onMouse(at(2, 2, "drag"));
check("no-trailing-newline", t.selectedText() === "lpha\n");

// A stray drag or release without a press changes nothing.
t.onMouse(at(3, 0, "press"));
t.onMouse(at(5, 0, "drag"));
t.onMouse(at(5, 0, "release"));
copied = null;
t.onMouse(at(9, 0, "drag"));
check("orphan-drag", t.selectedText() === "lp");
t.onMouse(at(9, 0, "release"));
check("orphan-release", copied === null);

// An append never moves the source before it, so a selection in the draft survives a delta.
body.a9 = "draft text";
t.setOutline([{ id: "u1", type: "user" }], { id: "a9", type: "assistant" });
paint();
// Rows 0 and 1 belong to "alpha", so row 2 is the first draft row.
t.onMouse(at(3, 2, "press"));
t.onMouse(at(5, 2, "drag"));
check("draft-sel", t.selection !== null && t.selection.anchor.id === "a9");
body.a9 = "draft text and more";
t.setActive("a9");
check("stream-keeps", t.selectedText() === "ra");
// A selection in another message survives a draft delta.
t.onMouse(at(3, 0, "press"));
t.onMouse(at(5, 0, "drag"));
t.setActive("a9");
check("other-msg-kept", t.selection !== null);

// An edit before the selection moves the text under it, so the selection drops.
body.a7 = "alpha bravo";
t.setOutline([], { id: "a7", type: "assistant" });
paint();
t.onMouse(at(8, 0, "press"));
t.onMouse(at(13, 0, "drag"));
check("edit-before-sel", t.selectedText() === "bravo");
body.a7 = "xxx alpha bravo";
t.setActive("a7");
check("edit-clears", t.selection === null);
// An append after it keeps the same words.
body.a8 = "alpha bravo";
t.setOutline([], { id: "a8", type: "assistant" });
paint();
t.onMouse(at(8, 0, "press"));
t.onMouse(at(13, 0, "drag"));
body.a8 = "alpha bravo charlie";
t.setActive("a8");
check("append-keeps", t.selectedText() === "bravo");

// A user turn maps each row back to its source, so a rewrap keeps the same words.
t.setOutline([{ id: "u1", type: "user" }, { id: "u2", type: "user" }], null);
paint();
t.onMouse(at(3, 0, "press"));
t.onMouse(at(5, 0, "drag"));
check("before-resize", t.selectedText() === "lp");
t.rows(20, 0, 12);
check("keep-user-resize", t.selectedText() === "lp");

// A markdown turn re-anchors on its source, so the same words stay selected.
body.a2 = "alpha bravo charlie delta echo";
t.setOutline([{ id: "a2", type: "assistant" }], null);
t.rows(40, 0, 12);
paint();
t.onMouse(at(8, 0, "press"));
t.onMouse(at(13, 0, "drag"));
check("wide-sel", t.selectedText() === "bravo");
t.rows(14, 0, 12);
check("keep-on-resize", t.selectedText() === "bravo");
