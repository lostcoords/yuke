// The core contracts of the text widgets on a fake 20×6 driver: mounts, extensions, and the early key phase.
// A test widget takes the place of the editor and the text view.

import { createSurface } from "yuke:internal/tui/surface";
import { registerWidget, TextSupport, type WidgetMount } from "yuke:internal/tui/widgets";
import { equal, test } from "yuke:test";
import type { Canvas, Cursor, KeyEvent, TextExtension, View } from "yuke:tui";
import { atoms, fakeTerminal, key, named, newCore } from "./terminal.ts";

/** A text widget of one line: it types characters and pastes by default, and draws its prompt and cursor shape. */
class Probe implements View {
  readonly focusable = true;
  readonly support: TextSupport<number, string>;
  text = "";

  constructor(group?: object) {
    this.support = new TextSupport(group);
    registerWidget(this, this.support);
  }

  extend(signal: AbortSignal): TextExtension<number, string> {
    return this.support.extend(signal);
  }

  get contexts(): string[] {
    return ["probe", ...this.support.contexts()];
  }

  draw(canvas: Canvas): void {
    canvas.text(0, 0, `${this.support.appearance().prompt ?? ""}${this.text}`);
  }

  cursor(): Cursor {
    const appearance = this.support.appearance();
    const column = (appearance.prompt ?? "").length + this.text.length;
    return { column, row: 0, ...(appearance.cursorShape === undefined ? {} : { shape: appearance.cursorShape }) };
  }

  key(event: KeyEvent): boolean {
    if (this.support.key(event, "beforeDefault")) return true;
    if (event.code !== "character") return false;
    this.text += event.character;
    this.support.emit(this.text);
    return true;
  }

  paste(text: string): boolean {
    if (this.support.paste(text)) return true;
    this.text += text;
    return true;
  }
}

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
  const core = newCore(terminal);
  const panes = createSurface(core, "chat", new AbortController().signal).panes;
  const probe = new Probe();
  const log: string[] = [];
  const signals: AbortSignal[] = [];
  const watcher = (name: string) => (mount: WidgetMount) => {
    log.push(`${name} attach ${mount.pane === undefined ? "no pane" : "pane"}`);
    signals.push(mount.signal);
    return () => log.push(`${name} cleanup`);
  };
  core.widgets.watch("early", watcher("early"));
  const pane = panes.split(() => holder(probe));
  terminal.screen(core);
  terminal.screen(core);
  // A modal covers the widget but does not unmount it.
  const modal = core.scene.overlay("test", () => ({ draw() {} }));
  terminal.screen(core);
  core.widgets.watch("late", watcher("late"));
  modal.close();
  terminal.screen(core);
  pane.close();
  terminal.screen(core);
  panes.split(() => holder(probe));
  terminal.screen(core);
  equal(log, [
    "early attach pane",
    "late attach pane",
    "early cleanup",
    "late cleanup",
    "early attach pane",
    "late attach pane",
  ]);
  equal(
    signals.map((signal) => signal.aborted),
    [true, true, false, false],
  );
  equal(core.widgets.list().length, 1);
});

test("a watch that starts inside an attach sees each mount once", () => {
  const terminal = fakeTerminal();
  const core = newCore(terminal);
  const first = new Probe();
  const second = new Probe();
  core.scene.setRoot("chat", () => ({
    draw() {},
    layout: () => [
      { view: first, rect: { column: 0, row: 0, width: 5, height: 1 } },
      { view: second, rect: { column: 0, row: 1, width: 5, height: 1 } },
    ],
  }));
  const log: string[] = [];
  const name = (mount: WidgetMount): string => (mount.widget === first ? "first" : "second");
  core.widgets.watch("outer", () => {
    if (log.length === 0) {
      core.widgets.watch("inner", (mount) => {
        log.push(`inner ${name(mount)}`);
        return () => log.push(`inner cleanup ${name(mount)}`);
      });
    }
    return undefined;
  });
  terminal.screen(core);
  core.scene.setRoot("chat", () => ({ draw() {} }));
  terminal.screen(core);
  equal(log, ["inner first", "inner second", "inner cleanup first", "inner cleanup second"]);
});

