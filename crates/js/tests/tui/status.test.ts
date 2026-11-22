// The status items of the core: their ids, their removers, and the pending keys of a sequence.

import { assertEquals, assertThrows, createFrame, test } from "yuke:test";
import type { StatusEntry } from "yuke:tui";

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
  watcher.tui.status.addChangeListener(() => {
    changes += 1;
  });
  vim.tui.status.set("mode", { ...item("NORMAL", "left", 0), style: ["bar"] });
  vim.tui.status.set("mode", { ...item("NORMAL", "left", 0), style: ["bar"] });
  assertEquals(assertThrows(() => vim.tui.status.set("chat:model", item("m", "right", 0)))?.constructor, TypeError);
  const removeCount = vim.tui.status.set("vim:count", item("3", "left", 1));
  assertEquals(
    watcher.tui.status.list().map((entry) => [entry.id, entry.text, entry.priority]),
    [
      ["vim:mode", "NORMAL", 0],
      ["vim:count", "3", 0],
    ],
  );
  removeCount();
  vim.close();
  assertEquals([watcher.tui.status.list(), changes], [[], 4]);
});

test("the pending keys of a sequence are the item core:keys until the wait ends", () => {
  using frame = createFrame({ width: 20, height: 2 });
  const surface = frame.surface("demo");
  surface.tui.commands.add({ name: "top", run: () => {} });
  surface.tui.keys.add("g g", "top");
  frame.key("g");
  const waiting = surface.tui.status.list().map((entry) => [entry.id, entry.text, entry.side]);
  frame.advance(1000);
  assertEquals([waiting, surface.tui.status.list()], [[["core:keys", "g", "right"]], []]);
});

test("the remover of a set deletes its item, and an older remover leaves a newer entry", () => {
  using frame = createFrame({ width: 24, height: 3 });
  const tui = frame.surface("vim").tui;
  const removeFirst = tui.status.set("mode", item("NORMAL", "left", 0));
  const removeSecond = tui.status.set("mode", item("INSERT", "left", 0));
  removeFirst();
  const afterOld = tui.status.list().map((entry) => entry.text);
  removeSecond();

  assertEquals([afterOld, tui.status.list()], [["INSERT"], []]);
});
