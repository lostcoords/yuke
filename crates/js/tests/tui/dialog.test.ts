// `tui.dialog`: its head and footer rows, the order of the keys, the scroll of its body, and its close. `tui.select`: its answers.

import { createFrame, equal, type FrameTest, test } from "yuke:test";
import { type KeyEvent, Picker, strokeOf, TextView, type View } from "yuke:tui";
import { rows } from "./rows.ts";

/** A text view with the lines `count` lines. */
function lines(count: number): TextView {
  const text = Array.from({ length: count }, (_, index) => `line ${index}`).join("\n");
  return new TextView({ document: { id: "d", items: [{ id: "i", sections: [{ id: "s", kind: "text", text }] }] } });
}

/** A focusable body that takes the key `taken` and draws `text`. */
function body(text: string, taken: string): View {
  return {
    focusable: true,
    draw: (canvas) => canvas.text(0, 0, text),
    onKey: (event: KeyEvent) => strokeOf(event) === taken,
  };
}

const shows = (frame: FrameTest, text: string) => rows(frame.frame).some((line) => line.includes(text));

test("a dialog shows its title, its body, and the keys that work now", () => {
  using frame = createFrame({ width: 60, height: 10 });
  const tui = frame.surface("test").tui;
  let ready = false;
  const runs: string[] = [];
  tui.dialog({
    title: () => "Plugins",
    body: body("the body", "x"),
    rows: 6,
    keys: [
      { key: "enter", label: "apply", when: () => ready, run: () => runs.push("enter") },
      { key: "u", label: "update", run: () => runs.push("u") },
    ],
  });
  frame.draw();
  const before = rows(frame.frame);
  frame.key("enter");
  ready = true;
  frame.key("enter");
  frame.key("u");
  frame.draw();

  equal(
    [before.at(-6)?.trim(), before.at(-5)?.trim(), before.at(-1)?.trim()],
    ["Plugins", "the body", "u: update · esc: close"],
  );
  equal(shows(frame, "enter: apply · u: update · esc: close"), true);
  equal(runs, ["enter", "u"]);
});

test("the body takes a key first, and the dialog takes what the body leaves", () => {
  using frame = createFrame({ width: 60, height: 10 });
  const runs: string[] = [];
  frame.surface("test").tui.dialog({
    body: body("the body", "x"),
    keys: [
      { key: "x", label: "taken by the body", run: () => runs.push("x") },
      { key: "y", label: "left by the body", run: () => runs.push("y") },
    ],
  });

  frame.key("x");
  frame.key("y");

  equal(runs, ["y"]);
});

test("the arrow and page keys scroll a body that scrolls", () => {
  using frame = createFrame({ width: 60, height: 12 });
  frame.surface("test").tui.dialog({ body: lines(40), rows: 8 });
  frame.draw();
  const top = shows(frame, "line 0");
  frame.key("page_down");
  frame.draw();
  const paged = [shows(frame, "line 0"), shows(frame, "line 6")];
  frame.key("up");
  frame.draw();

  equal([top, ...paged, shows(frame, "line 5")], [true, false, true, true]);
});

test("the abort of its signal closes the dialog, and esc closes it too", () => {
  using frame = createFrame({ width: 60, height: 10 });
  const tui = frame.surface("test").tui;
  const controller = new AbortController();
  const first = tui.dialog({ body: body("first", ""), signal: controller.signal });
  controller.abort();
  const late = tui.dialog({ body: body("late", ""), signal: controller.signal });
  const second = tui.dialog({ body: body("second", "") });
  frame.key("esc");
  frame.draw();

  equal(
    [first.signal.aborted, late.signal.aborted, second.signal.aborted, shows(frame, "second")],
    [true, true, true, false],
  );
});

test("a select gives the chosen item, and it shows the title", async () => {
  using frame = createFrame({ width: 60, height: 10 });
  const items = [{ name: "first" }, { name: "second" }];
  const answer = frame.surface("test").tui.select({ title: "Pick one", items, label: (item) => item.name });
  frame.draw();
  const shown = shows(frame, "Pick one");
  frame.key("down");
  frame.key("enter");

  equal(shown, true);
  equal(await answer, items[1]);
  frame.draw();
  equal(shows(frame, "Pick one"), false);
});

test("a select of two items with one label gives the chosen one", async () => {
  using frame = createFrame({ width: 60, height: 10 });
  const items = [
    { name: "twin", at: 1 },
    { name: "twin", at: 2 },
  ];
  const answer = frame.surface("test").tui.select({ items, label: (item) => item.name });
  frame.draw();
  frame.key("down");
  frame.key("enter");

  equal(await answer, { name: "twin", at: 2 });
});

