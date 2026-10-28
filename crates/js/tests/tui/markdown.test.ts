// Markdown to styled rows: the blocks, the inline styles, the wrap, the stream, and the map from a segment to its
// source.

import { Markdown, type Row, type Segment } from "yuke:internal/tui/markdown";
import { assert, equal, test } from "yuke:test";

function rowsOf(source: string, width: number): readonly Row[] {
  const markdown = new Markdown();
  markdown.setText(source);
  return markdown.rows(width);
}

function segmentsOf(rows: readonly Row[]): Segment[] {
  return rows.flatMap((row) => row.segments);
}

/** The text of each row. */
function lines(rows: readonly Row[]): string[] {
  return rows.map((row) => row.segments.map((s) => s.text).join(""));
}

/** Whether a segment of `rows` has the style `style` and the text `text`. */
function has(rows: readonly Row[], style: string, text: string): boolean {
  return segmentsOf(rows).some((s) => s.style === style && s.text === text);
}

function find(rows: readonly Row[], style: string, text: string): Segment | undefined {
  return segmentsOf(rows).find((s) => s.style === style && s.text === text);
}

test("inline markup gives strong, emphasis, code, and both", () => {
  equal(
    [
      has(rowsOf("hello **bold** and `code`", 80), "markdown.strong", "bold"),
      has(rowsOf("x `y` z", 80), "markdown.code", "y"),
      has(rowsOf("an *word* here", 80), "markdown.emphasis", "word"),
      has(rowsOf("***wow***", 80), "markdown.strongEmphasis", "wow"),
      has(rowsOf("use ``a`b`` now", 80), "markdown.code", "a`b"),
    ],
    [true, true, true, true, true],
  );
});

test("an inner strong span keeps the outer emphasis", () => {
  const rows = rowsOf("*x **y** z*", 80);
  equal(
    [
      has(rows, "markdown.strongEmphasis", "y"),
      has(rows, "markdown.emphasis", "x"),
      has(rows, "markdown.emphasis", "z"),
    ],
    [true, true, true],
  );
});

test("an underscore inside a word and an escaped marker stay literal", () => {
  const plain = (source: string) => segmentsOf(rowsOf(source, 80)).every((s) => s.style === "markdown.text");
  equal([plain("call foo_bar_baz now"), plain("not \\*bold\\* here")], [true, true]);
});

test("each block kind has its style", () => {
  equal(
    [
      has(rowsOf("# Title", 80), "markdown.heading", "Title"),
      has(rowsOf("```js\nx=1\n```", 80), "markdown.codeBlock", "x=1"),
      segmentsOf(rowsOf("---", 80)).some((s) => s.style === "markdown.rule"),
      has(rowsOf("- a\n- b", 80), "markdown.listMark", "• "),
      segmentsOf(rowsOf("> hi", 80)).some((s) => s.style === "markdown.quote"),
    ],
    [true, true, true, true, true],
  );
});

test("each block marker still opens its block after three spaces", () => {
  const kinds = (source: string) => {
    const markdown = new Markdown();
    markdown.setText(source);
    return markdown
      .blocks()
      .map((b) => b.kind)
      .join(",");
  };
  equal(
    ["   ```\nx\n```", "   ~~~\nx\n~~~", "   # H", "   - a", "   * a", "   + a", "p\n   1. a", "   ___", "   > q"].map(
      kinds,
    ),
    ["code", "code", "heading", "list", "list", "list", "paragraph,list", "hr", "quote"],
  );
  equal([kinds("x\n   ==="), kinds("x\n   ---")], ["heading", "heading"]);
});

// A link keeps its brackets and its target, so the user can copy the target. Each piece of it knows the target.
test("a link shows its label and its target, and each piece carries the target", () => {
  const rows = rowsOf("see [the **docs**](http://x/a_b) ok", 80);

  equal(lines(rows), ["see [the docs](http://x/a_b) ok"]);
  equal(
    segmentsOf(rows).map((s) => [s.text, s.style, s.link]),
    [
      ["see", "markdown.text", undefined],
      [" ", "markdown.text", undefined],
      ["[", "markdown.link", "http://x/a_b"],
      ["the", "markdown.linkText", "http://x/a_b"],
      [" ", "markdown.linkText", "http://x/a_b"],
      ["docs", "markdown.strong", "http://x/a_b"],
      ["](http://x/a_b)", "markdown.link", "http://x/a_b"],
      [" ", "markdown.text", undefined],
      ["ok", "markdown.text", undefined],
    ],
  );
});

test("a link label keeps the emphasis around it, and a target with a space is no link", () => {
  equal(
    [
      has(rowsOf("*[x](u)* y", 80), "markdown.emphasis", "x"),
      lines(rowsOf("[foo](bad url)", 80)),
      segmentsOf(rowsOf("[foo](bad url)", 80)).some((s) => s.link !== undefined),
    ],
    [true, ["[foo](bad url)"], false],
  );
});

