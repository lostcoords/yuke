import { check } from "yuke:internal/test";
import { Composer } from "yuke:internal/ui";
const key = (code, extra) => Object.assign({ type: "key", code, char: "", text: "", mods: 0 }, extra);
const png = { hash: "a".repeat(64), mime: "image/png", bytes: 12288 };
const jpg = { hash: "b".repeat(64), mime: "image/jpeg", bytes: 2048 };

// The attach route arrives in a later slice, so these tests build the spans the way it will.
const make = (text, spans) => {
  const c = new Composer({ onSubmit: () => true });
  c.rect = { x: 0, y: 0, w: 40, h: 6 };
  c.text = text;
  c.spans = spans;
  return c;
};

// The label draws instead of the path, and the type comes from the mime.
const two = make("look at /a.png and /b.png please", [{ start: 8, end: 14, blob: png }, { start: 19, end: 25, blob: jpg }]);
check("labels", two.projection().text === "look at [PNG #1] and [JPEG #2] please");

// The number is derived from position, so a delete renumbers the rest.
const del = make("/a.png /b.png", [{ start: 0, end: 6, blob: png }, { start: 7, end: 13, blob: jpg }]);
check("two-labels", del.projection().text === "[PNG #1] [JPEG #2]");
del.input.caret = 6;
del.onKey(key("backspace"));
check("renumbered", del.spans.length === 1 && del.projection().text === " [JPEG #1]");

// Images at the end give one text part and the images after it.
const tail = make("here /a.png /b.png", [{ start: 5, end: 11, blob: png }, { start: 12, end: 18, blob: jpg }]);
const tailParts = tail.content();
check("tail-count", tailParts.length === 3);
check("tail-text", tailParts[0].type === "text" && tailParts[0].text === "here ");
check("tail-images", tailParts[1].source === png && tailParts[2].source === jpg);

// An image between two runs splits the text, and each run keeps the space beside the image.
const mid = make("  before /a.png after  ", [{ start: 9, end: 15, blob: png }]);
check("mid-parts", JSON.stringify(mid.content()) === JSON.stringify([{ type: "text", text: "before " }, { type: "image", source: png }, { type: "text", text: " after" }]));

// A run of whitespace alone between two images carries nothing.
const gap = make("/a.png /b.png", [{ start: 0, end: 6, blob: png }, { start: 7, end: 13, blob: jpg }]);
check("gap-parts", gap.content().length === 2);

// An image with no text is a whole input on its own.
const alone = make("/a.png", [{ start: 0, end: 6, blob: png }]);
check("image-only", alone.content().length === 1 && alone.content()[0].type === "image");

// A submit on an image alone is not the empty submit that a blank buffer makes.
const sent = [];
const one = make("/a.png", [{ start: 0, end: 6, blob: png }]);
one.onSubmit = (content) => { sent.push(content); };
one.onKey(key("enter"));
check("image-submits", sent.length === 1 && sent[0].length === 1);
check("image-clears", one.text === "" && one.spans.length === 0);
one.onKey(key("enter"));
check("empty-submits-nothing", sent.length === 1);

// A snapshot puts the images back with the text after a failed send.
const snapped = make("look at /a.png", [{ start: 8, end: 14, blob: png }]);
const snap = snapped.snapshot();
snapped.text = "";
check("wiped", snapped.spans.length === 0);
snapped.restore(snap);
check("restored", snapped.text === "look at /a.png" && snapped.projection().text === "look at [PNG #1]");

// A restore lands above what the user typed since, and the live spans move past it.
const since = make("/a.png", [{ start: 0, end: 6, blob: png }]);
const held = since.snapshot();
since.text = "";
since.text = "typed since";
since.restore(held);
check("restore-prepends", since.text === "/a.png\ntyped since");
check("restore-label", since.projection().text === "[PNG #1]\ntyped since");

// A snapshot is a copy, so a later edit never reaches back into it.
const copy = make("/a.png", [{ start: 0, end: 6, blob: png }]);
const kept = copy.snapshot();
copy.input.caret = 6;
copy.onKey(key("backspace"));
check("snapshot-is-a-copy", copy.spans.length === 0 && kept.spans.length === 1);
