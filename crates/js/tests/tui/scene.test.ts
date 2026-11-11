// The core of the terminal interface on a fake 20×6 driver: placement, clipping, input routing, focus, overlays, panes,
// the plugin surface and restore.

import { Core } from "yuke:internal/tui/core";
import { createSurface } from "yuke:internal/tui/surface";
import { assert, equal, test, throws } from "yuke:test";
import { type Cursor, type MouseEvent, type RestoreView, stack, type View } from "yuke:tui";
import { atoms, click, fakeTerminal, key, named } from "./terminal.ts";

test("a placed child draws in its rect and is cut to it", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const left: View = {
    draw: (canvas) => {
      canvas.text(0, 0, "abcdefgh");
      canvas.text(1, 1, "xyz");
      canvas.text(0, 2, "below");
      canvas.fill(0, 3, 4, 1);
    },
  };
  const right: View = {
    draw: (canvas) => {
      canvas.fill(0, 0, canvas.width, canvas.height);
      canvas.text(-2, 0, "ABCDE");
      canvas.region(1, 1, 2, 1).text(0, 0, "QRS");
      canvas.text(-1, 2, "中Z");
    },
  };
  core.scene.wrapRoot("test", () => ({
    layout: () => [
      { view: left, rect: { column: 0, row: 0, width: 4, height: 2 } },
      { view: right, rect: { column: 5, row: 0, width: 4, height: 3 } },
    ],
    draw: (canvas) => {
      canvas.text(0, 3, "parent");
    },
  }));
  // `abcdefgh` stops at the width 4 of its rect. `ABCDE` at column -2 loses `AB`. The region keeps `QR`.
  // The wide `中` crosses the left edge, so its visible cell stays blank before `Z`.
  equal(terminal.screen(core).slice(0, 4), ["abcd CDE", " xyz  QR", "      Z", "parent"]);
});

test("a stack gives sized children their cells and fill the rest", () => {
  const first: View = { draw() {} };
  const second: View = { draw() {} };
  const third: View = { draw() {} };
  const fourth: View = { draw() {} };
  const column = stack("column", [
    { view: first, size: 1 },
    { view: second, size: "fill" },
    { view: third, size: (size) => Math.floor(size.width / 10) },
    { view: fourth, size: "fill" },
  ]);
  const row = stack("row", [
    { view: first, size: 30 },
    { view: second, size: "fill" },
  ]);
  assert(column.layout !== undefined && row.layout !== undefined);
  // Column: 1 row, then 2 rows from the function, then 7 rows shared by the fills (3 and the rest, 4).
  equal(column.layout({ width: 20, height: 10 }), [
    { view: first, rect: { column: 0, row: 0, width: 20, height: 1 } },
    { view: second, rect: { column: 0, row: 1, width: 20, height: 3 } },
    { view: third, rect: { column: 0, row: 4, width: 20, height: 2 } },
    { view: fourth, rect: { column: 0, row: 6, width: 20, height: 4 } },
  ]);
  equal(row.layout({ width: 20, height: 3 }), [
    { view: first, rect: { column: 0, row: 0, width: 20, height: 3 } },
    { view: second, rect: { column: 20, row: 0, width: 0, height: 3 } },
  ]);
});

test("a key goes to the keymap first then up the focus path", () => {
  const core = new Core(fakeTerminal().driver);
  const log: string[] = [];
  core.commands.add({
    name: "test:bound",
    run: () => {
      log.push("command");
    },
  });
  core.keymap.bind("b", "test:bound");
  const child: View = {
    focusable: true,
    contexts: ["editor"],
    draw() {},
    key: (event) => {
      log.push(`child ${event.character}`);
      return event.character === "c";
    },
  };
  core.scene.wrapRoot("test", () => ({
    layout: () => [{ view: child, rect: { column: 0, row: 0, width: 5, height: 1 } }],
    draw() {},
    key: (event) => {
      log.push(`parent ${event.character}`);
      return true;
    },
  }));
  core.scene.layout();
  core.scene.focus(child);
  for (const character of ["b", "c", "p"]) core.event(key(character));
  equal(log, ["command", "child c", "child p", "parent p"]);
  equal(atoms(core), ["global", "root", "editor"]);
});