test("an early handler takes a continuation before the keymap and enter alone reaches the keymap", () => {
  const core = newCore(fakeTerminal());
  const tui = createSurface(core, "chat", new AbortController().signal);
  const probe = new Probe();
  tui.panes.split(() => holder(probe));
  let submits = 0;
  tui.commands.add({
    name: "submit",
    run: () => {
      submits += 1;
    },
  });
  tui.commands.add({ name: "none", run() {} });
  tui.keys.bind("enter", "submit", { in: "probe" });
  tui.keys.bind("ctrl+k x", "none", { in: "probe" });
  const replaced: string[] = [];
  let pending = false;
  core.widgets.watch("vim", (mount) => {
    const extension = (mount.widget as Probe).extend(mount.signal);
    extension.onKey((event) => {
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
  equal([replaced, submits], [["enter"], 0]);
  core.event(named("enter"));
  equal(submits, 1);
  // A key that the early phase takes ends a pending sequence of the keymap.
  core.event(key("k", { ctrl: true }));
  equal(core.keymap.pending(), "ctrl+k");
  core.event(key("r"));
  equal(core.keymap.pending(), "");
});

test("each extension adds its own part and the stop of one plugin leaves the other", () => {
  const terminal = fakeTerminal();
  const core = newCore(terminal);
  const probe = new Probe();
  core.scene.setRoot("chat", () => holder(probe));
  const typed: string[] = [];
  const extend = (mount: WidgetMount, name: string, shape: "block" | "bar"): (() => void) => {
    const extension = (mount.widget as Probe).extend(mount.signal);
    extension.setContexts([`${name}-mode`]);
    extension.setAppearance({ cursorShape: shape, prompt: `${name}> ` });
    extension.onKey((event) => {
      typed.push(`${name} ${event.character}`);
      return false;
    });
    return () => extension.dispose();
  };
  core.widgets.watch("other", (mount) => extend(mount, "other", "bar"));
  const stopVim = core.widgets.watch("vim", (mount) => extend(mount, "vim", "block"));
  equal(terminal.screen(core)[0], "vim>");
  core.event(key("a"));
  equal(atoms(core), ["global", "root", "probe", "other-mode", "vim-mode"]);
  // The newest handler runs first. A handler that returns false only watches.
  equal([typed, probe.text], [["vim a", "other a"], "a"]);
  stopVim();
  equal(terminal.screen(core)[0], "other> a");
  equal(terminal.cursors.at(-1), { column: 8, row: 0, shape: "bar" });
  core.event(key("b"));
  equal(typed.slice(2), ["other b"]);
  equal(atoms(core).at(-1), "other-mode");
});

test("a contexts change ends a pending sequence and a throwing extension goes", () => {
  const core = newCore(fakeTerminal());
  const tui = createSurface(core, "chat", new AbortController().signal);
  const probe = new Probe();
  tui.panes.split(() => holder(probe));
  tui.commands.add({ name: "none", run() {} });
  tui.keys.bind("ctrl+k x", "none");
  core.draw();
  const extension = probe.extend(new AbortController().signal);
  core.event(key("k", { ctrl: true }));
  equal(core.keymap.pending(), "ctrl+k");
  extension.setContexts(["vim-insert"]);
  equal(core.keymap.pending(), "");
  extension.onPaste(() => {
    throw new Error("bad paste");
  });
  core.event({ type: "paste", text: "one" });
  core.event({ type: "paste", text: "two" });
  equal(probe.text, "onetwo");
  equal(
    core.notices.list().map((notice) => [notice.text.split("\n")[0], notice.count]),
    [["a text widget extension failed and was removed: Error: bad paste", 1]],
  );
  equal(atoms(core).at(-1), "probe");
  // The abort of its signal removes an extension as its dispose does.
  const controller = new AbortController();
  probe.extend(controller.signal).setContexts(["other-mode"]);
  equal(atoms(core).at(-1), "other-mode");
  controller.abort();
  equal(atoms(core).at(-1), "probe");
});
