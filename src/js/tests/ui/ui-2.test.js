import { check } from "yuke:test";
import { List } from "yuke:ui";
import { Transcript } from "yuke:transcript";
import { fuzzyMatch, fuzzyRank } from "yuke:fzy";

// A two-line list shows floor(h / itemHeight) items and scrolls in item units.
const l = new List({ items: [0, 1, 2, 3, 4, 5], itemHeight: 2 });
l.moveToEdge(1);
check("sel-end", l.selectedIndex() === 5);
l.ensureVisible(6);
check("scroll-bottom", l.scroll === 3);
l.moveToEdge(-1);
l.ensureVisible(6);
check("scroll-top", l.scroll === 0 && l.selectedIndex() === 0);

// fzy requires a subsequence and prefers a word boundary.
check("nomatch", fuzzyMatch("abc", "xyz") === null);
check("empty", fuzzyMatch("abc", "") === 0);
const ranked = fuzzyRank(["afboo", "foo_bar", "random"], "fb", String);
check("boundary-first", ranked[0] === "foo_bar");
const dog = fuzzyRank(["cat", "dog"], "og", String);
check("subsequence", dog.length === 1 && dog[0] === "dog");
check("over-long-cap", fuzzyMatch("a".repeat(1025), "a") === -Infinity);

// A user turn is a tinted band with a gutter marker; an assistant turn renders markdown.
const texts = { u1: "hello world", a1: "**bold** text" };
const t = new Transcript({ textOf: (id) => texts[id] || "" });
t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }], null);
const rows = t.rows(40, 0, 100);
check("user-band", rows.some((r) => r.marker === "⟩" && r.bg === "TxUser"));
check("assistant-md", rows.some((r) => r.segments && r.segments.some((s) => s.group === "MdStrong" && s.text === "bold")));

// A draft delta re-renders the assistant turn through yuke:md.
texts.a2 = "streamed";
t.setActive("a2");
const rows2 = t.rows(40, 0, 100);
check("draft", rows2.some((r) => r.segments && r.segments.some((s) => s.text.indexOf("streamed") >= 0)));
