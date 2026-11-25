// The status items of the core, and the bundled bar that draws them in the last row.

import { assertEquals, assertThrows, createFrame, createHost, test } from "yuke:test";
import type { StatusEntry, View } from "yuke:tui";

/** A main view that draws `text` in its first row. */
function main(text: string): () => View {
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

test("a listener added twice and removed once stays, and a listener that an earlier one removes gets no call", () => {
  using frame = createFrame({ width: 20, height: 2 });
  const tui = frame.surface("demo").tui;
  const calls: string[] = [];
  const twice = (): void => {
    calls.push("twice");
  };
  tui.status.addChangeListener(twice);
  const removeSecond = tui.status.addChangeListener(twice);
  removeSecond();
  let removeLate = (): void => {};
  tui.status.addChangeListener(() => removeLate());
  removeLate = tui.status.addChangeListener(() => {
    calls.push("late");
  });

  tui.status.set("mode", item("NORMAL", "left", 0));

  assertEquals(calls, ["twice"]);
});

test("the bar takes the last row: the left side from the start and the right side to the end", async () => {
  using frame = createFrame({ width: 24, height: 3 });
  frame.surface("main").tui.setMain(main("main"));
  await using _host = await createHost({ frame, plugins: [{ bundled: "bar" }] });
  frame.start();
  const tui = frame.surface("vim").tui;
  tui.status.set("mode", item("NORMAL", "left", 0));
  tui.status.set("model", item("luna", "right", 10));
  tui.status.set("jobs", item("jobs 2", "right", 1));
  frame.draw();
  assertEquals(frame.rows(), ["main", "", "NORMAL     jobs 2 · luna"]);
  // The items are dim, and the bar has no background.
  const last = frame.frame.cells[2] ?? [];
  assertEquals([last[0]?.style, last[7]?.style], [{ dim: true }, {}]);
});

test("a narrow bar drops the lowest priority first, the later item of a tie first, and cuts the last one", async () => {
  using frame = createFrame({ width: 20, height: 2 });
  await using _host = await createHost({ frame, plugins: [{ bundled: "bar" }] });
  const tui = frame.surface("demo").tui;
  tui.status.set("mode", item("NORMAL", "left", 0, 5));
  tui.status.set("jobs", item("jobs 2", "right", 1));
  tui.status.set("model", item("luna high", "right", 10));
  const removeKeys = tui.status.set("keys", item("g", "right", -1, 9));
  frame.draw();
  const row = (): string => frame.rows().at(-1) ?? "";
  const twenty = row();
  frame.resize({ width: 12, height: 2 });
  const twelve = row();
  frame.resize({ width: 6, height: 2 });
  const six = row();
  removeKeys();
  frame.resize({ width: 5, height: 2 });
  assertEquals([twenty, twelve, six, row()], ["NORMAL    g · jobs 2", "NORMAL     g", "     g", "NORM…"]);
});

test("the options hide an item and put named items in their order", async () => {
  using frame = createFrame({ width: 30, height: 2 });
  await using _host = await createHost({
    frame,
    plugins: [{ bundled: "bar", options: { hide: ["demo:jobs"], order: ["demo:model", "demo:keys"] } }],
  });
  const tui = frame.surface("demo").tui;
  tui.status.set("keys", item("g", "right", -1));
  tui.status.set("jobs", item("jobs 2", "right", 1));
  tui.status.set("model", item("luna", "right", 10));
  frame.draw();
  assertEquals(frame.rows().at(-1), "                      luna · g");
});
