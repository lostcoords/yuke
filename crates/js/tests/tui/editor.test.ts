// The text editor of `yuke:tui`: whole graphemes and spans, its states and changes, its coordinates, its keys, and its
// frames.

import { createFrame, equal, test, throws } from "yuke:test";
import { type EditorChange, type EditorState, TextEditor, type View } from "yuke:tui";

/** A root view that shows `editor` at `width` by `height` cells from (1, 1), and gives it the first focus. */
function root(editor: View, width: number, height: number): View {
  return {
    draw() {},
    initialFocus: editor,
    layout: () => [{ view: editor, rect: { column: 1, row: 1, width, height } }],
  };
}

/** The text of a frame row from `from` to `to`. */
function row(cells: readonly { readonly text: string }[] | undefined, from = 0, to?: number): string {
  return (cells ?? [])
    .slice(from, to)
    .map((cell) => cell.text)
    .join("");
}

function state(text: string, caret = text.length, spans: EditorState["spans"] = []): EditorState {
  return { text, selection: { anchor: caret, head: caret }, spans };
}

test("an edit inside a grapheme or a span takes the whole of it", () => {
  // The astronaut is 5 UTF-16 units: a woman, a zero-width joiner, and a laptop.
  const editor = new TextEditor({ state: state("A👩‍💻B") });
  const changes: EditorChange[] = [];
  editor.extend(new AbortController().signal).onChange((change) => changes.push(change));
  editor.replace(2, 3, "");
  equal([editor.state.text, editor.caret], ["AB", 1]);
  equal(changes[0]?.changes, [{ from: 1, to: 6, text: "", spans: [] }]);
  // A caret inside a grapheme goes to its nearest edge.
  const second = new TextEditor({ state: state("A👩‍💻B") });
  second.caret = 3;
  equal(second.caret, 1);
  const pasted = new TextEditor({ state: state("abcdef", 6, [{ from: 1, to: 5, kind: "paste", label: "[4 chars]" }]) });
  pasted.replace(2, 3, "");
  equal([pasted.state.text, pasted.state.spans], ["af", []]);
  // An insertion in a span goes to its nearer edge, and a tie goes after it.
  const tie = new TextEditor({ state: state("abcdef", 6, [{ from: 1, to: 5, kind: "paste", label: "[4 chars]" }]) });
  tie.replace(3, 3, "x");
  equal([tie.state.text, tie.state.spans[0]?.from, tie.caret], ["abcdexf", 1, 6]);
});

test("a restore brings back an image with its media and a change keeps its states", () => {
  const media = { blob: { digest: "abc", len: 3 }, mime: "image/png" };
  const editor = new TextEditor({
    state: state("x￼y", 3, [{ from: 1, to: 2, kind: "image", label: "[image 1]", media }]),
  });
  const saved = editor.state;
  const changes: EditorChange[] = [];
  editor.extend(new AbortController().signal).onChange((change) => changes.push(change));
  editor.caret = 2;
  editor.key({
    type: "key",
    code: "backspace",
    character: "",
    shifted: "",
    baseLayout: "",
    text: "",
    modifiers: { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false },
  });
  equal([editor.state.text, editor.state.spans], ["xy", []]);
  editor.restore(saved);
  equal(editor.state, {
    text: "x￼y",
    selection: { anchor: 3, head: 3 },
    spans: [
      {
        from: 1,
        to: 2,
        kind: "image",
        label: "[image 1]",
        media: { blob: { digest: "abc", len: 3 }, mime: "image/png" },
      },
    ],
  });
  editor.reset(state("new"));
  equal(
    changes.map((change) => change.kind),
    ["selection", "edit", "restore", "reset"],
  );
  // A change holds frozen states, so a plugin can keep `before` for its undo.
  equal(
    [Object.isFrozen(changes[1]?.before), Object.isFrozen(changes[1]?.before.spans[0]), changes[1]?.before.text],
    [true, true, "x￼y"],
  );
  throws(() => editor.replace(0, 9, ""));
  throws(() => editor.reset(state("ab", 0, [{ from: 0, to: 1, kind: "image", label: "[image]", media }])));
});

test("logical lines and display rows give different moves on a wrapped line", () => {
  const editor = new TextEditor({ state: state("abcdefgh\nxy", 1) });
  using frame = createFrame({ width: 6, height: 4 }, () => root(editor, 4, 3));
  frame.draw();
  // Down a logical line goes to the next line; down a display row stays in the same line.
  const line = editor.lines.point(1);
  const display = editor.rows.point(1);
  equal(
    [line, display],
    [
      { column: 1, row: 0 },
      { column: 1, row: 0 },
    ],
  );
  equal(editor.lines.at({ column: 1, row: 1 }), 10);
  equal(editor.rows.at({ column: 1, row: 1 }), 5);
  equal([editor.lines.count, editor.rows.count, editor.rows.text(1), editor.lines.text(0)], [2, 3, "efgh", "abcdefgh"]);
  // The down key moves by display rows and keeps its column across a short row.
  frame.key("down");
  equal(editor.caret, 5);
  frame.key("down");
  equal(editor.caret, 10);
});

