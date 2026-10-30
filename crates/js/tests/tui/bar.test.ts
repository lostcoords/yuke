// The status items of the core and the bundled bar that draws them in the last row.

import { apply } from "yuke:internal/bundled/bar";
import { createFrame, equal, type FrameTest, test, throws } from "yuke:test";
import type { StatusEntry, View } from "yuke:tui";
import { rows } from "./chat.ts";

/** Load the bar into `frame` with `options`. */
function loadBar(frame: FrameTest, options: { readonly hide?: string[]; readonly order?: string[] } = {}): void {
  const tui = frame.surface("bar").tui;
  apply({ get: (name: string) => (name === "tui" ? tui : undefined), options } as never);
}

/** A pane view that draws `text` in its first row. */
function pane(text: string): () => View {
  return () => ({
    draw: (canvas) => {
      canvas.text(0, 0, text);
    },
  });
}

const item = (text: string, side: "left" | "right", order: number, priority?: number): StatusEntry => ({
  text,
  side,
  order,
  ...(priority === undefined ? {} : { priority }),
});

test("an item gets the prefix of its plugin, a repeat changes nothing, and the stop of the plugin deletes its items", () => {
  using frame = createFrame({ width: 20, height: 2 });
  const vim = frame.surface("vim");
  const watcher = frame.surface("watcher");
  let changes = 0;
  watcher.tui.status.on(() => {
    changes += 1;
  });
  vim.tui.status.set("mode", { ...item("NORMAL", "left", 0), style: ["bar"] });
  vim.tui.status.set("mode", { ...item("NORMAL", "left", 0), style: ["bar"] });
  equal(throws(() => vim.tui.status.set("chat:model", item("m", "right", 0)))?.constructor, TypeError);
  vim.tui.status.set("vim:count", item("3", "left", 1));
  equal(
    watcher.tui.status.list().map((entry) => [entry.key, entry.text, entry.priority]),
    [
      ["vim:mode", "NORMAL", 0],
      ["vim:count", "3", 0],
    ],
  );
  vim.tui.status.delete("count");
  vim.close();
  equal([watcher.tui.status.list(), changes], [[], 4]);
});

test("the pending keys of a sequence are the item core:keys until the wait ends", () => {
  using frame = createFrame({ width: 20, height: 2 });
  const surface = frame.surface("demo");
  surface.tui.commands.add({ name: "top", run: () => {} });
  surface.tui.keys.bind("g g", "top");
  frame.key("g");
  const waiting = surface.tui.status.list().map((entry) => [entry.key, entry.text, entry.side]);
  frame.advance(1000);
  equal([waiting, surface.tui.status.list()], [[["core:keys", "g", "right"]], []]);
});

test("the bar takes the last row: the left side from the start and the right side to the end", () => {
  using frame = createFrame({ width: 24, height: 3 });
  frame.surface("panes").tui.panes.setDefault(pane("pane"));
  loadBar(frame);
  frame.start();
  const tui = frame.surface("vim").tui;
  tui.status.set("mode", item("NORMAL", "left", 0));
  tui.status.set("model", item("luna", "right", 10));
  tui.status.set("jobs", item("jobs 2", "right", 1));
  frame.draw();
  equal(rows(frame), ["pane", "", "NORMAL     jobs 2 · luna"]);
  // The items are dim, and the bar has no background.
  const last = frame.frame.cells[2] ?? [];
  equal([last[0]?.style, last[7]?.style], [{ dim: true }, {}]);
});

test("a narrow bar drops the lowest priority first, the later item of a tie first, and cuts the last one", () => {
  using frame = createFrame({ width: 20, height: 2 });
  loadBar(frame);
  const tui = frame.surface("demo").tui;
  tui.status.set("mode", item("NORMAL", "left", 0, 5));
  tui.status.set("jobs", item("jobs 2", "right", 1));
  tui.status.set("model", item("luna high", "right", 10));
  tui.status.set("keys", item("g", "right", -1, 9));
  frame.draw();
  const row = (): string => rows(frame).at(-1) ?? "";
  const twenty = row();
  frame.resize({ width: 12, height: 2 });
  const twelve = row();
  frame.resize({ width: 6, height: 2 });
  const six = row();
  tui.status.delete("keys");
  frame.resize({ width: 5, height: 2 });
  equal([twenty, twelve, six, row()], ["NORMAL    g · jobs 2", "NORMAL     g", "     g", "NORM…"]);
});

test("the options hide an item and put named items in their order", () => {
  using frame = createFrame({ width: 30, height: 2 });
  loadBar(frame, { hide: ["demo:jobs"], order: ["demo:model", "demo:keys"] });
  const tui = frame.surface("demo").tui;
  tui.status.set("keys", item("g", "right", -1));
  tui.status.set("jobs", item("jobs 2", "right", 1));
  tui.status.set("model", item("luna", "right", 10));
  frame.draw();
  equal(rows(frame).at(-1), "                      luna · g");
});
