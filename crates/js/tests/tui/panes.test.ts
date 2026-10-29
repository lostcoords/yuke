// The default pane of the core on a fake 20×6 driver: the start pane, splits, the last close, restore, and the stop
// of its plugin.

import { createSurface } from "yuke:internal/tui/surface";
import { equal, test, throws } from "yuke:test";
import type { PaneReason, View } from "yuke:tui";
import { fakeTerminal, newCore } from "./terminal.ts";

/** A default pane that shows its reason and number, and the reasons of each call so far. */
function counted(): { readonly create: (mount: unknown, reason: PaneReason) => View; readonly reasons: PaneReason[] } {
  const reasons: PaneReason[] = [];
  return {
    reasons,
    create: (_mount, reason) => {
      reasons.push(reason);
      const name = `${reason} ${reasons.length}`;
      return { draw: (canvas) => canvas.text(0, 0, name) };
    },
  };
}

test("the start pane comes at the later of the start event and the default pane", () => {
  const terminal = fakeTerminal();
  // A first start: the start event comes before the plugins load. A split before the default pane keeps its focus.
  const first = newCore(terminal);
  first.event({ type: "start" });
  first.commands.run("core:split-right");
  equal(terminal.screen(first)[0], "          │");
  const late = counted();
  createSurface(first, "chat", new AbortController().signal).panes.setDefault(late.create);
  equal(terminal.screen(first)[0], "start 1   │");
  first.commands.run("core:close");
  equal(terminal.screen(first)[0], "start 1");
  // A reload without saved panes: the plugins load before the start event.
  const second = newCore(terminal);
  const early = counted();
  createSurface(second, "chat", new AbortController().signal).panes.setDefault(early.create);
  equal(terminal.screen(second)[0], "");
  second.event({ type: "start" });
  equal(terminal.screen(second)[0], "start 1");
  // A later default pane makes no second start pane.
  const third = createSurface(second, "other", new AbortController().signal);
  equal(early.reasons, ["start"]);
  equal(late.reasons, ["start"]);
  const error = throws(() => third.panes.setDefault(counted().create));
  equal([error instanceof TypeError, (error as Error).message], [true, "plugin chat sets the default pane"]);
});

test("a split and a close of the last pane make new default panes, and a stopping plugin makes none", () => {
  const terminal = fakeTerminal();
  const core = newCore(terminal);
  const chat = new AbortController();
  const tui = createSurface(core, "chat", chat.signal);
  const pane = counted();
  tui.panes.setDefault(pane.create);
  core.event({ type: "start" });
  core.commands.run("core:split-right");
  equal(terminal.screen(core)[0], "start 1   │new 2");
  core.commands.run("core:close");
  core.commands.run("core:close");
  equal(terminal.screen(core)[0], "new 3");
  // The stop closes each pane of the plugin, and the last close gives an empty pane.
  core.commands.run("core:split-down");
  chat.abort();
  equal(terminal.screen(core)[0], "");
  equal(pane.reasons, ["start", "new", "new", "new"]);
  // A default pane of a new plugin follows the stopped one.
  createSurface(core, "next", new AbortController().signal).panes.setDefault(counted().create);
  core.commands.run("core:close");
  equal(terminal.screen(core)[0], "new 1");
});

test("a saved empty pane comes back as a default pane, and a default pane that throws leaves an empty pane", () => {
  const terminal = fakeTerminal();
  const core = newCore(terminal);
  const tui = createSurface(core, "chat", new AbortController().signal);
  const pane = counted();
  tui.panes.setDefault(pane.create);
  core.event({ type: "start", snapshot: JSON.stringify({ tree: null, focus: 0 }) });
  equal([terminal.screen(core)[0], pane.reasons], ["new 1", ["new"]]);
  const other = newCore(terminal);
  createSurface(other, "broken", new AbortController().signal).panes.setDefault(() => {
    throw new Error("no pane");
  });
  other.event({ type: "start" });
  equal(terminal.screen(other)[0], "");
  equal(other.notices.list().at(-1)?.text.split("\n")[0], "a view did not start: Error: no pane");
});