test("escape closes the top modal when nothing takes it", () => {
  const core = new Core(fakeTerminal().driver);
  const log: string[] = [];
  let query = "abc";
  const keeps = core.scene.overlay("test", (mount) => {
    mount.signal.addEventListener("abort", () => log.push("keeps closed"));
    return {
      draw() {},
      key: (event) => {
        if (event.code === "esc" && query !== "") {
          query = "";
          return true;
        }
        return false;
      },
    };
  });
  // The first Escape clears the query; the second closes the modal; a float stays open.
  core.event(named("esc"));
  equal(keeps.signal.aborted, false);
  core.event(named("esc"));
  core.scene.overlay("test", () => ({ draw() {} }), { modal: false });
  core.event(named("esc"));
  equal(keeps.signal.aborted, true);
  equal(log, ["keeps closed"]);
  equal(atoms(core), ["global", "root"]);
});

test("a modal takes all input below it and a float takes only what it handles", () => {
  const core = new Core(fakeTerminal().driver);
  const log: string[] = [];
  core.scene.wrapRoot("test", () => ({
    focusable: true,
    draw() {},
    key: () => {
      log.push("root key");
      return true;
    },
    mouse: (event) => {
      log.push(`root mouse ${event.action}`);
      return true;
    },
  }));
  const float = core.scene.overlay(
    "test",
    () => ({
      draw() {},
      key: (event) => {
        log.push("float key");
        return event.character === "f";
      },
      mouse: () => {
        log.push("float mouse");
        return true;
      },
    }),
    { modal: false, place: () => ({ column: 0, row: 0, width: 3, height: 1 }) },
  );
  core.event(key("f"));
  core.event(key("x"));
  core.event(click(1, 0));
  core.event(click(10, 3));
  equal(log.splice(0), ["float key", "float key", "root key", "float mouse", "root mouse press"]);
  float.close();
  core.scene.overlay("test", () => ({ draw() {}, key: () => false, mouse: () => false }));
  core.event(key("x"));
  core.event(click(10, 3));
  equal(log, ["root mouse cancel"]);
  equal(atoms(core), ["global", "overlay"]);
});

test("a press focuses and captures and a modal cancels the capture", () => {
  const core = new Core(fakeTerminal().driver);
  const log: [string, MouseEvent["action"], number, number][] = [];
  const record = (name: string) => (event: MouseEvent) => {
    log.push([name, event.action, event.column, event.row]);
    return true;
  };
  const a: View = { focusable: true, draw() {}, mouse: record("a") };
  const b: View = { focusable: true, draw() {}, mouse: record("b") };
  core.scene.wrapRoot("test", () => ({
    layout: () => [
      { view: a, rect: { column: 0, row: 0, width: 5, height: 2 } },
      { view: b, rect: { column: 10, row: 0, width: 5, height: 2 } },
    ],
    draw() {},
  }));
  core.event(click(11, 1));
  assert(core.scene.focused === b, "a press focuses b");
  core.event(click(2, 0, "press"));
  core.event(click(15, 4, "drag"));
  core.event(click(16, 5, "release"));
  core.event(click(1, 1, "press"));
  core.scene.overlay("test", () => ({ draw() {} }));
  core.event(click(3, 3, "release"));
  assert(core.scene.focused !== a, "the modal takes the focus from a");
  // The drag and the release reach `a` outside its rect; the modal sends `cancel` and takes the later release.
  equal(log, [
    ["b", "press", 1, 1],
    ["a", "press", 2, 0],
    ["a", "drag", 15, 4],
    ["a", "release", 16, 5],
    ["a", "press", 1, 1],
    ["a", "cancel", 1, 1],
  ]);
});

