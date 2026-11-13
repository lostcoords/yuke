// The core contracts of the text widgets on a fake 20×6 driver: mounts, extensions, and the early key phase.

import { Core } from "yuke:internal/tui/core";
import { createSurface } from "yuke:internal/tui/surface";
import { assertEquals, test } from "yuke:test";
import { type PlacedWidget, TextEditor, type View } from "yuke:tui";
import { atoms, fakeTerminal, key, named } from "./terminal.ts";

/** A pane that shows `widget` on its first row. */
function holder(widget: View): View {
  return {
    draw() {},
    initialFocus: widget,
    layout: () => [{ view: widget, rect: { column: 0, row: 0, width: 9, height: 1 } }],
  };
}

test("a watch gets each mount once and its cleanup when the widget leaves", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const panes = createSurface(core, "chat", new AbortController().signal).panes;
  const editor = new TextEditor();
  const log: string[] = [];
  const signals: AbortSignal[] = [];
  const watcher = (name: string) => (mount: PlacedWidget) => {
    log.push(`${name} attach ${mount.pane === undefined ? "no pane" : "pane"}`);
    signals.push(mount.signal);
    return () => log.push(`${name} cleanup`);
  };
  core.widgets.addWatcher("early", watcher("early"));
  const pane = panes.split(() => holder(editor));
  terminal.screen(core);
  terminal.screen(core);
  // A modal covers the widget but does not unmount it.
  const modal = core.scene.overlay("test", () => ({ draw() {} }));
  terminal.screen(core);
  core.widgets.addWatcher("late", watcher("late"));
  modal.close();
  terminal.screen(core);
  pane.close();
  terminal.screen(core);
  panes.split(() => holder(editor));
  terminal.screen(core);
  assertEquals(log, [
    "early attach pane",
    "late attach pane",
    "early cleanup",
    "late cleanup",
    "early attach pane",
    "late attach pane",
  ]);
  assertEquals(
    signals.map((signal) => signal.aborted),
    [true, true, false, false],
  );
  assertEquals(core.widgets.list().length, 1);
});

test("a watch that starts inside an attach sees each mount once", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const first = new TextEditor();
  const second = new TextEditor();
  core.scene.wrapRoot("chat", () => ({
    draw() {},
    layout: () => [
      { view: first, rect: { column: 0, row: 0, width: 5, height: 1 } },
      { view: second, rect: { column: 0, row: 1, width: 5, height: 1 } },
    ],
  }));
  const log: string[] = [];
  const name = (mount: PlacedWidget): string => (mount.widget === first ? "first" : "second");
  core.widgets.addWatcher("outer", () => {
    if (log.length === 0) {
      core.widgets.addWatcher("inner", (mount) => {
        log.push(`inner ${name(mount)}`);
        return () => log.push(`inner cleanup ${name(mount)}`);
      });
    }
    return undefined;
  });
  terminal.screen(core);
  core.scene.wrapRoot("chat", () => ({ draw() {} }));
  terminal.screen(core);
  assertEquals(log, ["inner first", "inner second", "inner cleanup first", "inner cleanup second"]);
});

test("an early handler takes a continuation before the keymap and enter alone reaches the keymap", () => {
  const core = new Core(fakeTerminal().driver);
  const tui = createSurface(core, "chat", new AbortController().signal);
  const editor = new TextEditor();
  tui.panes.split(() => holder(editor));
  let submits = 0;
  tui.commands.add({
    name: "submit",
    run: () => {
      submits += 1;
    },
  });
  tui.commands.add({ name: "none", run() {} });
  tui.keys.add("enter", "submit", { in: "field" });
  tui.keys.add("ctrl+k x", "none", { in: "field" });
  const replaced: string[] = [];
  let pending = false;
  core.widgets.addWatcher("vim", (mount) => {
    const extension = mount.widget.extend(mount.signal);
    extension.addKeyHandler((event) => {
      if (pending) {
        pending = false;
        replaced.push(event.code === "character" ? event.character : event.code);
        return true;
      }
      pending = event.character === "r";
      return pending;
    }, "beforeKeymap");
    return () => extension.dispose();
  });
  core.draw();
  core.event(key("r"));
  core.event(named("enter"));
  assertEquals([replaced, submits], [["enter"], 0]);
  core.event(named("enter"));
  assertEquals(submits, 1);
  // A key that the early phase takes ends a pending sequence of the keymap.
  core.event(key("k", { ctrl: true }));
  assertEquals(core.keymap.pending(), "ctrl+k");
  core.event(key("r"));
  assertEquals(core.keymap.pending(), "");
});

