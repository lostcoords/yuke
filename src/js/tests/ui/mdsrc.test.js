import { check } from "yuke:test";
import { renderRows, Document } from "yuke:md";
const segsOf = (rows) => { const out = []; for (const r of rows) for (const s of r.segments) out.push(s); return out; };
const find = (rows, group, text) => segsOf(rows).find((s) => s.group === group && s.text === text);

// Every span stays inside the source and holds the text it rendered. A mark hides its markup,
// so it is the one segment whose span does not contain the text.
const mapsBack = (src, rows) => {
  for (const s of segsOf(rows)) {
    if (s.src == null) continue;
    if (s.src < 0 || s.srcEnd <= s.src || s.srcEnd > src.length) return false;
    if (s.mark) continue;
    const span = src.slice(s.src, s.srcEnd);
    // A linear segment is its own source. An escape is the same text behind a backslash.
    if (span !== s.text && span.split("\\").join("") !== s.text) return false;
  }
  return true;
};
const corpus = [
  "hello **bold** and `code`",
  "# Title\n\npara one\npara two",
  "> one\n> two",
  "- alpha\n- bravo",
  "1. one\n2. two",
  "| a | b |\n|---|---|\n| 1 | 2 |",
  "| a\\|b | c |\n|---|---|\n| 1 | 2 |",
  "```js\nlet x = 1;\n```",
  "not \\*bold\\* here",
  "see [docs](http://x) ok",
  "***wow*** and *x **y** z*",
  "---",
  "Setext\n======",
];
for (const src of corpus) {
  const doc = new Document();
  doc.setText(src);
  for (const w of [80, 24, 7]) check("maps-back:" + w + ":" + src.slice(0, 8), mapsBack(src, doc.rows(w)));
}

// A rendered word maps to the word, and a span still holds the markup between its ends.
{
  const src = "hello **bold** and `code`";
  const rows = renderRows(src, 80);
  const b = find(rows, "MdStrong", "bold");
  const c = find(rows, "MdCode", "code");
  check("strong-src", b && src.slice(b.src, b.srcEnd) === "bold");
  check("code-src", c && src.slice(c.src, c.srcEnd) === "code");
  check("span-keeps-markup", b && c && src.slice(b.src, c.srcEnd) === "bold** and `code");
}

// An escape renders one character over two, so it keeps the whole markup.
{
  const src = "a \\*b\\* c";
  const star = segsOf(renderRows(src, 80)).find((s) => s.text === "*");
  check("escape-atomic", star && star.srcEnd - star.src === 2 && src.slice(star.src, star.srcEnd) === "\\*");
}

{
  const src = "alpha bravo charlie delta";
  const rows = renderRows(src, 12);
  const d = find(rows, "MdText", "delta");
  check("wrap-rows", rows.length > 1);
  check("wrap-src", d && d.src === src.indexOf("delta"));
}

// A paragraph joins its lines with one space, so the second line keeps its offsets.
{
  const src = "one two\nthree four";
  const t = find(renderRows(src, 80), "MdText", "three");
  check("para-line-2", t && t.src === src.indexOf("three"));
}

// A quote drops the "> " of each line, so a segment splits at the line edge.
{
  const src = "> one\n> two";
  const rows = renderRows(src, 80);
  const t = find(rows, "MdQuote", "two");
  const bar = find(rows, "MdQuote", "▏ ");
  const flat = rows.map((r) => r.segments.map((g) => g.text).join("")).join("");
  // A soft line break is a word gap, so no row ever holds a line feed.
  check("quote-one-line", flat === "▏ one two");
  check("quote-line-2", t && t.src === src.indexOf("two"));
  check("quote-bar", bar && src.slice(bar.src, bar.srcEnd) === "> ");
}

// A list marker takes the span of the source marker.
{
  const src = "- alpha\n- bravo";
  const rows = renderRows(src, 80);
  const b = find(rows, "MdText", "bravo");
  const mark = segsOf(rows).find((s) => s.group === "MdListMark" && s.src === src.indexOf("- bravo"));
  check("list-item", b && b.src === src.indexOf("bravo"));
  check("list-mark", mark && src.slice(mark.src, mark.srcEnd) === "- ");
}

check("fence-src", (() => {
  const src = "```js\nlet x = 1;\n```";
  const c = find(renderRows(src, 80), "MdCodeBlock", "let x = 1;");
  return c && src.slice(c.src, c.srcEnd) === "let x = 1;";
})());
check("hr-src", (() => {
  const r = renderRows("---", 10)[0].segments[0];
  return r.src === 0 && r.srcEnd === 3;
})());

// An escaped pipe renders as one character and keeps the whole markup, like any escape.
{
  const src = "| a\\|b | c |\n|---|---|\n| 1 | 2 |";
  const rows = renderRows(src, 80);
  const one = find(rows, "MdText", "1");
  const pipe = segsOf(rows).find((s) => s.text === "|");
  check("table-cell", one && one.src === src.indexOf("| 1 |") + 2);
  check("table-escape", pipe && src.slice(pipe.src, pipe.srcEnd) === "\\|");
}

// A closer consumes its run from the start, so the leftover marker keeps the true offset.
{
  const src = "**x***";
  const star = segsOf(renderRows(src, 80)).find((s) => s.text === "*");
  check("leftover-delim", star && star.src === 5);
}

// A hard break by grapheme keeps each piece on its own offset.
{
  const wide = segsOf(renderRows("日本語", 2)).filter((s) => s.src != null);
  check("grapheme-rows", wide.length === 3);
  check("grapheme-offsets", wide.every((s, k) => s.src === k && s.srcEnd === k + 1));
  const src = "a𝄞b";
  const astral = segsOf(renderRows(src, 1)).filter((s) => s.src != null);
  check("astral-pieces", astral.length === 3);
  check("astral-offsets", astral.every((s) => src.slice(s.src, s.srcEnd) === s.text));
}

// Two blocks can hold the same text, so the second one keeps its own source position.
{
  const src = "hi\n\nbye\n\nhi\n\nend";
  const doc = new Document();
  doc.setText(src);
  const his = segsOf(doc.rows(80)).filter((s) => s.text === "hi");
  check("dup-blocks", his.length === 2 && his[0].src === 0 && his[1].src === src.lastIndexOf("hi"));
}

{
  const doc = new Document();
  doc.setText("# H\n\npara one");
  doc.rows(80);
  doc.setText("# H\n\npara one two");
  const h = find(doc.rows(80), "MdHeading", "H");
  check("stream-offsets", h && h.src === 2);
}

// The offsets index the normalized text, so a CRLF source reads through sourceText.
{
  const doc = new Document();
  doc.setText("one two\r\nthree");
  const t = find(doc.rows(80), "MdText", "three");
  check("crlf-src", t && doc.sourceText().slice(t.src, t.srcEnd) === "three");
}
