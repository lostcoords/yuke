// The text view of `yuke:tui`: positions on sections, copy, the mouse, hidden sections, Markdown rows, extensions,
// and its scroll control.

import { assertEquals, assertThrows, createFrame, test, waitForSettled } from "yuke:test";
import {
  Markdown,
  type MouseEvent,
  type TextDocument,
  type TextItem,
  type TextPosition,
  type TextRow,
  TextView,
  type TextViewChange,
} from "yuke:tui";
import { rows } from "./rows.ts";

const MODIFIERS = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };

function mouse(column: number, row: number, action: MouseEvent["action"]): MouseEvent {
  return { type: "mouse", column, row, button: "left", action, modifiers: MODIFIERS };
}

/** An item of plain text sections, each `[key, text]`. */
function item(key: string, ...sections: [string, string][]): TextItem {
  return { id: key, sections: sections.map(([section, text]) => ({ id: section, kind: "text", text })) };
}

function document(key: string, ...items: TextItem[]): TextDocument {
  return { id: key, items };
}

function at(item: string, section: string, offset: number): TextPosition {
  return { item, section, offset };
}

test("a drag copies both end graphemes in either direction", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "xA👩‍💻By"])) });
  using frame = createFrame({ width: 20, height: 2 }, () => view);
  // "A" is at cell 1, the astronaut takes cells 2 and 3, and "B" is at cell 4.
  frame.mouse(mouse(1, 0, "press"));
  frame.mouse(mouse(4, 0, "drag"));
  frame.mouse(mouse(4, 0, "release"));
  frame.mouse(mouse(4, 0, "press"));
  frame.mouse(mouse(1, 0, "drag"));
  frame.mouse(mouse(1, 0, "release"));
  assertEquals(frame.copies, ["A👩‍💻B", "A👩‍💻B"]);
});

test("a position stays on its section when an earlier item grows and when an item comes first", () => {
  const view = new TextView({
    document: document("d", item("one", ["s", "aaa"]), item("two", ["body", "hello world"])),
  });
  using frame = createFrame({ width: 20, height: 6 }, () => view);
  view.caret = at("two", "body", 2);
  assertEquals(frame.draw().cursor, { column: 2, row: 1 });
  view.setDocument(
    document(
      "d",
      item("zero", ["s", "first"]),
      item("one", ["s", "aaa\nbbb\nccc"]),
      item("two", ["body", "hello world"]),
    ),
  );
  assertEquals(
    [view.caret, frame.draw().cursor, view.rows.text(4)],
    [at("two", "body", 2), { column: 2, row: 4 }, "hello world"],
  );
});

test("a copy puts a line end between two sections and between two items, in display and in source", () => {
  const view = new TextView({
    document: document("d", item("tool", ["title", "Read a.rs"], ["body", "fn main() {}"]), item("next", ["s", "ok"])),
  });
  using frame = createFrame({ width: 20, height: 4 }, () => view);
  const range = { from: at("tool", "title", 5), to: at("next", "s", 2) };
  assertEquals([view.text(range), view.text(range, "source")], ["a.rs\nfn main() {}\nok", "a.rs\nfn main() {}\nok"]);
  void frame;
});

test("a Markdown row maps each cell to its source across a paragraph line break", () => {
  const text = "one\ntwo";
  const markdown = new Markdown(text);
  const section = { id: "s", kind: "text" as const, text, render: (width: number) => markdown.rows(width) };
  const view = new TextView({ document: document("d", { id: "i", sections: [section] }) });
  using frame = createFrame({ width: 20, height: 2 }, () => view);
  frame.draw();
  assertEquals(
    [view.rows.text(0), view.rows.at({ column: 5, row: 0 }), view.rows.point(at("i", "s", 5))],
    ["one two", at("i", "s", 5), { column: 5, row: 0 }],
  );
});