test("a press on a view without focusOnPress reaches it and focuses its parent, and tui.focus still focuses it", () => {
  const core = new Core(fakeTerminal().driver);
  const presses: string[] = [];
  const inner: View = {
    focusable: true,
    focusOnPress: false,
    draw() {},
    mouse: (event) => {
      presses.push(event.action);
      return true;
    },
  };
  const outer: View = {
    focusable: true,
    draw() {},
    layout: () => [{ view: inner, rect: { column: 0, row: 0, width: 5, height: 2 } }],
  };
  core.scene.wrapRoot("test", () => ({
    layout: () => [{ view: outer, rect: { column: 0, row: 0, width: 10, height: 4 } }],
    draw() {},
  }));
  core.event(click(1, 1));
  const pressed = core.scene.focused === outer;
  core.scene.focus(inner);
  equal([presses, pressed, core.scene.focused === inner], [["press"], true, true]);
});

test("the view of a pane takes a press without focusOnPress", () => {
  const core = new Core(fakeTerminal().driver);
  const panes = createSurface(core, "test", new AbortController().signal).panes;
  const view = (): View => ({ focusable: true, focusOnPress: false, draw() {} });
  // The split puts the pane right of the empty pane. A press on the empty pane takes the focus away first.
  const right = panes.split(view);
  core.event(click(1, 1));
  const away = core.scene.focused !== right.view;
  core.event(click(12, 1));
  equal([away, core.scene.focused === right.view], [true, true]);
});

test("panes split focus and close and the last close gives an empty pane without a default", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const pane = (name: string) => (): View => ({
    draw: (canvas, focused) => {
      canvas.text(0, 0, focused ? name.toUpperCase() : name);
    },
  });
  const panes = createSurface(core, "test", new AbortController().signal).panes;
  // The first split puts `a` right of the empty pane, the second puts `b` below `a`.
  const a = panes.split(pane("a"));
  const b = panes.split(pane("b"), { direction: "column" });
  equal(terminal.screen(core), [
    "          │a",
    "          │",
    "          │",
    "          │─────────",
    "          │B",
    "          │",
  ]);
  core.commands.run("core:focus-left");
  equal(terminal.screen(core)[0], "          │a");
  // A close goes back to `a`.
  core.commands.run("core:focus-right");
  b.close();
  equal(terminal.screen(core).slice(0, 3), ["          │A", "          │", "          │"]);
  assert(panes.active === a, "the close of b makes a active");
  // The close of `a` leaves the empty pane; without a default pane, a last close gives an empty pane.
  core.commands.run("core:close");
  core.commands.run("core:close");
  equal(terminal.screen(core)[0], "");
  equal(panes.active, undefined);
  equal(a.signal.aborted, true);
  // A plugin pane as the last pane gives way to an empty pane too.
  const c = panes.split(pane("c"));
  // Focus by direction reads the rects of the last layout, which each key runs first.
  terminal.screen(core);
  core.commands.run("core:focus-left");
  core.commands.run("core:close");
  equal(terminal.screen(core)[0], "C");
  c.close();
  equal(terminal.screen(core)[0], "");
});

