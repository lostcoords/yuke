import { check } from "yuke:test";
import { term } from "yuke:term";
import { Transcript } from "yuke:transcript";
import { rowText } from "yuke:pager";
const at = (col, row, event) => ({ type: "mouse", col, row, button: "left", event, mods: 0 });

const body = { u1: "plain user text", a1: "hello **bold** and `code`", a2: "- alpha" };
const t = new Transcript({ textOf: (id) => body[id] || "" });
t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }, { id: "a2", type: "assistant" }], null);
term.beginFrame();
t.draw({ x: 0, y: 0, w: 40, h: 12 });
term.endFrame();

// Take the columns from the drawn rows, so the test does not depend on the layout.
const rows = t.rows(40, 0, 12);
const colOf = (row, s) => (rows[row].indent || 0) + rowText(rows[row]).indexOf(s);
const endOf = (row) => (rows[row].indent || 0) + rowText(rows[row]).length;

check("no-selection", t.selectedSource() === "");

// Row 2 is the assistant paragraph, past the user turn and its blank row.
t.onMouse(at(colOf(2, "bold"), 2, "press"));
t.onMouse(at(endOf(2), 2, "drag"));
check("rendered-text", t.selectedText() === "bold and code");
// The copy keeps the rendered text; the source keeps the markup between the two ends.
check("source-text", t.selectedSource() === "bold** and `code");

// One word inside a code span maps to that word, not to the backticks.
t.onMouse(at(colOf(2, "code"), 2, "press"));
t.onMouse(at(endOf(2), 2, "drag"));
check("inside-code", t.selectedText() === "code" && t.selectedSource() === "code");

// A bullet hides its markup, so one character of it still maps to the whole marker.
t.onMouse(at(colOf(4, "•"), 4, "press"));
t.onMouse(at(colOf(4, "•") + 1, 4, "drag"));
check("mark-whole", t.selectedText() === "•" && t.selectedSource() === "- ");

// A user turn is plain text, so its source is what it renders.
t.onMouse(at(colOf(0, "plain"), 0, "press"));
t.onMouse(at(colOf(0, "plain") + 5, 0, "drag"));
check("user-plain", t.selectedText() === "plain" && t.selectedSource() === "plain");