test("a select gives undefined for esc, an abort, and a stop, and a call after the stop throws", async () => {
  using frame = createFrame({ width: 60, height: 10 });
  const options = { items: [{ name: "only" }], label: (item: { name: string }) => item.name };
  const surface = frame.surface("test");
  const tui = surface.tui;

  const cancelled = tui.select(options);
  frame.key("esc");
  equal(await cancelled, undefined);

  const controller = new AbortController();
  const aborted = tui.select({ ...options, signal: controller.signal });
  controller.abort();
  equal(await aborted, undefined);
  equal(await tui.select({ ...options, signal: controller.signal }), undefined);

  const stopped = tui.select(options);
  surface.close();
  equal(await stopped, undefined);

  let thrown = false;
  try {
    tui.select(options);
  } catch {
    thrown = true;
  }
  equal(thrown, true);
});

test("two keys in a row with one label share one footer entry, and a key on esc replaces the close", () => {
  using frame = createFrame({ width: 60, height: 10 });
  const runs: string[] = [];
  frame.surface("test").tui.dialog({
    body: body("the body", ""),
    rows: 4,
    keys: [
      { key: "enter", label: "go", run: () => runs.push("enter") },
      { key: "ctrl+t", label: "go", run: () => runs.push("ctrl+t") },
      { key: "esc", label: "stay", run: () => runs.push("esc") },
    ],
  });
  frame.draw();

  equal(shows(frame, "enter/ctrl+t: go · esc: stay"), true);
  equal(shows(frame, "esc: close"), false);
  frame.key("esc");
  frame.key("ctrl+t");
  frame.draw();
  equal([runs, shows(frame, "the body")], [["esc", "ctrl+t"], true]);
});

test("a guard decides on a quit, and its disposer ends it", () => {
  using frame = createFrame({ width: 60, height: 10 });
  const tui = frame.surface("test").tui;
  tui.keys.add("ctrl+q", "core:quit");
  let held: ((text?: string) => void) | undefined;
  const end = tui.setQuitGuard((quit) => {
    held = quit;
  });

  frame.key("ctrl+q");
  const asked = frame.quits.length;
  held?.("bye");
  const after = frame.quits.length;
  end();
  frame.key("ctrl+q");

  equal([asked, after, frame.quits], [0, 1, ["bye", undefined]]);
});

test("a key of more than one stroke throws", () => {
  using frame = createFrame({ width: 60, height: 10 });
  let thrown = "";
  try {
    frame.surface("test").tui.dialog({ body: body("b", ""), keys: [{ key: "ctrl+k x", label: "two", run: () => {} }] });
  } catch (error) {
    thrown = String(error);
  }

  equal(thrown, "TypeError: dialog: the key 'ctrl+k x' is not one stroke");
});

test("a picker body gets the focus of its search field, so typed text filters it", () => {
  using frame = createFrame({ width: 60, height: 10 });
  const picker = new Picker<{ readonly name: string }>({
    items: [{ name: "clock" }, { name: "tools" }],
    id: (item) => item.name,
    label: (item) => item.name,
    onChoose: () => {},
    onCancel: () => {},
  });
  frame.surface("test").tui.dialog({ body: picker });

  frame.paste("too");
  frame.key("l");
  frame.draw();

  equal([picker.query, picker.selected?.name, shows(frame, "clock")], ["tool", "tools", false]);
});

test("the title and the keys of a dialog have a default look that a plugin changes", () => {
  using frame = createFrame({ width: 30, height: 6 });
  const tui = frame.surface("test").tui;
  tui.dialog({ title: () => "Plugins", body: body("the body", "x"), rows: 4 });
  const looks = () => {
    const cells = frame.draw().cells;
    const title = rows(frame.frame).findIndex((line) => line.includes("Plugins"));
    const keys = rows(frame.frame).findIndex((line) => line.includes("esc: close"));
    return [cells[title]?.[1]?.style, cells[keys]?.[1]?.style];
  };
  const before = looks();
  tui.styles.add({ "dialog.title": { fg: 1, dim: null }, "dialog.keys": { fg: 2, dim: null } });
  equal(
    [before, looks()],
    [
      [{ dim: true }, { dim: true }],
      [{ fg: 1 }, { fg: 2 }],
    ],
  );
});
