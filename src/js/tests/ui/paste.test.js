import { check } from "yuke:test";
import { Composer } from "yuke:ui";
const key = (code, extra) => Object.assign({ type: "key", code, char: "", text: "", mods: 0 }, extra);
const paste = (t) => ({ type: "paste", text: t });
const big = "one\ntwo\nthree\nfour";

const sent = [];
const c = new Composer({ onSubmit: (t) => { sent.push(t); } });
c.rect = { x: 0, y: 0, w: 40, h: 6 };

// The text keeps the paste. Only the screen shows a label.
c.onKey(paste(big));
check("text-whole", c.text === big);
check("one-span", c.spans.length === 1);
check("label", c._projection().text === "[Pasted text #1 +4 lines]");
check("one-row", c.height(40) === 1);

// A short paste stays plain text.
c.onKey(paste("tail"));
check("short-plain", c.spans.length === 1 && c.text === big + "tail");

// The submit sends the paste and never the label.
c.onKey(key("enter"));
check("submitted-whole", sent.length === 1 && sent[0] === big + "tail");
check("spans-cleared", c.spans.length === 0 && c.text === "");

// A one-line paste over the character threshold counts characters.
const line = new Composer();
line.rect = { x: 0, y: 0, w: 40, h: 6 };
line.onKey(paste("z".repeat(200)));
check("chars-label", line._projection().text === "[Pasted text #1 +200 chars]");

// A newline at the end closes the last line, so a four-line paste is not five.
const nl = new Composer();
nl.rect = { x: 0, y: 0, w: 40, h: 6 };
nl.onKey(paste("one\ntwo\nthree\nfour\n"));
check("trailing-newline", nl._projection().text === "[Pasted text #1 +4 lines]");

// Backspace at the end drops the whole block, and the numbering keeps counting up.
const del = new Composer();
del.rect = { x: 0, y: 0, w: 40, h: 6 };
del.onKey(paste(big));
del.onKey(key("backspace"));
check("atomic-delete", del.text === "" && del.spans.length === 0);
del.onKey(paste(big));
check("id-not-reused", del._projection().text === "[Pasted text #2 +4 lines]");

// The caret steps over a span instead of into it.
const step = new Composer();
step.rect = { x: 0, y: 0, w: 40, h: 6 };
step.onKey(paste(big));
step.onKey(key("left"));
check("step-over", step.input.caret === 0);
step.onKey(key("right"));
check("step-back", step.input.caret === big.length);

// The same paste beside its label expands it. Elsewhere it makes a second block.
const again = new Composer();
again.rect = { x: 0, y: 0, w: 40, h: 6 };
again.onKey(paste(big));
again.onKey(paste(big));
check("expanded", again.spans.length === 0 && again.text === big);
const two = new Composer();
two.rect = { x: 0, y: 0, w: 40, h: 6 };
two.text = "hi";
two.onKey(paste(big));
two.input.caret = 0; // away from the span, which now starts at 2
two.onKey(paste(big));
check("second-block", two.spans.length === 2 && two.text === big + "hi" + big);

// ctrl+w at the end drops the whole block instead of a word inside the paste.
const word = new Composer();
word.rect = { x: 0, y: 0, w: 40, h: 6 };
word.onKey(paste("alpha beta\ngamma delta\nepsilon zeta"));
word.onKey(key("w", { char: "w", text: "w", mods: 4 }));
check("ctrl-w-atomic", word.text === "" && word.spans.length === 0);

// The content decides which side expands, so a different span on the left cannot block it.
const side = new Composer();
side.rect = { x: 0, y: 0, w: 40, h: 6 };
const other = "aaa\nbbb\nccc";
side.onKey(paste(other));
side.onKey(paste(big));
side.input.caret = other.length; // between the two labels
side.onKey(paste(big));
check("right-side-expands", side.spans.length === 1 && side.spans[0].end === other.length);

// An edit that reaches into a span drops the label and shows the paste.
const cut = new Composer();
cut.rect = { x: 0, y: 0, w: 40, h: 6 };
cut.onKey(paste(big));
cut.onKey(key("u", { char: "u", text: "u", mods: 4 }));
check("edit-detaches", cut.spans.length === 0 && cut.text === "");
