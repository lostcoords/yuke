// The dialog of `tui.dialog`: its head and footer rows, the order of the keys, the scroll of its body, and its close.

import { createFrame, equal, type FrameTest, test } from "yuke:test";
import { type KeyEvent, Picker, strokeOf, TextView, type View } from "yuke:tui";
import { rows } from "./chat.ts";

/** A text view with the lines `count` lines. */
function lines(count: number): TextView {
  const text = Array.from({ length: count }, (_, index) => `line ${index}`).join("\n");
  return new TextView({ document: { key: "d", items: [{ key: "i", sections: [{ key: "s", kind: "text", text }] }] } });
}

/** A focusable body that takes the key `taken` and draws `text`. */
function body(text: string, taken: string): View {
  return {
    focusable: true,
    draw: (canvas) => canvas.text(0, 0, text),
    key: (event: KeyEvent) => strokeOf(event) === taken,
  };
}

const shows = (frame: FrameTest, text: string) => rows(frame).some((line) => line.includes(text));

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
  const before = rows(frame);
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
    key: (item) => item.name,
    label: (item) => item.name,
    choose: () => {},
    cancel: () => {},
  });
  frame.surface("test").tui.dialog({ body: picker });

  frame.paste("too");
  frame.key("l");
  frame.draw();

  equal([picker.query, picker.selected?.name, shows(frame, "clock")], ["tool", "tools", false]);
});
