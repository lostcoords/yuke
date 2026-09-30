import { check, textParts } from "yuke:internal/test";
import { List } from "yuke:internal/ui";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";
import { fuzzyRank } from "yuke:internal/fzy";

registerRender(defaultRender);

// A two-line list shows floor(h / itemHeight) items and scrolls in item units.
const l = new List({ items: [0, 1, 2, 3, 4, 5], itemHeight: 2 });
l.navEdge(1);
check("sel-end", l.selectedIndex() === 5);
l.ensureVisible(6);
check("scroll-bottom", l.scroll === 3);
l.navEdge(-1);
l.ensureVisible(6);
check("scroll-top", l.scroll === 0 && l.selectedIndex() === 0);

// fzy requires a subsequence and prefers a word boundary.
const ranked = fuzzyRank(["afboo", "foo_bar", "random"], "fb", String);
check("boundary-first", ranked[0] === "foo_bar");
const dog = fuzzyRank(["cat", "dog"], "og", String);
check("subsequence", dog.length === 1 && dog[0] === "dog");
// A text over the length cap still matches, but it ranks last.
const long = "a".repeat(1025);
const capped = fuzzyRank([long, "ba"], "a", String);
check("over-long-cap", capped.length === 2 && capped[1] === long);
// The score rows are shared, so a short text after a long one reads none of the long one's cells.
const shorts = ["x_ab", "xab", "ax_b", "zzab"];
const before = fuzzyRank(shorts, "ab", String).join(",");
fuzzyRank(["ab".repeat(300) + "_ab"], "ab", String);
check("rows-reused", fuzzyRank(shorts, "ab", String).join(",") === before);

// A user turn is a shaded block; an assistant turn renders markdown.
const texts = { u1: "hello world", a1: "**bold** text" };
const t = new Transcript({ partsOf: textParts((id) => texts[id] || "") });
t.setOutline([{ id: "u1", type: "user" }, { id: "a1", type: "assistant" }], null);
const rows = t.rows(40, 0, 100);
check("user-band", rows.some((r) => r.bg === "TxUser" && r.text === "hello world" && r.indent === 2) && t.rows(3, 0, 100).some((r) => r.bg === "TxUser" && r.indent === 1));
check("assistant-md", rows.some((r) => r.segments && r.segments.some((s) => s.group === "MdStrong" && s.text === "bold")));

// A draft delta re-renders the assistant turn through yuke:internal/md.
texts.a2 = "streamed";
t.setActive("a2");
const rows2 = t.rows(40, 0, 100);
check("draft", rows2.some((r) => r.segments && r.segments.some((s) => s.text.indexOf("streamed") >= 0)));