test("a table lines up its columns, and a long cell wraps inside its column", () => {
  equal(lines(rowsOf("| a | bb |\n|---|---|\n| ccc | d |", 80)), ["a   │ bb", "────┼───", "ccc │ d"]);
  const wrapped = lines(rowsOf("| k | value |\n|---|---|\n| x | one two three four five six |", 20));
  assert(wrapped.length > 3 && wrapped.every((line) => line.length <= 20), wrapped.join("\n"));
  assert(wrapped[2]?.startsWith("x │ one"), wrapped.join("\n"));
  equal(
    has(rowsOf("| abcdefghij | klmnopqrst |\n|---|---|", 22), "markdown.tableBorder", "──────────┼───────────"),
    true,
  );
});

test("a table aligns each column by the colons of its separator", () => {
  equal(lines(rowsOf("| l | c | r |\n|:--|:-:|--:|\n| a | b | c |\n| aaaa | bbbb | cccc |", 80)), [
    "l    │  c   │    r",
    "─────┼──────┼─────",
    "a    │  b   │    c",
    "aaaa │ bbbb │ cccc",
  ]);
});

test("a long paragraph wraps to the width and keeps each word", () => {
  equal(lines(rowsOf("alpha bravo charlie delta", 11)), ["alpha bravo", "charlie", "delta"]);
});

// A pane can have no width for a moment, and a row then still takes one character.
test("a code block at width 0 gives one character for each row", () => {
  equal(lines(rowsOf("```\nab\n```", 0)), ["a", "b"]);
});

test("an open fence stays code and renders again as it grows", () => {
  const markdown = new Markdown();
  markdown.setText("# H\n\n```\nx=1");
  const first = has(markdown.rows(80), "markdown.codeBlock", "x=1");
  markdown.setText("# H\n\n```\nx=2");
  equal([first, has(markdown.rows(80), "markdown.codeBlock", "x=2")], [true, true]);
});

// Every block kind, with look-ahead: a setext heading, a table, and a fence that closes late.
test("each prefix of a stream renders as a fresh parse of it", () => {
  const text =
    "Intro para\nsecond line\n\n# Head\n\nSetext\n===\n\n- one\n- two\n\n1. first\n2. second\n\n> quoted\n> more\n\n" +
    "a | b\n:--|--:\n1 | 2\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n---\n\nlast **bold** [a](b) para\nwith a|pipe\n---|---\nx|y\n";
  const stream = new Markdown();
  const appended = new Markdown();
  const differs: (number | string)[] = [];
  for (let n = 1; n <= text.length; n++) {
    const head = text.slice(0, n);
    stream.setText(head);
    appended.append(text.slice(n - 1, n), head);
    const fresh = new Markdown();
    fresh.setText(head);
    const expected = JSON.stringify([fresh.blocks(), fresh.rows(24)]);
    if (JSON.stringify([stream.blocks(), stream.rows(24)]) !== expected) differs.push(n);
    if (JSON.stringify([appended.blocks(), appended.rows(24)]) !== expected) differs.push(`append ${n}`);
  }
  // A change that is no append parses from the start again.
  stream.setText(`changed\n\n${text}`);
  const fresh = new Markdown();
  fresh.setText(`changed\n\n${text}`);
  if (JSON.stringify(stream.rows(24)) !== JSON.stringify(fresh.rows(24))) differs.push("rewrite");
  equal(differs, []);
});

// Each span stays inside the source and holds the text that it shows. A mark hides its markup, and an escape is the
// same text behind a backslash.
test("each segment maps back to its source at each width", () => {
  const corpus = [
    "hello **bold** and `code`",
    "# Title\n\npara one\npara two",
    "> one\n> two",
    "- alpha\n- bravo",
    "1. one\n2. two",
    "| a | b |\n|---|---|\n| 1 | 2 |",
    "| a\\|b | c |\n|:-:|---|\n| 1 | 2 |",
    "```js\nlet x = 1;\n```",
    "not \\*bold\\* here",
    "see [docs](http://x) ok",
    "***wow*** and *x **y** z*",
    "---",
    "Setext\n======",
  ];
  const wrong: string[] = [];
  for (const source of corpus) {
    for (const width of [80, 24, 7]) {
      for (const s of segmentsOf(rowsOf(source, width))) {
        if (s.src === undefined) continue;
        const end = s.srcEnd as number;
        const span = source.slice(s.src, end);
        const inside = s.src >= 0 && end > s.src && end <= source.length;
        if (!inside || (s.mark !== true && span !== s.text && span.split("\\").join("") !== s.text)) {
          wrong.push(`${width} ${JSON.stringify(source)} ${JSON.stringify(s)}`);
        }
      }
    }
  }
  equal(wrong, []);
});