test("a wrap and a close of a root keep the mount of a widget in a pane", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const tui = createSurface(core, "chat", new AbortController().signal);
  const log: string[] = [];
  core.widgets.addWatcher("watcher", () => {
    log.push("attach");
    return () => log.push("cleanup");
  });
  tui.panes.split(() => holder(new TextEditor()));
  terminal.screen(core);
  const root = tui.wrapRoot((_mount, inner) => inner);
  terminal.screen(core);
  root.close();
  terminal.screen(core);
  assertEquals(log, ["attach"]);
});

test("each extension adds its own part and the stop of one plugin leaves the other", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const editor = new TextEditor();
  core.scene.wrapRoot("chat", () => holder(editor));
  const typed: string[] = [];
  const extend = (mount: PlacedWidget, name: string, shape: "block" | "bar"): (() => void) => {
    const extension = mount.widget.extend(mount.signal);
    extension.setContexts([`${name}-mode`]);
    extension.setAppearance({ cursorShape: shape, prompt: `${name}> ` });
    extension.addKeyHandler((event) => {
      typed.push(`${name} ${event.character}`);
      return false;
    });
    return () => extension.dispose();
  };
  core.widgets.addWatcher("other", (mount) => extend(mount, "other", "bar"));
  const stopVim = core.widgets.addWatcher("vim", (mount) => extend(mount, "vim", "block"));
  assertEquals(terminal.screen(core)[0], "vim>");
  core.event(key("a"));
  assertEquals(atoms(core), ["global", "root", "field", "other-mode", "vim-mode"]);
  // The newest handler runs first. A handler that returns false only watches.
  assertEquals([typed, editor.state.text], [["vim a", "other a"], "a"]);
  stopVim();
  assertEquals(terminal.screen(core)[0], "other> a");
  assertEquals(terminal.cursors.at(-1), { column: 8, row: 0, shape: "bar" });
  core.event(key("b"));
  assertEquals(typed.slice(2), ["other b"]);
  assertEquals(atoms(core).at(-1), "other-mode");
});

test("a contexts change ends a pending sequence", () => {
  const core = new Core(fakeTerminal().driver);
  const tui = createSurface(core, "chat", new AbortController().signal);
  const editor = new TextEditor();
  tui.panes.split(() => holder(editor));
  tui.commands.add({ name: "none", run() {} });
  tui.keys.add("ctrl+k x", "none");
  core.draw();
  const extension = editor.extend(new AbortController().signal);
  core.event(key("k", { ctrl: true }));
  assertEquals(core.keymap.pending(), "ctrl+k");
  extension.setContexts(["vim-insert"]);
  assertEquals(core.keymap.pending(), "");
  assertEquals(atoms(core).at(-1), "vim-insert");
  extension.dispose();
  assertEquals(atoms(core).at(-1), "field");
  // The abort of its signal removes an extension as its dispose does.
  const controller = new AbortController();
  editor.extend(controller.signal).setContexts(["other-mode"]);
  assertEquals(atoms(core).at(-1), "other-mode");
  controller.abort();
  assertEquals(atoms(core).at(-1), "field");
});

test("a change of a placed editor by code asks for a frame", () => {
  const terminal = fakeTerminal();
  const core = new Core(terminal.driver);
  const editor = new TextEditor();
  core.scene.wrapRoot("chat", () => holder(editor));
  terminal.screen(core);
  const asked = [terminal.requests()];
  editor.replace(0, 0, "a");
  asked.push(terminal.requests());
  editor.caret = 0;
  asked.push(terminal.requests());
  editor.restore({ text: "", selection: { anchor: 0, head: 0 }, spans: [] });
  asked.push(terminal.requests());
  assertEquals(
    asked.slice(1).map((count, at) => count > (asked[at] ?? Number.POSITIVE_INFINITY)),
    [true, true, true],
  );
});
