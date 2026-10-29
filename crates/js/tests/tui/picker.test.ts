// The fuzzy match and the picker of `yuke:tui`: ranges, ranking, selection by key, and the keys.

import { createFrame, equal, test } from "yuke:test";
import { fuzzyMatch, Picker, type PickerOptions } from "yuke:tui";

interface Command {
  readonly name: string;
}

/** A picker of `names` that logs its actions in `log`. */
function picker(
  names: readonly string[],
  log: string[],
  options: Partial<PickerOptions<Command>> = {},
): Picker<Command> {
  return new Picker<Command>({
    items: names.map((name) => ({ name })),
    key: (command) => command.name,
    label: (command) => command.name,
    choose: (command) => log.push(`choose ${command.name}`),
    cancel: () => log.push("cancel"),
    ...options,
  });
}

/** The text of each row of a frame. */
function screen(cells: readonly (readonly { readonly text: string }[])[]): string[] {
  return cells.map((row) =>
    row
      .map((cell) => cell.text)
      .join("")
      .trimEnd(),
  );
}

test("a fuzzy match ignores case, covers whole graphemes, and prefers consecutive letters and word starts", () => {
  equal(
    [
      fuzzyMatch("e", "AéB")?.ranges,
      fuzzyMatch("💻", "A👩‍💻B")?.ranges,
      fuzzyMatch("FB", "foobar")?.ranges,
      fuzzyMatch("ab", "a_b ab")?.ranges,
      fuzzyMatch("zz", "foobar"),
      fuzzyMatch("", "foobar"),
    ],
    [
      [{ from: 1, to: 3 }],
      [{ from: 1, to: 6 }],
      [
        { from: 0, to: 1 },
        { from: 3, to: 4 },
      ],
      [{ from: 4, to: 6 }],
      undefined,
      { score: 0, ranges: [] },
    ],
  );
  const score = (query: string, text: string): number => fuzzyMatch(query, text)?.score ?? Number.NaN;
  // A letter after a separator, and a letter after a gap at a word start, score higher than the same letter in a word.
  equal(
    [
      score("sp", "split pane") > score("sp", "dispose"),
      score("b", "a_b") > score("b", "ab"),
      score("ab", "a_b") > score("ab", "axb"),
    ],
    [true, true, true],
  );
  equal(fuzzyMatch("fb", "FooBar")?.ranges, [
    { from: 0, to: 1 },
    { from: 3, to: 4 },
  ]);
  // A text over 1024 points ranks last, also when it equals the query.
  equal(fuzzyMatch("a".repeat(1025), "a".repeat(1025))?.score, Number.NEGATIVE_INFINITY);
});

test("a caller rank stays in its order, and the default rank puts the best match first", () => {
  const log: string[] = [];
  const reversed = picker(["alpha", "beta", "gamma"], log, {
    rank: (_query, items) => items.toReversed().map((item) => ({ item })),
  });
  using frame = createFrame({ width: 10, height: 3 }, () => reversed);
  equal(screen(frame.frame.cells), ["", "gamma", "beta"]);
  const fuzzy = picker(["dispose", "split pane", "close"], log);
  using second = createFrame({ width: 12, height: 4 }, () => fuzzy);
  second.key("s p");
  equal(screen(second.frame.cells).slice(1), ["split pane", "dispose", ""]);
});

test("the selection follows its key and goes to the first result when its key leaves", () => {
  const log: string[] = [];
  const view = picker(["a", "b", "c"], log);
  using frame = createFrame({ width: 5, height: 4 }, () => view);
  view.move(1);
  const replacement = { name: "b" };
  view.setItems([{ name: "c" }, replacement, { name: "a" }]);
  const kept = view.selected;
  view.setItems([{ name: "c" }, { name: "a" }]);
  equal([kept === replacement, view.selected], [true, { name: "c" }]);
  void frame;
});

test("Esc cancels, Up and Down stop at the ends, and an empty result chooses nothing", () => {
  const log: string[] = [];
  const view = picker(["open", "close"], log);
  using frame = createFrame({ width: 10, height: 3 }, () => view);
  frame.key("up");
  const top = view.selected;
  frame.key("down down");
  const bottom = view.selected;
  frame.key("esc");
  frame.key("z z enter");
  equal(
    [top, bottom, log, view.selected, view.choose()],
    [{ name: "open" }, { name: "close" }, ["cancel"], undefined, false],
  );
});

test("the selected row shows reversed and its matched letters marked, and a click chooses a row", () => {
  const log: string[] = [];
  const view = picker(["alpha", "beta"], log);
  using frame = createFrame({ width: 6, height: 3 }, () => view);
  frame.key("a");
  const cells = frame.frame.cells;
  equal(
    [cells[1]?.[0]?.style, cells[1]?.[1]?.style, cells[1]?.[5]?.style],
    [{ fg: "#a8cfa0", bold: true, reverse: true }, { reverse: true }, { reverse: true }],
  );
  // A move gives the old row its plain style back.
  frame.key("down");
  equal([frame.frame.cells[1]?.[1]?.style, frame.frame.cells[2]?.[1]?.style], [{}, { reverse: true }]);
  const modifiers = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };
  frame.mouse({ type: "mouse", column: 1, row: 2, button: "left", action: "press", modifiers });
  equal(log, ["choose beta"]);
});

test("a selected row pads by cells, and a picker with its field takes the focus", () => {
  const log: string[] = [];
  // "e" with a combining accent is one cell in two UTF-16 units.
  const view = picker(["e\u0301"], log);
  using frame = createFrame({ width: 3, height: 2 }, () => ({ draw() {} }));
  const surface = frame.surface("demo");
  surface.tui.overlay(() => view);
  const cells = frame.draw().cells[1];
  equal(
    [cells?.[1]?.style, cells?.[2]?.style, surface.tui.focus(view), surface.tui.focused === view.input],
    [{ reverse: true }, { reverse: true }, true, true],
  );
});