test("a pane gets its inner focus back and focus changes reach the path", () => {
  const core = new Core(fakeTerminal().driver);
  const log: string[] = [];
  const composer: View = { focusable: true, draw() {}, focusChanged: (focused) => log.push(`composer ${focused}`) };
  const transcript: View = { focusable: true, draw() {} };
  const chat: View = {
    draw() {},
    focusChanged: (focused) => log.push(`chat ${focused}`),
    layout: (size) => [
      { view: transcript, rect: { column: 0, row: 0, width: size.width, height: size.height - 1 } },
      { view: composer, rect: { column: 0, row: size.height - 1, width: size.width, height: 1 } },
    ],
  };
  const panes = createSurface(core, "test", new AbortController().signal).panes;
  panes.split(() => chat);
  core.scene.layout();
  core.scene.focus(composer);
  core.commands.add({ name: "test:none", run() {} });
  core.keymap.bind("ctrl+k x", "test:none");
  core.commands.run("core:focus-left");
  core.scene.layout();
  core.event(key("k", { ctrl: true }));
  equal(core.keymap.pending(), "ctrl+k");
  core.commands.run("core:focus-right");
  core.scene.layout();
  // Back in the chat pane the composer has the focus again; the focus change drops the pending `ctrl+k`.
  assert(core.scene.focused === composer, "the composer has the focus again");
  equal(core.keymap.pending(), "");
  equal(log, ["chat true", "composer true", "chat false", "composer false", "chat true", "composer true"]);
});

test("a pane starts at its initial focus and each focus change names the view and the pane", () => {
  const core = new Core(fakeTerminal().driver);
  const tui = createSurface(core, "chat", new AbortController().signal);
  /** A chat pane: a transcript above a composer, and the composer takes the first focus. */
  const chat = (name: string) => {
    const composer: View = { focusable: true, draw() {} };
    const transcript: View = { focusable: true, draw() {} };
    const view: View = {
      draw() {},
      initialFocus: composer,
      layout: (size) => [
        { view: transcript, rect: { column: 0, row: 0, width: size.width, height: size.height - 1 } },
        { view: composer, rect: { column: 0, row: size.height - 1, width: size.width, height: 1 } },
      ],
    };
    names.set(composer, `${name} composer`).set(transcript, `${name} transcript`);
    return { view, composer, transcript };
  };
  const names = new Map<View | undefined, string>();
  const changes: string[] = [];
  tui.onFocusChange((change) => {
    const pane = change.pane === undefined ? "no pane" : change.pane === a ? "pane a" : "pane b";
    changes.push(`${names.get(change.previous) ?? "none"} -> ${names.get(change.current) ?? "?"} in ${pane}`);
  });
  const first = chat("a");
  const second = chat("b");
  const a = tui.panes.split(() => first.view);
  const b = tui.panes.split(() => second.view);
  core.draw();
  equal(tui.focused, second.composer);
  tui.focus(first.transcript);
  core.draw();
  b.focus();
  core.draw();
  const input: View = { focusable: true, draw() {} };
  names.set(input, "modal input");
  const modal = tui.overlay(() => ({
    draw() {},
    initialFocus: input,
    layout: () => [{ view: input, rect: { column: 0, row: 0, width: 5, height: 1 } }],
  }));
  core.draw();
  // A focus beneath the modal moves the active pane but not `tui.focused`, so it gives no change.
  tui.focus(first.composer);
  core.draw();
  modal.close();
  core.draw();
  // The modal input belongs to no pane; after the modal the focus is the one beneath it.
  equal(changes, [
    "none -> b composer in pane b",
    "b composer -> a transcript in pane a",
    "a transcript -> b composer in pane b",
    "b composer -> modal input in no pane",
    "modal input -> a composer in pane a",
  ]);
});

test("a timer runs once in time order, asks for a frame, and its disposer or the stop of its plugin cancels it", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const stop = new AbortController();
  const tui = createSurface(core, "timers", stop.signal);
  const ran: string[] = [];
  tui.after(100, () => ran.push("late"));
  const cancel = tui.after(100, () => ran.push("cancelled"));
  tui.after(50, () => ran.push("early"));
  cancel();
  const requests = terminal.requests();
  terminal.clock.advance(99);
  const before = [[...ran], terminal.requests() - requests];
  terminal.clock.advance(1);
  equal([before, ran, terminal.requests() - requests], [[["early"], 1], ["early", "late"], 2]);
  terminal.clock.advance(1000);
  equal(ran, ["early", "late"]);
  tui.after(10, () => ran.push("stopped"));
  stop.abort();
  terminal.clock.advance(10);
  equal(ran, ["early", "late"]);
});

