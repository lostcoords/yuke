import type { PluginApply } from "yuke:plugins";
import { createFrame, createHost, equal, type FrameTest, settled, test } from "yuke:test";
import { stack, TextEditor } from "yuke:tui";
import * as hello from "../guide/examples/hello.js";
import * as lifecycle from "../guide/examples/lifecycle.js";
import * as picker from "../guide/examples/picker.js";
import * as counter from "../guide/examples/plugin.js";
import * as prompt from "../guide/examples/roomy-chat.js";
import * as sidebar from "../guide/examples/sidebar.js";
import * as stopwatch from "../guide/examples/stopwatch.js";
import { withSurface } from "./context.ts";

function loadExample(name: string, apply: PluginApply, frame: FrameTest) {
  return createHost({ plugins: [{ name, apply: (ctx) => apply(withSurface(ctx, frame.surface(name))) }] });
}

test("the first plugin sends its notice from its command and key binding", async () => {
  using frame = createFrame({ width: 40, height: 10 });
  const tui = frame.surface("observer").tui;
  await using host = await loadExample("hello", hello.apply, frame);
  equal(tui.commands.run("hello:hi"), true);
  frame.key("ctrl+g");
  await settled();
  equal(
    host.notices.map((notice) => [notice.source, notice.message]),
    [
      ["hello", "hi from hello"],
      ["hello", "hi from hello"],
    ],
  );
  await host.close();
  equal(tui.commands.run("hello:hi"), false);
});

test("the documented model tool counts words and rejects invalid arguments", async () => {
  await using host = await createHost({ plugins: [{ name: "counter", ...counter }] });
  const session = await host.openSession();
  const words = await session.call("count_words", { text: "  red\n green\tblue  " });
  const empty = await session.call("count_words", { text: "  " });
  const invalid = await session.call("count_words", { text: 7 });
  equal([words.text, empty.text, invalid.isError], ["3", "0", true]);
});

test("the documented event listener reports the session that opens", async () => {
  await using host = await createHost({ plugins: [{ name: "lifecycle", ...lifecycle }] });
  const session = await host.openSession();
  await settled();
  equal(
    host.notices.map((notice) => [notice.source, notice.message]),
    [["lifecycle", `Opened ${session.id}`]],
  );
});

test("the documented picker stores the chosen review focus", async () => {
  using frame = createFrame({ width: 50, height: 12 });
  const tui = frame.surface("observer").tui;
  await using host = await loadExample("picker", picker.apply, frame);
  tui.commands.run("picker:focus");
  frame.draw();
  frame.key("down enter");
  await settled();
  equal(
    tui.status.list().map((item) => [item.key, item.text]),
    [["picker:focus", "Performance"]],
  );
  equal(host.notices, []);
});

test("the documented stopwatch freezes its duration and resets it", async () => {
  using frame = createFrame({ width: 40, height: 10 });
  const tui = frame.surface("observer").tui;
  await using host = await loadExample("clock", stopwatch.apply, frame);
  tui.commands.run("clock:toggle");
  frame.advance(2100);
  const running = tui.status.list().map((item) => item.text);
  tui.commands.run("clock:toggle");
  frame.advance(5000);
  const stopped = tui.status.list().map((item) => item.text);
  tui.commands.run("clock:reset");
  equal([running, stopped, tui.status.list().map((item) => item.text)], [["2s"], ["2s"], ["0s"]]);
  await host.close();
  equal(tui.status.list(), []);
});

test("the documented sidebar keeps pane content and hides on a narrow terminal", async () => {
  using frame = createFrame({ width: 100, height: 10 });
  const tui = frame.surface("observer").tui;
  tui.panes.setDefault(() => ({ draw: (canvas) => canvas.text(0, 0, "Workspace") }));
  await using host = await loadExample("sidebar", sidebar.apply, frame);
  frame.start();
  const wide = frame.frame.cells[0]
    ?.map((cell) => cell.text)
    .join("")
    .trimEnd();
  frame.resize({ width: 70, height: 10 });
  equal(
    [
      wide,
      frame.frame.cells[0]
        ?.map((cell) => cell.text)
        .join("")
        .trimEnd(),
    ],
    [`Workspace${" ".repeat(68)}Shortcuts`, "Workspace"],
  );
  equal(host.notices, []);
});

test("the documented widget extension changes only composer prompts and unload restores them", async () => {
  using frame = createFrame({ width: 30, height: 4 });
  const tui = frame.surface("layout").tui;
  const composer = new TextEditor({ role: "composer", appearance: { prompt: "chat> " } });
  const field = new TextEditor({ appearance: { prompt: "field> " } });
  tui.panes.setDefault(() =>
    stack("column", [
      { view: composer, size: 1 },
      { view: field, size: 1 },
    ]),
  );
  frame.start();
  await using host = await loadExample("prompt", prompt.apply, frame);
  const extended = frame
    .draw()
    .cells.slice(0, 2)
    .map((row) =>
      row
        .map((cell) => cell.text)
        .join("")
        .trimEnd(),
    );
  await host.close();
  equal(
    [
      extended,
      frame
        .draw()
        .cells.slice(0, 2)
        .map((row) =>
          row
            .map((cell) => cell.text)
            .join("")
            .trimEnd(),
        ),
    ],
    [
      [">", "field>"],
      ["chat>", "field>"],
    ],
  );
});
