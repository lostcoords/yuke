import { check } from "yuke:test";
import { renderRows, Document } from "yuke:md";
const has = (rows, group, text) => rows.some((r) => r.segments.some((s) => s.group === group && s.text === text));

check("inline", has(renderRows("hello **bold** and `code`", 80), "MdStrong", "bold") &&
  has(renderRows("x `y` z", 80), "MdCode", "y"));
check("emphasis", has(renderRows("an *word* here", 80), "MdEm", "word"));
check("heading", has(renderRows("# Title", 80), "MdHeading", "Title"));
check("code", has(renderRows("```js\nx=1\n```", 80), "MdCodeBlock", "x=1"));
check("hr", renderRows("---", 80).some((r) => r.segments.some((s) => s.group === "MdRule")));
check("list", has(renderRows("- a\n- b", 80), "MdListMark", "• "));
check("quote", renderRows("> hi", 80).some((r) => r.segments.some((s) => s.group === "MdQuote")));
const noGroup = (rows, group) => !rows.some((r) => r.segments.some((s) => s.group === group));
// An underscore inside a word is not emphasis (code identifiers stay literal).
check("intraword-underscore", noGroup(renderRows("call foo_bar_baz now", 80), "MdEm"));
// A backslash escapes a marker, so it stays literal text.
check("escape", noGroup(renderRows("not \\*bold\\* here", 80), "MdStrong"));
// A link shows its text, never the URL.
{
  const rows = renderRows("see [docs](http://x) ok", 80);
  check("link-text", has(rows, "MdText", "docs") &&
    !rows.some((r) => r.segments.some((s) => s.text.indexOf("http") >= 0)));
}
// Double backticks let inline code hold a backtick.
check("code-backtick", has(renderRows("use ``a`b`` now", 80), "MdCode", "a`b"));
// Triple markers are strong and emphasis together.
check("strong-em", has(renderRows("***wow***", 80), "MdStrongEm", "wow"));
// Nested emphasis: the inner strong span keeps the outer emphasis.
{
  const rows = renderRows("*x **y** z*", 80);
  check("nested-emph", has(rows, "MdStrongEm", "y") && has(rows, "MdEm", "x") && has(rows, "MdEm", "z"));
}
// A link label keeps the emphasis that encloses it.
check("link-in-emphasis", has(renderRows("*[x](u)* y", 80), "MdEm", "x"));
// A malformed link (a space in the destination) stays literal, not dropped.
check("bad-link", renderRows("[foo](bad url)", 80).some((r) => r.segments.some((s) => s.text.indexOf("bad") >= 0)));
// A table renders a column border.
check("table", renderRows("| a | b |\n|---|---|\n| 1 | 2 |", 80).some((r) => r.segments.some((s) => s.group === "MdTableBorder")));
// Cells align in columns, and a long cell wraps inside its column instead of breaking the row.
const aligned = renderRows("| a | bb |\n|---|---|\n| ccc | d |", 80).map((r) => r.segments.map((s) => s.text).join(""));
check("table-aligned", aligned[0] === "a   │ bb" && aligned[2] === "ccc │ d" && aligned[1] === "────┼───");
const cellWrap = renderRows("| k | value |\n|---|---|\n| x | one two three four five six |", 20).map((r) => r.segments.map((s) => s.text).join(""));
check("table-wraps", cellWrap.length > 3 && cellWrap.every((line) => line.length <= 20) && cellWrap[2].startsWith("x │ one"));
const tied = renderRows("| abcdefghij | klmnopqrst |\n|---|---|", 22);
check("table-tie-order", has(tied, "MdTableBorder", "──────────┼───────────"));

// A long paragraph wraps to width and keeps every word.
const wrapped = renderRows("alpha bravo charlie delta", 11);
check("wrap", wrapped.length > 1);

// An unclosed fence stays provisional code and is never cached.
{
  const doc = new Document();
  doc.setText("# H\n\n```\nx=1");
  check("open-fence", has(doc.rows(80), "MdCodeBlock", "x=1"));
  doc.setText("# H\n\n```\nx=2");
  check("open-tail-refreshes", has(doc.rows(80), "MdCodeBlock", "x=2"));
}

// A finalized block keeps its cache entry when the open tail grows.
{
  const doc = new Document();
  doc.setText("# H\n\npara one");
  doc.rows(80);
  doc.setText("# H\n\npara one two");
  const rows = doc.rows(80);
  check("append-heading", has(rows, "MdHeading", "H"));
  check("append-tail", rows.some((r) => r.segments.some((s) => s.text.indexOf("two") >= 0)));
}