test("one advance runs due timers in time order with the oldest timer first at the same time", () => {
  const terminal = fakeTerminal();
  const tui = createSurface(new Core(terminal.driver), "timers", new AbortController().signal);
  const ran: string[] = [];
  tui.after(30, () => ran.push("30"));
  tui.after(20, () => ran.push("20"));
  tui.after(20, () => ran.push("20 again"));
  tui.after(10, () => {
    ran.push("10");
    tui.after(5, () => ran.push("15"));
  });
  terminal.clock.advance(30);
  equal(ran, ["10", "15", "20", "20 again", "30"]);
});

test("a throwing timer is reported under its plugin", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const tui = createSurface(core, "timers", new AbortController().signal);
  tui.after(0, () => {
    throw new Error("bad timer");
  });
  terminal.clock.advance(0);
  equal(
    core.notices.list().map((notice) => [notice.source, notice.text.split("\n")[0]]),
    [["timers", "a timer failed: Error: bad timer"]],
  );
});

/** A view that writes `text` on its first row. */
function label(text: string): View {
  return {
    draw: (canvas) => {
      canvas.text(0, 0, text);
    },
  };
}

test("each root wraps the root below, and a close removes only that root", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const bar = core.scene.wrapRoot("bar", (_mount, inner) =>
    stack("column", [
      { view: inner, size: "fill" },
      { view: label("bar"), size: 1 },
    ]),
  );
  const side = core.scene.wrapRoot("side", (_mount, inner) =>
    stack("row", [
      { view: inner, size: "fill" },
      { view: label("side"), size: 4 },
    ]),
  );
  const top = core.scene.wrapRoot("top", (_mount, inner) =>
    stack("column", [
      { view: label("top"), size: 1 },
      { view: inner, size: "fill" },
    ]),
  );
  equal(bar.signal.aborted, false);
  let screen = terminal.screen(core);
  equal(screen[0], "top");
  equal(screen[1]?.slice(16), "side");
  equal(screen[5], "bar");
  // The top root stays, and it places the bar now.
  side.close();
  screen = terminal.screen(core);
  equal([screen[0], screen[1], screen[5]], ["top", "", "bar"]);
  top.close();
  screen = terminal.screen(core);
  equal([screen[0], screen[5]], ["", "bar"]);
  bar.close();
  equal(terminal.screen(core)[5], "");
});

test("a root that does not place `inner` covers the root below until the close", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const below = core.scene.wrapRoot("below", () => label("below"));
  const cover = core.scene.wrapRoot("cover", () => label("cover"));
  equal(terminal.screen(core)[0], "cover");
  cover.close();
  equal(terminal.screen(core)[0], "below");
  equal(below.signal.aborted, false);
});

test("a view beside the panes gets the mouse and leaves the focus on the active pane", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const tui = createSurface(core, "test", new AbortController().signal);
  const pressed: string[] = [];
  const side: View = {
    ...label("side"),
    mouse: (event) => {
      pressed.push(event.action);
      return true;
    },
  };
  const left = tui.panes.split(() => label("left"));
  const right = tui.panes.split(() => label("right"));
  const root = tui.wrapRoot((_mount, inner) =>
    stack("row", [
      { view: inner, size: "fill" },
      { view: side, size: 4 },
    ]),
  );
  terminal.screen(core);
  equal(tui.panes.active, right);
  // The view gets the press. The active pane keeps the focus.
  core.event(click(18, 0));
  equal(pressed.includes("press"), true);
  equal(tui.panes.active, right);
  equal(tui.focused, right.view);
  // No pane is to the right. The focus stays.
  equal(tui.panes.focus("right"), false);
  equal(tui.panes.focus("left"), true);
  equal(tui.panes.active, left);
  root.close();
  terminal.screen(core);
  equal(tui.panes.active, left);
});

