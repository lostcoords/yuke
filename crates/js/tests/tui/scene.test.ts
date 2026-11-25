// The core of the terminal interface on a fake 20×6 driver: placement, clipping, input routing, focus, overlays, the
// main view, the plugin surface, and the snapshot of a reload.

import { Core } from "yuke:internal/tui/core";
import { createSurface } from "yuke:internal/tui/surface";
import { assert, assertEquals, assertThrows, test } from "yuke:test";
import { type Cursor, type JsonValue, type Mount, type MouseEvent, stack, type View } from "yuke:tui";
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
  assertEquals(terminal.screen(core).slice(0, 4), ["abcd CDE", " xyz  QR", "      Z", "parent"]);
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
  assertEquals(column.layout({ width: 20, height: 10 }), [
    { view: first, rect: { column: 0, row: 0, width: 20, height: 1 } },
    { view: second, rect: { column: 0, row: 1, width: 20, height: 3 } },
    { view: third, rect: { column: 0, row: 4, width: 20, height: 2 } },
    { view: fourth, rect: { column: 0, row: 6, width: 20, height: 4 } },
  ]);
  assertEquals(row.layout({ width: 20, height: 3 }), [
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
  core.keymap.add("b", "test:bound");
  const child: View = {
    focusable: true,
    contexts: ["editor"],
    draw() {},
    onKey: (event) => {
      log.push(`child ${event.character}`);
      return event.character === "c";
    },
  };
  core.scene.wrapRoot("test", () => ({
    layout: () => [{ view: child, rect: { column: 0, row: 0, width: 5, height: 1 } }],
    draw() {},
    onKey: (event) => {
      log.push(`parent ${event.character}`);
      return true;
    },
  }));
  core.scene.layout();
  core.scene.focus(child);
  for (const character of ["b", "c", "p"]) core.event(key(character));
  assertEquals(log, ["command", "child c", "child p", "parent p"]);
  assertEquals(atoms(core), ["global", "root", "editor"]);
});