test("a frame shows the prompt, the text, a label, the selection, and the cursor with its shape", () => {
  const editor = new TextEditor({
    appearance: { prompt: "> " },
    state: {
      text: "hi there",
      selection: { anchor: 0, head: 2 },
      spans: [{ from: 3, to: 8, kind: "paste", label: "[p]" }],
    },
  });
  using frame = createFrame({ width: 12, height: 3 }, () => root(editor, 10, 2));
  const surface = frame.surface("vim");
  surface.tui.widgets.watch((mount) => {
    const extension = mount.widget.extend(mount.signal);
    extension.setAppearance({ cursorShape: "block" });
    return () => extension.dispose();
  });
  const cells = frame.draw().cells[1];
  equal(row(cells, 1, 11), "> hi [p]  ");
  // The selection reverses "hi"; the label takes the accent color of the dark palette.
  equal([cells?.[3]?.style, cells?.[6]?.style], [{ reverse: true }, { fg: "#a8cfa0" }]);
  equal(frame.frame.cursor, { column: 5, row: 1, shape: "block" });
  // The close of the surface ends the extension, so the cursor takes the shape of the terminal again.
  surface.close();
  equal(frame.draw().cursor, { column: 5, row: 1 });
});

test("the keys type, select, delete, add a line, and submit without a clear", () => {
  const submitted: string[] = [];
  const editor = new TextEditor({ submit: (draft) => submitted.push(draft.text) });
  using frame = createFrame({ width: 12, height: 3 }, () => root(editor, 10, 2));
  frame.key("h i");
  frame.key("shift+left");
  equal(editor.selection, { anchor: 2, head: 1 });
  frame.key("backspace");
  frame.key("o shift+enter k");
  equal(editor.state.text, "ho\nk");
  frame.key("enter");
  equal([submitted, editor.state.text], [["ho\nk"], "ho\nk"]);
  frame.key("home");
  equal(editor.caret, 3);
  frame.paste("x\ny");
  equal(editor.state.text, "ho\nx\nyk");
});

test("a one-line field writes line ends as spaces and passes a newline key on", () => {
  const field = new TextEditor({ multiline: false });
  using frame = createFrame({ width: 12, height: 3 }, () => root(field, 10, 1));
  frame.paste("a\nb\r\nc");
  equal(field.state.text, "a b  c");
  frame.key("ctrl+j enter");
  equal(field.state.text, "a b  c");
});

test("a full last row gives the caret a row of its own", () => {
  const editor = new TextEditor({ state: state("abcd") });
  using frame = createFrame({ width: 6, height: 4 }, () => root(editor, 4, 3));
  equal([editor.heightFor(4), editor.heightFor(5), editor.rows.point(4)], [2, 1, { column: 0, row: 1 }]);
  equal(frame.frame.cursor, { column: 1, row: 2 });
  // Down from the first row reaches the row of the caret after the full row, and Up goes back to the goal column.
  editor.caret = 1;
  frame.key("down");
  equal(editor.caret, 4);
  frame.key("up");
  equal(editor.caret, 1);
});

test("overlapping decorations merge per field and a whole-row decoration fills its rows", () => {
  const editor = new TextEditor({ state: state("abcd\nx") });
  using frame = createFrame({ width: 8, height: 3 }, () => root(editor, 6, 2));
  const first = editor.extend(new AbortController().signal);
  const second = editor.extend(new AbortController().signal);
  first.setDecorations([{ range: { anchor: 0, head: 3 }, style: { fg: 1 } }]);
  second.setDecorations([
    { range: { anchor: 2, head: 1 }, style: { bg: 2 } },
    { range: { anchor: 5, head: 6 }, style: { bg: 3 }, wholeRows: true },
  ]);
  const cells = frame.draw().cells;
  equal(
    [1, 2, 3, 4].map((column) => cells[1]?.[column]?.style),
    [{ fg: 1 }, { fg: 1, bg: 2 }, { fg: 1 }, {}],
  );
  // The whole-row decoration covers the row of "x" up to the edge of the editor.
  equal(
    [1, 2, 6].map((column) => cells[2]?.[column]?.style),
    [{ bg: 3 }, { bg: 3 }, { bg: 3 }],
  );
});

test("a press puts the caret, a drag selects, and the wheel scrolls", () => {
  const editor = new TextEditor({ state: state("one\ntwo\nthree", 0) });
  using frame = createFrame({ width: 8, height: 3 }, () => root(editor, 6, 2));
  const mouse = (column: number, row: number, action: "press" | "drag" | "release", button = "left" as const) =>
    frame.mouse({
      type: "mouse",
      column,
      row,
      button,
      action,
      modifiers: { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false },
    });
  mouse(2, 1, "press");
  mouse(3, 2, "drag");
  mouse(3, 2, "release");
  equal(editor.selection, { anchor: 1, head: 6 });
  frame.mouse({
    type: "mouse",
    column: 2,
    row: 1,
    button: "wheel_down",
    action: "press",
    modifiers: { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false },
  });
  equal(editor.visibleRows, { from: 1, to: 3 });
  equal(row(frame.frame.cells[1], 1, 4), "two");
});