test("a Markdown section maps rows to its source, a replacement as a whole", () => {
  const text = "- **bold** item";
  const markdown = new Markdown(text);
  const view = new TextView({
    document: {
      id: "d",
      items: [{ id: "i", sections: [{ id: "s", kind: "text", text, render: (width) => markdown.rows(width) }] }],
    },
  });
  using frame = createFrame({ width: 20, height: 2 }, () => view);
  assertEquals(rows(frame.frame)[0], "• bold item");
  // "b" of "bold" is at source offset 4 and shows at cell 2, after the mark "• ".
  assertEquals(
    [view.rows.point(at("i", "s", 4)), view.rows.at({ column: 2, row: 0 })],
    [{ column: 2, row: 0 }, at("i", "s", 4)],
  );
  // The mark "• " stands for "- ": a cell inside it maps to an end of that source.
  assertEquals(
    [view.rows.at({ column: 1, row: 0 }), view.rows.at({ column: 1, row: 0 }, "cell", "after")],
    [at("i", "s", 0), at("i", "s", 2)],
  );
});

test("a hidden section has no place, and the caret on it shows no cursor", () => {
  const view = new TextView({
    document: {
      id: "d",
      items: [
        {
          id: "i",
          sections: [
            { id: "shown", kind: "label", text: "Tool" },
            { id: "body", kind: "text", text: "output", render: () => [] },
          ],
        },
      ],
    },
  });
  using frame = createFrame({ width: 20, height: 2 }, () => view);
  view.caret = at("i", "body", 1);
  assertEquals(
    [view.rows.point(at("i", "body", 1)), view.ensureVisible(at("i", "body", 1)), frame.draw().cursor],
    [undefined, false, undefined],
  );
});

test("a press on an item that the document drops activates nothing at the release", () => {
  const activated: TextPosition[] = [];
  const view = new TextView({
    document: document("d", item("draft", ["s", "abc"]), item("next", ["s", "def"])),
    onActivate: (position) => activated.push(position),
  });
  using frame = createFrame({ width: 10, height: 2 }, () => view);
  const notices = frame.surface("watch").tui.notices;
  frame.mouse(mouse(1, 0, "press"));
  view.setDocument(document("d", item("saved", ["s", "abc"]), item("next", ["s", "def"])));
  frame.mouse(mouse(2, 0, "drag"));
  frame.mouse(mouse(2, 0, "release"));
  // A drag from the removed item would throw in the view, and the core would report a fault.
  assertEquals([activated, view.selection, frame.copies, notices.list()], [[], undefined, [], []]);
});

test("a click gives activate the link of the segment under it, or none", () => {
  const activated: [string, string | undefined][] = [];
  const linked: TextRow = {
    segments: [
      { text: "see ", source: { kind: "text", from: 0, to: 4 } },
      { text: "docs", source: { kind: "text", from: 4, to: 8 }, link: "https://docs.rs" },
    ],
    join: "\n",
  };
  const view = new TextView({
    document: document("d", {
      id: "i",
      sections: [{ id: "s", kind: "text", text: "see docs", render: () => [linked] }],
    }),
    onActivate: (position, link) => activated.push([`${position.item}:${position.offset}`, link]),
  });
  using frame = createFrame({ width: 10, height: 1 }, () => view);
  for (const column of [5, 1]) {
    frame.mouse(mouse(column, 0, "press"));
    frame.mouse(mouse(column, 0, "release"));
  }
  assertEquals(activated, [
    ["i:5", "https://docs.rs"],
    ["i:1", undefined],
  ]);
});

test("a click without a drag activates its position and copies nothing", () => {
  const activated: TextPosition[] = [];
  const view = new TextView({
    document: document("d", item("i", ["s", "abc"])),
    onActivate: (position) => activated.push(position),
  });
  using frame = createFrame({ width: 10, height: 1 }, () => view);
  frame.mouse(mouse(2, 0, "press"));
  frame.mouse(mouse(2, 0, "release"));
  assertEquals([activated, frame.copies], [[at("i", "s", 2)], []]);
});