test("escape closes the top modal when nothing takes it", () => {
  const core = new Core(fakeTerminal().driver);
  const log: string[] = [];
  let query = "abc";
  const keeps = core.scene.overlay("test", (mount) => {
    mount.signal.addEventListener("abort", () => log.push("keeps closed"));
    return {
      draw() {},
      onKey: (event) => {
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
  assertEquals(keeps.signal.aborted, false);
  core.event(named("esc"));
  core.scene.overlay("test", () => ({ draw() {} }), { modal: false });
  core.event(named("esc"));
  assertEquals(keeps.signal.aborted, true);
  assertEquals(log, ["keeps closed"]);
  assertEquals(atoms(core), ["global", "root"]);
});

test("a modal takes all input below it and a float takes only what it handles", () => {
  const core = new Core(fakeTerminal().driver);
  const log: string[] = [];
  core.scene.wrapRoot("test", () => ({
    focusable: true,
    draw() {},
    onKey: () => {
      log.push("root key");
      return true;
    },
    onMouse: (event) => {
      log.push(`root mouse ${event.action}`);
      return true;
    },
  }));
  const float = core.scene.overlay(
    "test",
    () => ({
      draw() {},
      onKey: (event) => {
        log.push("float key");
        return event.character === "f";
      },
      onMouse: () => {
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
  assertEquals(log.splice(0), ["float key", "float key", "root key", "float mouse", "root mouse press"]);
  float.close();
  core.scene.overlay("test", () => ({ draw() {}, onKey: () => false, onMouse: () => false }));
  core.event(key("x"));
  core.event(click(10, 3));
  assertEquals(log, ["root mouse cancel"]);
  assertEquals(atoms(core), ["global", "overlay"]);
});

test("a press focuses and captures and a modal cancels the capture", () => {
  const core = new Core(fakeTerminal().driver);
  const log: [string, MouseEvent["action"], number, number][] = [];
  const record = (name: string) => (event: MouseEvent) => {
    log.push([name, event.action, event.column, event.row]);
    return true;
  };
  const a: View = { focusable: true, draw() {}, onMouse: record("a") };
  const b: View = { focusable: true, draw() {}, onMouse: record("b") };
  core.scene.wrapRoot("test", () => ({
    layout: () => [
      { view: a, rect: { column: 0, row: 0, width: 5, height: 2 } },
      { view: b, rect: { column: 10, row: 0, width: 5, height: 2 } },
    ],
    draw() {},
  }));
  core.event(click(11, 1));
  assert(core.scene.focusedView === b, "a press focuses b");
  core.event(click(2, 0, "press"));
  core.event(click(15, 4, "drag"));
  core.event(click(16, 5, "release"));
  core.event(click(1, 1, "press"));
  core.scene.overlay("test", () => ({ draw() {} }));
  core.event(click(3, 3, "release"));
  assert(core.scene.focusedView !== a, "the modal takes the focus from a");
  // The drag and the release reach `a` outside its rect; the modal sends `cancel` and takes the later release.
  assertEquals(log, [
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
    onMouse: (event) => {
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
  const pressed = core.scene.focusedView === outer;
  core.scene.focus(inner);
  assertEquals([presses, pressed, core.scene.focusedView === inner], [["press"], true, true]);
});

test("the main view takes a press and the focus without focusable", () => {
  const core = new Core(fakeTerminal().driver);
  const tui = createSurface(core, "test", new AbortController().signal);
  const main = label("main");
  const side: View = { focusable: true, draw() {} };
  tui.setMain(() => main);
  tui.wrapRoot((_mount, inner) =>
    stack("row", [
      { view: inner, size: "fill" },
      { view: side, size: 4 },
    ]),
  );
  core.event({ type: "start" });
  core.scene.layout();
  const away = tui.focus(side);
  core.event(click(1, 0));
  assertEquals([away, tui.focusedView === main], [true, true]);
});

test("the main view shows at the start, the last factory wins, and its remover brings back the one before", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const tui = createSurface(core, "test", new AbortController().signal);
  const mounts: Mount[] = [];
  const make =
    (name: string) =>
    (mount: Mount, saved: JsonValue): View => {
      mounts.push(mount);
      return { draw: (canvas) => canvas.text(0, 0, `${name} ${String(saved)}`) };
    };
  tui.setMain(make("a"));
  const beforeStart = terminal.screen(core)[0];
  core.event({ type: "start" });
  const started = terminal.screen(core)[0];
  const removeB = tui.setMain(make("b"));
  const replaced = terminal.screen(core)[0];
  removeB();
  assertEquals([beforeStart, started, replaced, terminal.screen(core)[0]], ["", "a null", "b null", "a null"]);
  // Each change closes the main view before it, and the factory that comes back makes a new view.
  assertEquals(
    mounts.map((mount) => mount.signal.aborted),
    [true, true, false],
  );
});

test("a main factory that throws gives one fault, and the close of its mount empties the main view", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  core.event({ type: "start" });
  let mount: Mount | undefined;
  createSurface(core, "notes", new AbortController().signal).setMain((given) => {
    mount = given;
    return label("notes");
  });
  const shown = terminal.screen(core)[0];
  mount?.close();
  const closed = terminal.screen(core)[0];
  createSurface(core, "broken", new AbortController().signal).setMain(() => {
    throw new Error("no disk");
  });
  const fault = core.notices.list().at(-1);
  assertEquals([shown, closed, terminal.screen(core)[0]], ["notes", "", ""]);
  assertEquals([fault?.source, fault?.text.split("\n")[0]], ["broken", "A view did not start: Error: no disk"]);
});

test("a new main view takes the focus from a view beside it", () => {
  const core = new Core(fakeTerminal().driver);
  const tui = createSurface(core, "test", new AbortController().signal);
  const side: View = { focusable: true, draw() {} };
  const first = label("first");
  const second = label("second");
  tui.setMain(() => first);
  tui.wrapRoot((_mount, inner) =>
    stack("row", [
      { view: inner, size: "fill" },
      { view: side, size: 4 },
    ]),
  );
  core.event({ type: "start" });
  core.scene.layout();
  tui.focus(side);
  tui.setMain(() => second);
  core.scene.layout();
  assertEquals(tui.focusedView === second, true);
});

test("the main view gets its inner focus back, and a focus change drops a pending key sequence", () => {
  const core = new Core(fakeTerminal().driver);
  const tui = createSurface(core, "test", new AbortController().signal);
  const log: string[] = [];
  const composer: View = { focusable: true, draw() {}, onFocusChange: (focused) => log.push(`composer ${focused}`) };
  const transcript: View = { focusable: true, draw() {} };
  const chat: View = {
    draw() {},
    onFocusChange: (focused) => log.push(`chat ${focused}`),
    layout: (size) => [
      { view: transcript, rect: { column: 0, row: 0, width: size.width, height: size.height - 1 } },
      { view: composer, rect: { column: 0, row: size.height - 1, width: size.width, height: 1 } },
    ],
  };
  const sidebar: View = { focusable: true, draw() {} };
  tui.setMain(() => chat);
  tui.wrapRoot((_mount, inner) =>
    stack("row", [
      { view: inner, size: "fill" },
      { view: sidebar, size: 4 },
    ]),
  );
  core.event({ type: "start" });
  core.scene.layout();
  tui.focus(composer);
  tui.commands.add({ name: "none", run() {} });
  tui.keys.add("ctrl+k x", "none");
  core.event(key("k", { ctrl: true }));
  const pending = core.keymap.pending();
  tui.focus(sidebar);
  tui.focus(chat);
  core.scene.layout();
  assertEquals([pending, core.keymap.pending(), tui.focusedView === composer], ["ctrl+k", "", true]);
  assertEquals(log, ["chat true", "composer true", "chat false", "composer false", "chat true", "composer true"]);
});

test("the main view starts at its initial focus, and a focus beneath a modal changes no focused view", () => {
  const core = new Core(fakeTerminal().driver);
  const tui = createSurface(core, "chat", new AbortController().signal);
  const composer: View = { focusable: true, draw() {} };
  const transcript: View = { focusable: true, draw() {} };
  const input: View = { focusable: true, draw() {} };
  const names = new Map<View | undefined, string>([
    [composer, "composer"],
    [transcript, "transcript"],
    [input, "modal input"],
  ]);
  const changes: string[] = [];
  tui.addFocusListener((change) => {
    changes.push(`${names.get(change.previousView) ?? "none"} -> ${names.get(change.focusedView) ?? "?"}`);
  });
  tui.setMain(() => ({
    draw() {},
    initialFocus: composer,
    layout: (size) => [
      { view: transcript, rect: { column: 0, row: 0, width: size.width, height: size.height - 1 } },
      { view: composer, rect: { column: 0, row: size.height - 1, width: size.width, height: 1 } },
    ],
  }));
  core.event({ type: "start" });
  core.draw();
  tui.focus(transcript);
  core.draw();
  const modal = tui.overlay(() => ({
    draw() {},
    initialFocus: input,
    layout: () => [{ view: input, rect: { column: 0, row: 0, width: 5, height: 1 } }],
  }));
  core.draw();
  // A focus beneath the modal waits there, so `tui.focusedView` stays the modal input until the close.
  tui.focus(composer);
  core.draw();
  const atomsUnderModal = atoms(core);
  modal.close();
  core.draw();
  assertEquals(changes, [
    "none -> composer",
    "composer -> transcript",
    "transcript -> modal input",
    "modal input -> composer",
  ]);
  assertEquals(atomsUnderModal, ["global", "overlay"]);
});

test("a timer runs once in time order, asks for a frame, and its disposer or the stop of its plugin cancels it", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const stop = new AbortController();
  const tui = createSurface(core, "timers", stop.signal);
  const ran: string[] = [];
  tui.addTimer(100, () => ran.push("late"));
  const cancel = tui.addTimer(100, () => ran.push("cancelled"));
  tui.addTimer(50, () => ran.push("early"));
  cancel();
  const requests = terminal.requests();
  terminal.clock.advance(99);
  const before = [[...ran], terminal.requests() - requests];
  terminal.clock.advance(1);
  assertEquals([before, ran, terminal.requests() - requests], [[["early"], 1], ["early", "late"], 2]);
  terminal.clock.advance(1000);
  assertEquals(ran, ["early", "late"]);
  tui.addTimer(10, () => ran.push("stopped"));
  stop.abort();
  terminal.clock.advance(10);
  assertEquals(ran, ["early", "late"]);
});

test("one advance runs due timers in time order with the oldest timer first at the same time", () => {
  const terminal = fakeTerminal();
  const tui = createSurface(new Core(terminal.driver), "timers", new AbortController().signal);
  const ran: string[] = [];
  tui.addTimer(30, () => ran.push("30"));
  tui.addTimer(20, () => ran.push("20"));
  tui.addTimer(20, () => ran.push("20 again"));
  tui.addTimer(10, () => {
    ran.push("10");
    tui.addTimer(5, () => ran.push("15"));
  });
  terminal.clock.advance(30);
  assertEquals(ran, ["10", "15", "20", "20 again", "30"]);
});

test("a throwing timer is reported under its plugin", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const tui = createSurface(core, "timers", new AbortController().signal);
  tui.addTimer(0, () => {
    throw new Error("bad timer");
  });
  terminal.clock.advance(0);
  assertEquals(
    core.notices.list().map((notice) => [notice.source, notice.text.split("\n")[0]]),
    [["timers", "A timer failed: Error: bad timer"]],
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
  assertEquals(bar.signal.aborted, false);
  let screen = terminal.screen(core);
  assertEquals(screen[0], "top");
  assertEquals(screen[1]?.slice(16), "side");
  assertEquals(screen[5], "bar");
  // The top root stays, and it places the bar now.
  side.close();
  screen = terminal.screen(core);
  assertEquals([screen[0], screen[1], screen[5]], ["top", "", "bar"]);
  top.close();
  screen = terminal.screen(core);
  assertEquals([screen[0], screen[5]], ["", "bar"]);
  bar.close();
  assertEquals(terminal.screen(core)[5], "");
});

test("a root that does not place `inner` covers the root below until the close", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const below = core.scene.wrapRoot("below", () => label("below"));
  const cover = core.scene.wrapRoot("cover", () => label("cover"));
  assertEquals(terminal.screen(core)[0], "cover");
  cover.close();
  assertEquals(terminal.screen(core)[0], "below");
  assertEquals(below.signal.aborted, false);
});

test("a view beside the main view gets the mouse and leaves the focus on the main view", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const tui = createSurface(core, "test", new AbortController().signal);
  const pressed: string[] = [];
  const side: View = {
    ...label("side"),
    onMouse: (event) => {
      pressed.push(event.action);
      return true;
    },
  };
  const main = label("main");
  tui.setMain(() => main);
  tui.wrapRoot((_mount, inner) =>
    stack("row", [
      { view: inner, size: "fill" },
      { view: side, size: 4 },
    ]),
  );
  core.event({ type: "start" });
  terminal.screen(core);
  core.event(click(18, 0));
  assertEquals([pressed.includes("press"), tui.focusedView === main], [true, true]);
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
  assertEquals(words(), { "first:run": "go", "second:run": "second:run", "plain:run": undefined });
  // A word with a space never matches a draft, so the add refuses it.
  assert(
    assertThrows(() =>
      createSurface(core, "bad", signal).commands.add({ name: "run", slash: "a b", run() {} }),
    ) instanceof TypeError,
  );
  // The word goes to the next command when its holder leaves.
  removeFirst();
  assertEquals(words(), { "second:run": "go", "plain:run": undefined });
  // A full name that a later command shows also counts as taken.
  add("third", "go");
  add("fourth", "third:run");
  assertEquals(words()["fourth:run"], "fourth:run");
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
  assertEquals(terminal.cursors, [{ column: 7, row: 3, shape: "bar" }, { column: 6, row: 3 }, undefined]);
});

test("the core commands reach the driver", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  for (const name of ["quit", "suspend", "reload"]) core.commands.run(`core:${name}`);
  assertEquals(terminal.calls, ["quit", "suspend", ["reload", {}]]);
});

test("a view that leaves the tree gets its focus loss and its capture cancel", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const log: string[] = [];
  let shown = true;
  const child: View = {
    focusable: true,
    draw() {},
    onFocusChange: (focused) => log.push(`focus ${focused}`),
    onMouse: (event) => {
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
  assertEquals(log, ["focus true", "mouse press", "mouse cancel", "focus false"]);
  core.event(click(2, 0, "release"));
  assertEquals(log.length, 4);
});

test("a press that opens a modal captures nothing", () => {
  const core = new Core(fakeTerminal().driver);
  const log: string[] = [];
  const opener: View = {
    focusable: true,
    draw() {},
    onMouse: (event) => {
      log.push(`opener ${event.action}`);
      if (event.action === "press") core.scene.overlay("test", () => ({ draw() {}, onMouse: () => true }));
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
  assertEquals(log, ["opener press"]);
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
  tui.keys.add("ctrl+n", "open");
  assert(assertThrows(() => tui.commands.add({ name: "other:x", run() {} })) instanceof TypeError);
  tui.commands.add({ name: "notes:close", run() {} });
  assertEquals([tui.commands.run("open"), tui.commands.run("core:quit")], [true, true]);
  assertEquals(log, ["open"]);
  assertEquals(terminal.calls, ["quit"]);
  assertEquals(
    tui.commands
      .list()
      .map((item) => item.name)
      .filter((name) => name.startsWith("notes:")),
    ["notes:open", "notes:close"],
  );
  assertEquals(tui.keys.list("open"), ["ctrl+n"]);
});

test("the stop of a plugin removes its registrations and mounts and later calls throw", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const heard: unknown[] = [];
  const thrownDuringStop: unknown[] = [];
  const stop = new AbortController();
  // A listener of the plugin that runs before the one of the surface sees a stopped surface too.
  stop.signal.addEventListener("abort", () => {
    thrownDuringStop.push(assertThrows(() => tui.commands.add({ name: "during", run() {} })));
  });
  const tui = createSurface(core, "notes", stop.signal);
  const once = tui.commands.add({ name: "open", run() {} });
  once();
  tui.commands.add({ name: "open", run() {} });
  tui.keys.add("ctrl+n", "open");
  tui.styles.add({ "notes.title": { bold: true } });
  tui.notices.addListener((notice) => heard.push(notice));
  let main: Mount | undefined;
  tui.setMain((mount) => {
    main = mount;
    return label("main");
  });
  core.event({ type: "start" });
  const overlay = tui.overlay(() => ({ draw() {} }), {
    modal: false,
    place: () => ({ column: 0, row: 5, width: 1, height: 1 }),
  });
  const root = tui.wrapRoot(() => ({
    draw: (canvas) => {
      canvas.text(0, 0, "root");
    },
  }));
  assertEquals(terminal.screen(core)[0], "root");
  stop.abort();
  core.notices.add("info", "core", "after");
  assert(assertThrows(() => tui.commands.add({ name: "late", run() {} })) instanceof TypeError);
  once();
  root.close();
  // After the stop the main view is empty again: the root, the main view, and the overlay of the plugin are gone.
  assertEquals(terminal.screen(core)[0], "");
  assertEquals([main?.signal.aborted, overlay.signal.aborted, root.signal.aborted], [true, true, true]);
  assertEquals(
    core.commands.list().some((item) => item.name.startsWith("notes:")),
    false,
  );
  assertEquals(core.keymap.list("notes:open"), []);
  assertEquals(core.styles.resolve("notes.title"), {});
  assertEquals(heard, []);
  assertEquals(thrownDuringStop.length, 1);
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
  assertEquals(counter.count, 2);
  assertEquals(
    [fault?.source, fault?.text.split("\n")[0]],
    ["notes", "The command notes:broken failed: Error: no disk"],
  );
});

test("a reload gives the saved value of the main view back to a factory of the same plugin only", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const note = (id: JsonValue): View => ({
    draw: (canvas) => canvas.text(0, 0, `note ${String(id)}`),
    snapshot: () => id,
  });
  createSurface(core, "notes", new AbortController().signal).setMain((_mount, saved) => note(saved ?? 1));
  core.event({ type: "start" });
  const snapshot = core.snapshot();
  /** The first row of a new core whose plugin `owner` makes the main view, after a start with `saved`. */
  const restored = (owner: string, saved: string | undefined): string | undefined => {
    const next = new Core(terminal.driver);
    createSurface(next, owner, new AbortController().signal).setMain((_mount, value) => note(value ?? 2));
    next.event(saved === undefined ? { type: "start" } : { type: "start", snapshot: saved });
    return terminal.screen(next)[0];
  };
  assertEquals(JSON.parse(snapshot), { main: { owner: "notes", state: 1 } });
  // A snapshot of an older yuke has no `main`, so its factory starts new.
  assertEquals(
    [restored("notes", snapshot), restored("other", snapshot), restored("notes", '{"tree":null,"focus":0}')],
    ["note 1", "note 2", "note 2"],
  );
});