test("a styled word maps to the word, and the span between two keeps the markup", () => {
  const source = "hello **bold** and `code`";
  const bold = find(rowsOf(source, 80), "markdown.strong", "bold");
  const code = find(rowsOf(source, 80), "markdown.code", "code");
  equal(
    [
      source.slice(bold?.src, bold?.srcEnd),
      source.slice(code?.src, code?.srcEnd),
      source.slice(bold?.src, code?.srcEnd),
    ],
    ["bold", "code", "bold** and `code"],
  );
});

test("an escape shows one character and keeps both characters of its source", () => {
  const source = "a \\*b\\* c";
  const star = segmentsOf(rowsOf(source, 80)).find((s) => s.text === "*");
  equal(source.slice(star?.src, star?.srcEnd), "\\*");
});

test("a wrapped word, a second paragraph line, and a second quote line keep their offsets", () => {
  const wrapped = "alpha bravo charlie delta";
  const paragraph = "one two\nthree four";
  const quote = "> one\n> two";
  const quoted = rowsOf(quote, 80);
  const bar = find(quoted, "markdown.quote", "▏ ");
  equal(
    [
      find(rowsOf(wrapped, 12), "markdown.text", "delta")?.src,
      find(rowsOf(paragraph, 80), "markdown.text", "three")?.src,
      find(quoted, "markdown.quote", "two")?.src,
      lines(quoted),
      quote.slice(bar?.src, bar?.srcEnd),
    ],
    [wrapped.indexOf("delta"), paragraph.indexOf("three"), quote.indexOf("two"), ["▏ one two"], "> "],
  );
});

test("a list mark, a fence line, a rule, and a table cell map to their markup", () => {
  const list = "- alpha\n- bravo";
  const mark = segmentsOf(rowsOf(list, 80)).find(
    (s) => s.style === "markdown.listMark" && s.src === list.indexOf("- bravo"),
  );
  const fence = "```js\nlet x = 1;\n```";
  const line = find(rowsOf(fence, 80), "markdown.codeBlock", "let x = 1;");
  const rule = rowsOf("---", 10)[0]?.segments[0];
  const table = "| a\\|b | c |\n|---|---|\n| 1 | 2 |";
  const pipe = segmentsOf(rowsOf(table, 80)).find((s) => s.text === "|");
  equal(
    [
      list.slice(mark?.src, mark?.srcEnd),
      fence.slice(line?.src, line?.srcEnd),
      [rule?.src, rule?.srcEnd],
      find(rowsOf(table, 80), "markdown.text", "1")?.src,
      table.slice(pipe?.src, pipe?.srcEnd),
    ],
    ["- ", "let x = 1;", [0, 3], table.indexOf("| 1 |") + 2, "\\|"],
  );
});

test("a leftover delimiter keeps its offset", () => {
  equal(segmentsOf(rowsOf("**x***", 80)).find((s) => s.text === "*")?.src, 5);
});

test("a hard break by grapheme keeps each piece on its offset", () => {
  const wide = segmentsOf(rowsOf("日本語", 2)).filter((s) => s.src !== undefined);
  const astral = "a𝄞b";
  const pieces = segmentsOf(rowsOf(astral, 1)).filter((s) => s.src !== undefined);
  equal(
    [wide.map((s) => [s.src, s.srcEnd]), pieces.map((s) => astral.slice(s.src, s.srcEnd) === s.text)],
    [
      [
        [0, 1],
        [1, 2],
        [2, 3],
      ],
      [true, true, true],
    ],
  );
});

test("two blocks with the same text keep their own offsets, also after the stream grows", () => {
  const source = "hi\n\nbye\n\nhi\n\nend";
  const markdown = new Markdown();
  markdown.setText("# H\n\npara one");
  markdown.rows(80);
  markdown.setText("# H\n\npara one two");
  equal(
    [
      segmentsOf(rowsOf(source, 80))
        .filter((s) => s.text === "hi")
        .map((s) => s.src),
      find(markdown.rows(80), "markdown.heading", "H")?.src,
    ],
    [[0, source.lastIndexOf("hi")], 2],
  );
});

test("an offset indexes the source after the line break change", () => {
  const markdown = new Markdown();
  markdown.setText("one two\r\nthree");
  const three = find(markdown.rows(80), "markdown.text", "three");
  equal(markdown.source().slice(three?.src, three?.srcEnd), "three");
});

// An ASCII word breaks by its cell count, and a word with wide characters breaks between graphemes. A wide word takes
// its cells, not its length.
test("a word wider than the row breaks at the width, also with wide characters", () => {
  equal(
    [lines(rowsOf("abcdefghij", 4)), lines(rowsOf("ab日本cd", 3)), lines(rowsOf("日本 ab", 5))],
    [
      ["abcd", "efgh", "ij"],
      ["ab", "日", "本c", "d"],
      ["日本", "ab"],
    ],
  );
});