test("a widget watcher gets the view, and an extension draws its decoration and its cursor shape", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "abcdef"])) });
  using frame = createFrame({ width: 10, height: 1 }, () => view);
  const surface = frame.surface("vim");
  surface.tui.widgets.addWatcher((mount) => {
    if (mount.widget.kind !== "textView") return undefined;
    const extension = mount.widget.extend(mount.signal);
    extension.setAppearance({ cursorShape: "block" });
    extension.setDecorations([{ range: { anchor: at("i", "s", 1), head: at("i", "s", 3) }, style: { bg: 2 } }]);
    return () => extension.dispose();
  });
  view.caret = at("i", "s", 4);
  const drawn = frame.draw();
  assertEquals(
    [[0, 1, 2, 3].map((column) => drawn.cells[0]?.[column]?.style), drawn.cursor],
    [[{}, { bg: 2 }, { bg: 2 }, {}], { column: 4, row: 0, shape: "block" }],
  );
});

test("a plugin sees a motion with no button and marks the row under the mouse, and the view keeps its selection", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "abcdef"])) });
  using frame = createFrame({ width: 10, height: 1 }, () => view);
  frame.surface("hover").tui.widgets.addWatcher((mount) => {
    if (mount.widget.kind !== "textView") return undefined;
    const widget = mount.widget;
    const extension = widget.extend(mount.signal);
    extension.addMouseHandler((event) => {
      const head = event.action === "motion" ? widget.hitTest(event) : undefined;
      if (head !== undefined) {
        const anchor = { ...head, offset: 0 };
        extension.setDecorations([{ range: { anchor, head }, style: { bg: 2 } }]);
      }
      return false;
    });
    return () => extension.dispose();
  });
  frame.mouse(mouse(3, 0, "press"));
  frame.mouse(mouse(5, 0, "drag"));
  frame.mouse(mouse(5, 0, "release"));
  const selection = view.selection;
  frame.mouse({ ...mouse(2, 0, "motion"), button: "none" });
  const drawn = frame.draw();
  assertEquals(
    [[0, 1, 2].map((column) => drawn.cells[0]?.[column]?.style), view.selection, selection === undefined],
    [[{ bg: 2 }, { bg: 2 }, {}], selection, false],
  );
});

test("a new document key clears the caret, a failed render keeps the document, and each change counts", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "abc"])) });
  using frame = createFrame({ width: 10, height: 2 }, () => view);
  const kinds: string[] = [];
  view
    .extend(new AbortController().signal)
    .addChangeListener((change: TextViewChange) => kinds.push(`${change.kind} ${change.revision}`));
  const start = view.revision;
  view.caret = at("i", "s", 1);
  view.setDocument(document("other", item("i", ["s", "abc"])));
  assertEquals(view.caret, undefined);
  const before = view.document;
  assertThrows(() =>
    view.setDocument({
      id: "other",
      items: [
        {
          id: "x",
          sections: [
            {
              id: "s",
              kind: "text",
              text: "x",
              render: () => {
                throw new Error("bad render");
              },
            },
          ],
        },
      ],
    }),
  );
  assertEquals([view.document === before, kinds], [true, [`selection ${start + 1}`, `document ${start + 2}`]]);
  assertThrows(() => view.compare(at("i", "s", 0), at("missing", "s", 0)));
  void frame;
});

test("the scroll control follows the tail and asks for older items", async () => {
  let asked = 0;
  const items = Array.from({ length: 5 }, (_, index) => item(`i${index}`, ["s", `line ${index}`]));
  const view = new TextView({
    document: document("d", ...items),
    followTail: true,
    onTopReached: () => {
      asked += 1;
    },
  });
  using frame = createFrame({ width: 10, height: 2 }, () => view);
  assertEquals(rows(frame.frame), ["line 3", "line 4"]);
  view.scroll.scrollTo(0);
  frame.draw();
  await waitForSettled();
  assertEquals(asked, 1);
});