test("an insertion that joins the next grapheme puts the caret after the whole grapheme", () => {
  // A lone combining acute accent joins the "e" before it into one grapheme.
  const editor = new TextEditor({ state: state("́", 0) });
  editor.replace(0, 0, "e");
  equal([editor.state.text, editor.caret], ["é", 2]);
});

test("an arrow steps over a span and up and down keep their column across a short row", () => {
  const editor = new TextEditor({
    state: state("abcd\nx\nabcdef", 0, [{ from: 1, to: 3, kind: "paste", label: "[p]" }]),
  });
  using frame = createFrame({ width: 10, height: 5 }, () => root(editor, 8, 4));
  frame.key("right right");
  equal(editor.caret, 3);
  frame.key("left");
  equal(editor.caret, 1);
  // The goal column counts display cells: "a[p]d" ends at cell 5, so the last line takes "abcde".
  frame.key("end down");
  equal(editor.caret, 6);
  frame.key("down");
  equal(editor.caret, 12);
});

test("the view follows the caret past the last shown row", () => {
  const editor = new TextEditor();
  using frame = createFrame({ width: 6, height: 2 }, () => root(editor, 4, 1));
  frame.key("a shift+enter b");
  equal([editor.visibleRows, row(frame.frame.cells[1], 1, 2)], [{ from: 1, to: 2 }, "b"]);
});

test("a whole-row decoration styles its rows from edge to edge and stops at a soft break", () => {
  const editor = new TextEditor({ state: state("abcdef") });
  using frame = createFrame({ width: 6, height: 3 }, () => root(editor, 4, 2));
  editor
    .extend(new AbortController().signal)
    .setDecorations([{ range: { anchor: 5, head: 6 }, style: { bg: 3 }, wholeRows: true }]);
  const cells = frame.draw().cells;
  // Offsets 5 to 6 ("f") are on the second row ("ef"): "e" before them takes the style, and "abcd" keeps its own.
  equal([cells[1]?.[1]?.style, cells[2]?.[1]?.style, cells[2]?.[4]?.style], [{}, { bg: 3 }, { bg: 3 }]);
});

test("reset and restore report one edit over the whole text", () => {
  const editor = new TextEditor({ state: state("old") });
  const changes: EditorChange[] = [];
  editor.extend(new AbortController().signal).onChange((change) => changes.push(change));
  editor.reset(state("new text"));
  editor.restore(state("old"));
  equal(
    changes.map((change) => change.changes),
    [[{ from: 0, to: 3, text: "new text", spans: [] }], [{ from: 0, to: 8, text: "old", spans: [] }]],
  );
});

test("the editor checks its appearance, its spans, and its media at the boundary", () => {
  const media = { blob: { digest: "abc", len: 3 }, mime: "image/png" };
  throws(() => new TextEditor({ appearance: { cursorShape: "beam" as "bar" } }));
  // The astronaut is one grapheme of 5 units, so a span that ends inside it splits it.
  throws(() => new TextEditor({ state: state("👩‍💻", 0, [{ from: 0, to: 2, kind: "paste", label: "[p]" }]) }));
  const image = (value: unknown) =>
    new TextEditor({
      state: state("￼", 0, [{ from: 0, to: 1, kind: "image", label: "[i]", media: value as typeof media }]),
    });
  throws(() => image({ mime: "image/png" }));
  throws(() => image({ mime: "image/png", blob: { digest: "abc" } }));
  throws(() => image({ mime: "image/png", blob: { len: 3 } }));
  equal(image(media).state.spans[0], { from: 0, to: 1, kind: "image", label: "[i]", media });
});

test("the scroll follows a new prompt and stays inside the text after a restore", () => {
  const editor = new TextEditor({ state: state("abcdefg") });
  using frame = createFrame({ width: 6, height: 2 }, () => root(editor, 4, 1));
  equal(editor.visibleRows, { from: 1, to: 2 });
  // The prompt leaves 2 cells for the text: "ab", "cd", "ef", "g" and the caret after "g".
  editor.extend(new AbortController().signal).setAppearance({ prompt: "> " });
  frame.draw();
  equal(editor.visibleRows, { from: 3, to: 4 });
  const tall = new TextEditor({ state: state("1\n2\n3\n4\n5\n6") });
  using second = createFrame({ width: 6, height: 3 }, () => root(tall, 4, 2));
  equal(tall.visibleRows, { from: 4, to: 6 });
  tall.restore(state("1\n2\n3"));
  second.draw();
  equal(tall.visibleRows, { from: 1, to: 3 });
});

test("a drag above the text selects to its start", () => {
  const editor = new TextEditor({ state: state("abc def", 4) });
  using frame = createFrame({ width: 10, height: 3 }, () => root(editor, 8, 1));
  const modifiers = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };
  frame.mouse({ type: "mouse", column: 5, row: 1, button: "left", action: "press", modifiers });
  frame.mouse({ type: "mouse", column: 5, row: 0, button: "left", action: "drag", modifiers });
  equal(editor.selection, { anchor: 4, head: 0 });
});
