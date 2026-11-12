// The pane watchers of the `chat` service: each chat pane, now and later, with its composer, until it closes.

import { createFrame, equal, test, waitForSettled } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { loadChat } from "./chat.ts";

test("a pane watcher sees each chat pane now and later, and a close or its remover aborts its signal", async () => {
  using frame = createFrame({ width: 40, height: 12 });
  const chat = await loadChat(frame);
  frame.start();
  await waitForSettled();
  const seen: { readonly composer: boolean; readonly signal: AbortSignal }[] = [];
  const remove = chat.chat.addPaneWatcher((pane, signal) => {
    seen.push({ composer: pane.composer instanceof TextEditor && pane.composer.role === "composer", signal });
  });
  chat.tui.commands.run("core:split-right");
  frame.draw();
  const watched = seen.length;
  chat.tui.commands.run("core:close");
  frame.draw();
  const afterClose = seen.map((entry) => entry.signal.aborted);
  remove();
  chat.tui.commands.run("core:split-right");
  frame.draw();

  equal(
    [watched, seen.map((entry) => entry.composer), afterClose, seen.length, seen[0]?.signal.aborted],
    [2, [true, true], [false, true], 2, true],
  );
});

test("a pane watcher that throws gives a notice, and the pane still opens", async () => {
  using frame = createFrame({ width: 40, height: 12 });
  const chat = await loadChat(frame);
  frame.start();
  await waitForSettled();
  chat.chat.addPaneWatcher(() => {
    throw new Error("boom");
  });
  chat.tui.commands.run("core:split-right");
  frame.draw();

  equal(
    [
      chat.notices.filter((notice) => notice.includes("boom")).map((notice) => notice.split("\n")[0]),
      chat.tui.panes.active?.view !== undefined,
    ],
    [["error a pane watcher failed: Error: boom", "error a pane watcher failed: Error: boom"], true],
  );
});