test("the first command with a slash word keeps it, and a later one shows its full name", () => {
  const core = new Core(fakeTerminal().driver);
  const signal = new AbortController().signal;
  const add = (owner: string, slash: string | undefined) =>
    createSurface(core, owner, signal).commands.add({ name: "run", slash, run() {} });
  const removeFirst = add("first", "go");
  add("second", "go");
  add("plain", undefined);
  const words = () =>
    Object.fromEntries(
      core.commands
        .list()
        .filter((item) => item.name.endsWith(":run"))
        .map((item) => [item.name, item.slash]),
    );
  equal(words(), { "first:run": "go", "second:run": "second:run", "plain:run": undefined });
  // A word with a space never matches a draft, so the add refuses it.
  assert(
    throws(() => createSurface(core, "bad", signal).commands.add({ name: "run", slash: "a b", run() {} })) instanceof
      TypeError,
  );
  // The word goes to the next command when its holder leaves.
  removeFirst();
  equal(words(), { "second:run": "go", "plain:run": undefined });
  // A full name that a later command shows also counts as taken.
  add("third", "go");
  add("fourth", "third:run");
  equal(words()["fourth:run"], "fourth:run");
});

test("the cursor of the focused view reaches the screen inside its clip with its shape", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  let at: Cursor = { column: 2, row: 0, shape: "bar" };
  const input: View = { focusable: true, draw() {}, cursor: () => at };
  core.scene.wrapRoot("test", () => ({
    layout: () => [{ view: input, rect: { column: 5, row: 3, width: 4, height: 1 } }],
    draw() {},
  }));
  core.scene.layout();
  core.scene.focus(input);
  terminal.screen(core);
  at = { column: 1, row: 0 };
  terminal.screen(core);
  at = { column: 9, row: 0 };
  terminal.screen(core);
  equal(terminal.cursors, [{ column: 7, row: 3, shape: "bar" }, { column: 6, row: 3 }, undefined]);
});

test("the core commands reach the driver", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  for (const name of ["quit", "suspend", "reload"]) core.commands.run(`core:${name}`);
  equal(terminal.calls, ["quit", "suspend", ["reload", { tree: null, focus: 0 }]]);
});

test("a focus change beneath a modal moves the active pane", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const panes = createSurface(core, "test", new AbortController().signal).panes;
  const a = panes.split(() => ({ draw() {} }));
  panes.split(() => ({ draw() {} }));
  terminal.screen(core);
  core.scene.overlay("test", () => ({ draw() {} }));
  terminal.screen(core);
  // A focus of the scene beneath the modal, as `tui.focus` gives, moves the active pane too.
  core.scene.focus(a.view);
  terminal.screen(core);
  assert(panes.active === a, "the focus makes a active");
  equal(atoms(core), ["global", "overlay"]);
});

test("a view that leaves the tree gets its focus loss and its capture cancel", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const log: string[] = [];
  let shown = true;
  const child: View = {
    focusable: true,
    draw() {},
    focusChanged: (focused) => log.push(`focus ${focused}`),
    mouse: (event) => {
      log.push(`mouse ${event.action}`);
      return true;
    },
  };
  core.scene.wrapRoot("test", () => ({
    layout: () => (shown ? [{ view: child, rect: { column: 0, row: 0, width: 5, height: 1 } }] : []),
    draw() {},
  }));
  core.event(click(1, 0, "press"));
  shown = false;
  terminal.screen(core);
  // The child leaves the layout during its drag: the layout gives it `cancel` and `focus false`; the release is gone.
  equal(log, ["focus true", "mouse press", "mouse cancel", "focus false"]);
  core.event(click(2, 0, "release"));
  equal(log.length, 4);
});

