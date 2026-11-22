import type { PluginApply } from "yuke:plugins";
import { assertEquals, createFrame, createHost, type FrameTest, test, waitForSettled } from "yuke:test";
import * as hello from "../guide/examples/hello.js";
import * as lifecycle from "../guide/examples/lifecycle.js";
import * as counter from "../guide/examples/plugin.js";

function loadExample(name: string, apply: PluginApply, frame: FrameTest) {
  return createHost({ frame, plugins: [{ name, apply }] });
}

test("the first plugin sends its notice from its command and key binding", async () => {
  using frame = createFrame({ width: 40, height: 10 });
  const tui = frame.surface("observer").tui;
  await using host = await loadExample("hello", hello.apply, frame);
  assertEquals(
    tui.commands.list().filter((command) => command.name === "hello:hi"),
    [{ name: "hello:hi", description: "Say hi", slash: "hi", enabled: true }],
  );
  assertEquals(tui.commands.run("hello:hi"), true);
  frame.key("ctrl+g");
  await waitForSettled();
  assertEquals(
    host.notices.map((notice) => [notice.source, notice.text]),
    [
      ["hello", "hi from hello"],
      ["hello", "hi from hello"],
    ],
  );
  await host.close();
  assertEquals(tui.commands.run("hello:hi"), false);
});

test("the documented model tool counts words and rejects invalid arguments", async () => {
  await using host = await createHost({ plugins: [{ name: "counter", ...counter }] });
  const session = await host.openSession();
  const words = await session.call("count_words", { text: "  red\n green\tblue  " });
  const empty = await session.call("count_words", { text: "  " });
  const invalid = await session.call("count_words", { text: 7 });
  assertEquals([words.text, empty.text, invalid.isError], ["3", "0", true]);
});

test("the documented event listener reports the session that opens", async () => {
  await using host = await createHost({ plugins: [{ name: "lifecycle", ...lifecycle }] });
  const session = await host.openSession();
  await waitForSettled();
  assertEquals(
    host.notices.map((notice) => [notice.source, notice.text]),
    [["lifecycle", `Opened ${session.id}`]],
  );
});