test("a copy over Markdown leaves out the quote bar and ends the section with a line end", () => {
  const quote = new Markdown("> one two");
  const view = new TextView({
    document: {
      id: "d",
      items: [
        {
          id: "i",
          sections: [
            { id: "quote", kind: "text", text: "> one two", render: (width) => quote.rows(width) },
            { id: "after", kind: "text", text: "next" },
          ],
        },
      ],
    },
  });
  using frame = createFrame({ width: 20, height: 3 }, () => view);
  assertEquals(view.text({ from: at("i", "quote", 0), to: at("i", "after", 4) }), "one two\nnext");
  void frame;
});

test("a position at a soft wrap takes the earlier row before it and the later row after it", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "abcd efgh"])) });
  using frame = createFrame({ width: 5, height: 2 }, () => view);
  assertEquals(
    [view.rows.point(at("i", "s", 5), "cell", "before"), view.rows.point(at("i", "s", 5), "cell", "after")],
    [
      { column: 5, row: 0 },
      { column: 0, row: 1 },
    ],
  );
  void frame;
});

test("a scroll of the view gives a scroll change", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "a\nb\nc\nd"])) });
  using frame = createFrame({ width: 5, height: 2 }, () => view);
  const kinds: string[] = [];
  view.extend(new AbortController().signal).addChangeListener((change) => kinds.push(change.kind));
  view.scroll.scrollBy(1);
  assertEquals(kinds, ["scroll"]);
  void frame;
});

test("a drag from a wide grapheme or inside a list mark keeps the whole of it", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "xA👩‍💻By"])) });
  using frame = createFrame({ width: 20, height: 1 }, () => view);
  frame.mouse(mouse(2, 0, "press"));
  frame.mouse(mouse(1, 0, "drag"));
  frame.mouse(mouse(1, 0, "release"));
  const list = new Markdown("- item");
  const marked = new TextView({
    document: {
      id: "d",
      items: [{ id: "i", sections: [{ id: "s", kind: "text", text: "- item", render: (width) => list.rows(width) }] }],
    },
  });
  using second = createFrame({ width: 20, height: 1 }, () => marked);
  second.mouse(mouse(0, 0, "press"));
  second.mouse(mouse(1, 0, "drag"));
  second.mouse(mouse(1, 0, "release"));
  assertEquals([frame.copies, second.copies], [["A👩‍💻"], ["• "]]);
});

test("a blank row between two Markdown blocks maps to the source next to it", () => {
  const text = "a\n\nb";
  const markdown = new Markdown(text);
  const view = new TextView({
    document: {
      id: "d",
      items: [{ id: "i", sections: [{ id: "s", kind: "text", text, render: (width) => markdown.rows(width) }] }],
    },
  });
  using frame = createFrame({ width: 5, height: 3 }, () => view);
  assertEquals(
    [view.rows.at({ column: 0, row: 1 }), view.rows.at({ column: 0, row: 1 }, "cell", "after")],
    [at("i", "s", 1), at("i", "s", 3)],
  );
  void frame;
});

test("the same document or selection gives no change, and compare checks its offsets", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "abc"])) });
  using frame = createFrame({ width: 5, height: 1 }, () => view);
  view.selection = { anchor: at("i", "s", 0), head: at("i", "s", 2) };
  const revision = view.revision;
  view.setDocument(view.document);
  view.selection = { anchor: at("i", "s", 0), head: at("i", "s", 2) };
  assertEquals(view.revision, revision);
  assertThrows(() => view.compare(at("i", "s", 9), at("i", "s", 0)));
  void frame;
});

test("the selection has a default look that a plugin changes", () => {
  const view = new TextView({ document: document("d", item("i", ["s", "hello"])) });
  using frame = createFrame({ width: 8, height: 1 }, () => view);
  view.selection = { anchor: at("i", "s", 0), head: at("i", "s", 2) };
  const before = frame.draw().cells[0];
  // The default look marks the selected cell and leaves the next cell plain.
  assertEquals([before?.[1]?.style.bg !== undefined, before?.[2]?.style], [true, {}]);
  frame.surface("theme").tui.styles.add({ "textView.selection": { fg: 1, bg: null } });
  const cells = frame.draw().cells[0];
  assertEquals([cells?.[1]?.style, cells?.[2]?.style], [{ fg: 1 }, {}]);
});