test("a press that opens a modal captures nothing", () => {
  const core = new Core(fakeTerminal().driver);
  const log: string[] = [];
  const opener: View = {
    focusable: true,
    draw() {},
    mouse: (event) => {
      log.push(`opener ${event.action}`);
      if (event.action === "press") core.scene.overlay("test", () => ({ draw() {}, mouse: () => true }));
      return true;
    },
  };
  core.scene.wrapRoot("test", () => ({
    layout: () => [{ view: opener, rect: { column: 0, row: 0, width: 5, height: 1 } }],
    draw() {},
  }));
  core.event(click(1, 0, "press"));
  core.event(click(1, 0, "drag"));
  core.event(click(1, 0, "release"));
  equal(log, ["opener press"]);
});

test("a bare name gets the plugin prefix and a foreign prefix throws", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const log: string[] = [];
  const tui = createSurface(core, "notes", new AbortController().signal);
  tui.commands.add({
    name: "open",
    run: () => {
      log.push("open");
    },
  });
  tui.keys.bind("ctrl+n", "open");
  tui.views.register("note", () => ({ draw() {} }));
  assert(throws(() => tui.commands.add({ name: "other:x", run() {} })) instanceof TypeError);
  assert(throws(() => tui.views.register("core:note", () => ({ draw() {} }))) instanceof TypeError);
  tui.commands.add({ name: "notes:close", run() {} });
  equal([tui.commands.run("open"), tui.commands.run("core:quit")], [true, true]);
  equal(log, ["open"]);
  equal(terminal.calls, ["quit"]);
  equal(
    tui.commands
      .list()
      .map((item) => item.name)
      .filter((name) => name.startsWith("notes:")),
    ["notes:open", "notes:close"],
  );
  equal(tui.keys.keysOf("open"), ["ctrl+n"]);
  assert(core.views.get("notes:note") !== undefined, "the view type has the plugin prefix");
});

test("the stop of a plugin removes its registrations and mounts and later calls throw", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const heard: unknown[] = [];
  const thrownDuringStop: unknown[] = [];
  const stop = new AbortController();
  // A listener of the plugin that runs before the one of the surface sees a stopped surface too.
  stop.signal.addEventListener("abort", () => {
    thrownDuringStop.push(throws(() => tui.commands.add({ name: "during", run() {} })));
  });
  const tui = createSurface(core, "notes", stop.signal);
  const once = tui.commands.add({ name: "open", run() {} });
  once();
  tui.commands.add({ name: "open", run() {} });
  tui.keys.bind("ctrl+n", "open");
  tui.styles.set({ "notes.title": { bold: true } });
  tui.notices.on((notice) => heard.push(notice));
  tui.views.register("note", () => ({ draw() {} }));
  const pane = tui.panes.split(() => ({
    draw: (canvas) => {
      canvas.text(0, 0, "pane");
    },
  }));
  const overlay = tui.overlay(() => ({ draw() {} }), {
    modal: false,
    place: () => ({ column: 0, row: 5, width: 1, height: 1 }),
  });
  const root = tui.wrapRoot(() => ({
    draw: (canvas) => {
      canvas.text(0, 0, "root");
    },
  }));
  equal(terminal.screen(core)[0], "root");
  stop.abort();
  core.notices.add("info", "core", "after");
  assert(throws(() => tui.commands.add({ name: "late", run() {} })) instanceof TypeError);
  once();
  root.close();
  // After the stop the pane tree is an empty pane again: the root, the pane, and the overlay of the plugin are gone.
  equal(terminal.screen(core)[0], "");
  equal([pane.signal.aborted, overlay.signal.aborted, root.signal.aborted], [true, true, true]);
  equal(
    core.commands.list().some((item) => item.name.startsWith("notes:")),
    false,
  );
  equal(core.keymap.keysOf("notes:open"), []);
  equal(core.styles.resolve("notes.title"), {});
  equal(core.views.get("notes:note"), undefined);
  equal(heard, []);
  equal(thrownDuringStop.length, 1);
  assert(thrownDuringStop[0] instanceof TypeError);
});

