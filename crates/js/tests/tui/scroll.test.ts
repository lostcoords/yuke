// The scroll list of `yuke:tui`: the anchor across a prepend and a resize, the tail and the hint below, the older
// pages, the cache of rows, and the frames.

import { createFrame, equal, test } from "yuke:test";
import { ScrollList, type TextRow } from "yuke:tui";
import { fakeTerminal, newCore } from "./terminal.ts";

/** An item of text that wraps at the width of the list, one row for each `width` characters. */
interface Item {
  readonly key: string;
  readonly text: string;
}

function item(key: string, text: string): Item {
  return { key, text };
}

/** A list of `items` that counts its renders in `renders`. */
function list(
  items: readonly Item[],
  options: { followTail?: boolean; requestOlder?: () => void | Promise<void> } = {},
) {
  const renders: string[] = [];
  const scroll = new ScrollList<Item>({
    items,
    key: (entry) => entry.key,
    render: (entry, width): TextRow[] => {
      renders.push(entry.key);
      const rows: TextRow[] = [];
      for (let at = 0; at < entry.text.length; at += width) {
        rows.push({ segments: [{ text: entry.text.slice(at, at + width) }], join: "" });
      }
      return rows;
    },
    ...options,
  });
  return { scroll, renders };
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

const MODIFIERS = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };

test("a prepend keeps the top item at its row", () => {
  const { scroll } = list([item("a", "a0a1a2"), item("b", "b0b1b2"), item("c", "c0c1c2")]);
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  scroll.scrollTo(4);
  equal(screen(frame.draw().cells), ["b1", "b2"]);
  scroll.setItems([item("z", "z0z1z2z3z4"), ...scroll.items]);
  equal([screen(frame.draw().cells), scroll.state.top], [["b1", "b2"], 9]);
});

test("the anchor names the top item and row, and scrollToItem puts that row at the top", () => {
  const { scroll } = list([item("a", "a0a1a2"), item("b", "b0b1b2"), item("c", "c0c1c2")]);
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  scroll.scrollTo(4);
  frame.draw();
  equal(scroll.state.anchor, { key: "b", row: 1 });
  // The rows below end the list, so the top stops at the last full view.
  equal(
    [scroll.scrollToItem("a", 1), scroll.scrollToItem("c", 2), scroll.state.anchor],
    [true, true, { key: "c", row: 1 }],
  );
  equal([scroll.scrollToItem("b", 3), scroll.scrollToItem("x"), scroll.state.top], [false, false, 7]);
  equal(scroll.scrollToItem("a", 1), true);
  equal(screen(frame.draw().cells), ["a1", "a2"]);
});

test("a top at the first row of an item keeps that item after a prepend", () => {
  const { scroll } = list([item("a", "a0a1a2"), item("b", "b0b1b2")]);
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  scroll.scrollTo(3);
  scroll.setItems([item("z", "z0"), ...scroll.items]);
  equal(screen(frame.draw().cells), ["b0", "b1"]);
});

test("a resize keeps the row offset of the top item", () => {
  const { scroll } = list([item("a", "aaaaaaaa"), item("b", "bbbbcccc"), item("c", "dddddddd")]);
  using frame = createFrame({ width: 4, height: 2 }, () => scroll);
  scroll.scrollTo(3);
  equal(screen(frame.draw().cells), ["cccc", "dddd"]);
  // At width 2, "a" takes 4 rows, so row 1 of "b" is row 5.
  frame.resize({ width: 2, height: 2 });
  equal([scroll.state.top, screen(frame.frame.cells)], [5, ["bb", "cc"]]);
});

test("a removed top item gives its place to the next item", () => {
  const { scroll } = list([item("a", "a0a1"), item("b", "b0b1"), item("c", "c0c1")]);
  using frame = createFrame({ width: 2, height: 1 }, () => scroll);
  scroll.scrollTo(3);
  scroll.setItems([scroll.items[0] as Item, scroll.items[2] as Item]);
  equal(screen(frame.draw().cells), ["c0"]);
});

test("output below a view that does not follow sets the hint, and the bottom follows again", () => {
  const { scroll } = list([item("a", "a0a1"), item("b", "b0b1")], { followTail: true });
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  equal([scroll.state.top, scroll.state.following], [2, true]);
  scroll.scrollBy(-1);
  scroll.setItems([...scroll.items, item("c", "c0")]);
  equal([scroll.state.top, scroll.state.following, scroll.state.changedBelow], [1, false, true]);
  scroll.followTail();
  equal([scroll.state.following, scroll.state.changedBelow], [true, false]);
  scroll.setItems([...scroll.items, item("d", "d0")]);
  equal(screen(frame.draw().cells), ["c0", "d0"]);
});

