// The fuzzy match and the picker of `yuke:tui`: ranges, ranking, selection by key, and the keys.

import { assert, assertEquals, createFrame, test } from "yuke:test";
import { fuzzyMatch, Picker, type PickerOptions } from "yuke:tui";
import { rows } from "./rows.ts";

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
    id: (command) => command.name,
    label: (command) => command.name,
    onChoose: (command) => log.push(`choose ${command.name}`),
    onCancel: () => log.push("cancel"),
    ...options,
  });
}

test("a fuzzy match ignores case, covers whole graphemes, and prefers consecutive letters and word starts", () => {
  assertEquals(
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
  assertEquals(
    [
      score("sp", "split pane") > score("sp", "dispose"),
      score("b", "a_b") > score("b", "ab"),
      score("ab", "a_b") > score("ab", "axb"),
    ],
    [true, true, true],
  );
  assertEquals(fuzzyMatch("fb", "FooBar")?.ranges, [
    { from: 0, to: 1 },
    { from: 3, to: 4 },
  ]);
});

test("a caller rank stays in its order, and the default rank puts the best match first", () => {
  const log: string[] = [];
  const reversed = picker(["alpha", "beta", "gamma"], log, {
    rank: (_query, items) => items.toReversed().map((item) => ({ item })),
  });
  using frame = createFrame({ width: 10, height: 3 }, () => reversed);
  assertEquals(rows(frame.frame), ["", "gamma", "beta"]);
  const fuzzy = picker(["dispose", "split pane", "close"], log);
  using second = createFrame({ width: 12, height: 4 }, () => fuzzy);
  second.key("s p");
  assertEquals(rows(second.frame).slice(1), ["split pane", "dispose", ""]);
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
  assertEquals([kept === replacement, view.selected], [true, { name: "c" }]);
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
  assertEquals(
    [top, bottom, log, view.selected, view.choose()],
    [{ name: "open" }, { name: "close" }, ["cancel"], undefined, false],
  );
});

test("the selected row has its look and its matched letters marked, and a click chooses a row", () => {
  const log: string[] = [];
  const view = picker(["alpha", "beta"], log);
  using frame = createFrame({ width: 6, height: 3 }, () => view);
  frame.key("a");
  const cells = frame.frame.cells;
  // The matched letter is bold, and the band of the selected row covers the whole row.
  const band = cells[1]?.[1]?.style.bg;
  assert(band !== undefined);
  assertEquals([cells[1]?.[0]?.style.bold, cells[1]?.[0]?.style.bg, cells[1]?.[5]?.style.bg], [true, band, band]);
  // A move gives the old row its plain style back.
  frame.key("down");
  assertEquals([frame.frame.cells[1]?.[1]?.style, frame.frame.cells[2]?.[1]?.style.bg], [{}, band]);
  const modifiers = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };
  frame.mouse({ type: "mouse", column: 1, row: 2, button: "left", action: "press", modifiers });
  assertEquals(log, ["choose beta"]);
});

test("a selected row pads by cells, and a picker with its field takes the focus", () => {
  const log: string[] = [];
  // "e" with a combining accent is one cell in two UTF-16 units.
  const view = picker(["e\u0301"], log);
  using frame = createFrame({ width: 3, height: 2 }, () => ({ draw() {} }));
  const surface = frame.surface("demo");
  surface.tui.overlay(() => view);
  const cells = frame.draw().cells[1];
  // The pad cell has the band of the row.
  assert(cells?.[1]?.style.bg !== undefined);
  assertEquals(
    [cells?.[2]?.style.bg, surface.tui.focus(view), surface.tui.focused === view.input],
    [cells?.[1]?.style.bg, true, true],
  );
});

test("a new query selects its best result, and new items keep the selection", () => {
  const log: string[] = [];
  const list = picker(["save", "send", "search", "sessions"], log);
  list.query = "s";
  list.move(2);
  const moved = list.selected?.name;
  // "search" still matches "se", but "send" is the best result.
  list.query = "se";
  const typed = list.selected?.name;
  list.move(1);
  const before = list.selected?.name;
  list.setItems([{ name: "save" }, { name: "send" }, { name: "search" }, { name: "sessions" }, { name: "set" }]);
  assertEquals([moved, typed, before, list.selected?.name], ["search", "send", "search", "search"]);
});

test("the rows of a picker have a default look that a plugin changes", () => {
  const view = picker(["alpha", "beta"], [], { detail: () => "x" });
  using frame = createFrame({ width: 12, height: 3 }, () => view);
  frame.key("a");
  const looks = () => {
    const cells = frame.draw().cells;
    return [cells[1]?.[0], cells[1]?.[1], cells[1]?.[7], cells[1]?.[11], cells[2]?.[6]].map((cell) => cell?.style);
  };
  const before = looks();
  frame.surface("theme").tui.styles.add({
    "picker.match": { fg: 1, bold: null },
    "picker.detail": { fg: 3, dim: null },
    "picker.selected": { bg: 2, fg: null },
  });
  const after = looks();
  assertEquals(
    [before.map((style, at) => JSON.stringify(style) !== JSON.stringify(after[at])), after],
    [
      [true, true, true, true, true],
      [{ fg: 1, bg: 2 }, { bg: 2 }, { bg: 2 }, { bg: 2 }, { fg: 3 }],
    ],
  );
});

test("onSelectionChange tells each change of the selection, and a query without a result gives nothing", () => {
  const seen: (string | undefined)[] = [];
  const view = picker(["alpha", "beta"], [], { onSelectionChange: (item) => seen.push(item?.name) });
  using frame = createFrame({ width: 10, height: 3 }, () => view);
  const first = [...seen];
  frame.key("down");
  frame.key("down");
  frame.key("z");
  assertEquals([first, seen], [["alpha"], ["alpha", "beta", undefined]]);
});