test("a command of a plugin keeps its this and its fault names the plugin", () => {
  const core = new Core(fakeTerminal().driver);
  class Counter {
    count = 0;
    readonly name = "count";
    run(): void {
      this.count += 1;
    }
  }
  const counter = new Counter();
  const tui = createSurface(core, "notes", new AbortController().signal);
  tui.commands.add(counter);
  tui.commands.add({
    name: "broken",
    run: () => {
      throw new Error("no disk");
    },
  });
  tui.commands.run("count");
  tui.commands.run("count");
  tui.commands.run("broken");
  const fault = core.notices.list().at(-1);
  equal(counter.count, 2);
  equal([fault?.source, fault?.text.split("\n")[0]], ["notes", "the command notes:broken failed: Error: no disk"]);
});

/** The state of a note: its id. */
type NoteState = { readonly id: number };

/** A note shows its id and saves its state. */
function note(state: NoteState): View {
  return {
    draw: (canvas, focused) => {
      canvas.text(0, 0, `${focused ? "N" : "n"}ote ${state.id}`);
    },
    snapshot: () => ({ type: "note", state }),
  };
}

/** The restore of a note. The tests save only notes, so the state is a `NoteState`. */
const restoreNote: RestoreView = (state) => note(state as NoteState);

test("the panes of a snapshot come back with their views and focus", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const tui = createSurface(core, "notes", new AbortController().signal);
  tui.views.register("note", restoreNote);
  const one = tui.panes.split(() => note({ id: 1 }));
  tui.panes.split(() => note({ id: 2 }), { direction: "column" });
  tui.panes.split(() => ({ draw() {} }));
  terminal.screen(core);
  one.focus();
  const before = terminal.screen(core);
  const snapshot = core.snapshot();
  const restored = new Core(terminal.driver);
  createSurface(restored, "notes", new AbortController().signal).views.register("note", restoreNote);
  restored.restore(snapshot);
  // The empty pane and the view without `snapshot()` save as `null`; the focus is the index of note 1.
  equal(JSON.parse(snapshot), {
    tree: {
      split: "row",
      first: null,
      second: {
        split: "column",
        first: { type: "notes:note", state: { id: 1 } },
        second: {
          split: "row",
          first: { type: "notes:note", state: { id: 2 } },
          second: null,
        },
      },
    },
    focus: 1,
  });
  equal(before, [
    "          │Note 1",
    "          │",
    "          │",
    "          │─────────",
    "          │note│",
    "          │    │",
  ]);
  // After the restore the layout and the focus are the same, and the view without a snapshot is an empty pane.
  equal(terminal.screen(restored), [
    "          │Note 1",
    "          │",
    "          │",
    "          │─────────",
    "          │note│",
    "          │    │",
  ]);
});

test("a restore drops a pane without its plugin and keeps an empty pane for a failed one", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const notes = new AbortController();
  const tui = createSurface(core, "notes", notes.signal);
  tui.views.register("note", restoreNote);
  const earlier = tui.panes.split(() => note({ id: 9 }));
  createSurface(core, "broken", new AbortController().signal).views.register("view", () => {
    throw new Error("old state");
  });
  const split = (first: unknown, second: unknown) => ({ split: "row", first, second });
  const saved = {
    tree: split(split({ type: "gone:view", state: 1 }, { type: "notes:note", state: { id: 3 } }), {
      type: "broken:view",
      state: 2,
    }),
    focus: 0,
  };
  core.restore(JSON.stringify(saved));
  // `gone:view` has no factory: its pane goes, and note 3 takes its place, with the focus of the gone leaf.
  equal(terminal.screen(core)[0], "Note 3    │");
  // The restore closes the panes from before it.
  equal(earlier.signal.aborted, true);
  const fault = core.notices.list().at(-1);
  equal([fault?.source, fault?.text.split("\n")[0]], ["broken", "a view did not start: Error: old state"]);
  // The stop of `notes` closes its restored pane too.
  notes.abort();
  equal(terminal.screen(core)[0], "");
});
