import { check } from "yuke:test";
import { Composer } from "yuke:ui";
const key = (code, extra) => Object.assign({ type: "key", code, char: "", text: "", mods: 0 }, extra);
const paste = (t) => ({ type: "paste", text: t });

// The prompt takes two cells, so a width of 12 wraps the text at 10.
const c = new Composer({ onSubmit: () => true });
c.rect = { x: 0, y: 0, w: 12, h: 4 };
check("empty-one-row", c.height(12) === 1);

// One paste is one edit, and the text keeps its newline.
check("paste-taken", c.onKey(paste("hello world\nsecond")) === true);
check("paste-text", c.text === "hello world\nsecond");
check("paste-caret", c.input.caret === c.text.length);
check("grew", c.height(12) === 3);

// A newline key adds a line. Enter still submits.
c.onKey(key("enter", { mods: 2 }));
check("alt-enter", c.text === "hello world\nsecond\n");
check("grew-again", c.height(12) === 4);

// The composer never returns false for a vertical key, so the transcript never scrolls.
c.input.caret = c.text.length;
check("up-taken", c.onKey(key("up")) === true);
check("up-moved", c.input.caret < c.text.length);
const mid = c.input.caret;
check("down-taken", c.onKey(key("down")) === true);
check("down-moved", c.input.caret !== mid);
c.input.caret = 0;
c.onKey(key("up"));
check("up-at-top", c.input.caret === 0);

// The height stops at maxRows for text the user typed.
const big = new Composer();
big.rect = { x: 0, y: 0, w: 12, h: 4 };
big.text = "a\n".repeat(20);
check("capped", big.height(12) === big.maxRows);

// Submit clears the buffer, so the composer shrinks back to one row.
const sent = [];
const s = new Composer({ onSubmit: (t) => { sent.push(t); } });
s.rect = { x: 0, y: 0, w: 12, h: 4 };
s.onKey(paste("one\ntwo"));
s.onKey(key("enter"));
check("submitted", sent.length === 1 && sent[0] === "one\ntwo");
check("cleared", s.text === "" && s.height(12) === 1);

// setText fires onChange, so a programmatic set never leaves a stale wrap.
s.text = "a\nb\nc";
check("set-text-rewrapped", s.height(12) === 3);

// A vertical move holds the goal column across a short row.
const goal = new Composer();
goal.rect = { x: 0, y: 0, w: 12, h: 4 };
goal.text = "12345\nx\n12345";
goal.input.caret = 5;
goal.onKey(key("down"));
check("goal-short-row", goal.input.caret === 7);
goal.onKey(key("down"));
check("goal-restored", goal.input.caret === 13);
// A horizontal key drops the goal column.
goal.input.caret = 5;
goal.onKey(key("down"));
goal.onKey(key("left"));
goal.onKey(key("down"));
check("goal-dropped", goal.input.caret === 8);