test("a prepend and a resize set no hint, and a same-height change below sets it", () => {
  const { scroll } = list([item("a", "a0a1"), item("b", "b0b1"), item("c", "c0c1")]);
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  scroll.scrollTo(1);
  scroll.setItems([item("z", "z0"), ...scroll.items]);
  frame.resize({ width: 4, height: 2 });
  equal(scroll.state.changedBelow, false);
  const items = scroll.items;
  scroll.setItems([...items.slice(0, -1), item("c", "x0x1")]);
  equal(scroll.state.changedBelow, true);
});

test("the list renders only new item objects until the width changes", () => {
  const { scroll, renders } = list([item("a", "a0"), item("b", "b0"), item("c", "c0")]);
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  equal(renders, ["a", "b", "c"]);
  frame.draw();
  scroll.scrollBy(1);
  frame.draw();
  scroll.setItems([scroll.items[0] as Item, item("b", "b1"), scroll.items[2] as Item]);
  frame.draw();
  equal(renders, ["a", "b", "c", "b"]);
  frame.resize({ width: 3, height: 2 });
  equal(renders.slice(4), ["a", "b", "c"]);
});

test("the wheel scrolls the list", () => {
  const { scroll } = list([item("a", "a0a1a2a3a4a5")]);
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  frame.mouse({ type: "mouse", column: 0, row: 0, button: "wheel_down", action: "press", modifiers: MODIFIERS });
  equal(screen(frame.frame.cells), ["a3", "a4"]);
});

test("older pages come once for each top visit and never overlap", async () => {
  const calls: number[] = [];
  let finish: () => void = () => {};
  const older = (): Promise<void> => {
    calls.push(calls.length);
    return new Promise((resolve) => {
      finish = resolve;
    });
  };
  const { scroll } = list([item("a", "a0a1a2a3")], { requestOlder: older });
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  // The first frame alone starts the first load.
  await Promise.resolve();
  equal(calls, [0]);
  // A second visit while the first load runs waits for its end, and then the list asks again once.
  scroll.scrollBy(2);
  scroll.scrollBy(-2);
  frame.draw();
  await Promise.resolve();
  equal(calls, [0]);
  finish();
  await new Promise((resolve) => setTimeout(resolve, 0));
  equal(calls, [0, 1]);
  // A load that ends with no new items asks for nothing more.
  finish();
  await new Promise((resolve) => setTimeout(resolve, 0));
  frame.draw();
  await new Promise((resolve) => setTimeout(resolve, 0));
  equal(calls, [0, 1]);
});

test("a change of a placed list by code asks for a frame", () => {
  const terminal = fakeTerminal();
  const core = newCore(terminal);
  const { scroll } = list([item("a", "a0a1a2a3")]);
  core.scene.setRoot("chat", () => scroll);
  terminal.screen(core);
  const asked = terminal.requests();
  scroll.scrollBy(1);
  scroll.setItems([item("b", "b0")]);
  equal(terminal.requests() - asked, 2);
});

test("items with no rows take no rows, and a render that throws changes nothing", () => {
  const { scroll } = list([item("a", "a0"), item("e", ""), item("b", "b0")]);
  using frame = createFrame({ width: 2, height: 2 }, () => scroll);
  equal([screen(frame.draw().cells), scroll.state.total], [["a0", "b0"], 2]);
  const broken = new ScrollList<Item>({
    items: [item("a", "a0")],
    key: (entry) => entry.key,
    render: (entry) => {
      if (entry.key === "bad") throw new Error("bad render");
      return [{ segments: [{ text: entry.text }], join: "" }];
    },
  });
  using second = createFrame({ width: 2, height: 1 }, () => broken);
  const before = broken.items;
  let thrown = false;
  try {
    broken.setItems([...before, item("bad", "x")]);
  } catch {
    thrown = true;
  }
  equal(broken.items, before);
  broken.setItems([...before, item("c", "c0")]);
  equal([thrown, broken.items.map((entry) => entry.key), broken.state.total], [true, ["a", "c"], 2]);
  void second;
});

test("a listener gets each later state until its signal aborts or its disposer runs", () => {
  const { scroll } = list([item("a", "a0a1a2a3")]);
  using frame = createFrame({ width: 2, height: 1 }, () => scroll);
  const controller = new AbortController();
  const tops: number[] = [];
  const kept: number[] = [];
  scroll.onChange((state) => tops.push(state.top), controller.signal);
  const dispose = scroll.onChange((state) => kept.push(state.top), new AbortController().signal);
  scroll.scrollTo(1);
  controller.abort();
  dispose();
  scroll.scrollTo(2);
  equal([tops, kept], [[1], [1]]);
  void frame;
});
