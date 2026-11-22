// The bundled bar, which draws the status items of the core in the last row.

import { assertEquals, createFrame, createHost, test } from "yuke:test";
import type { StatusEntry, View } from "yuke:tui";

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

test("the bar takes the last row: the left side from the start and the right side to the end", async () => {
  using frame = createFrame({ width: 24, height: 3 });
  frame.surface("panes").tui.panes.setDefault(pane("pane"));
  await using _host = await createHost({ frame, plugins: [{ bundled: "bar" }] });
  frame.start();
  const tui = frame.surface("vim").tui;
  tui.status.set("mode", item("NORMAL", "left", 0));
  tui.status.set("model", item("luna", "right", 10));
  tui.status.set("jobs", item("jobs 2", "right", 1));
  frame.draw();
  assertEquals(frame.rows(), ["pane", "", "NORMAL     jobs 2 · luna"]);
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
