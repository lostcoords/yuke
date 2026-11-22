// The rename command: its dialog, save failure, draft preservation, and disabled unbound pane.

import { apply as applySessions } from "yuke:internal/bundled/sessions";
import type { SessionRow } from "yuke:protocol";
import { assertEquals, createFrame, test, waitForSettled } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { fakeSessions, loadChat } from "./chat.ts";
import { fakeContext } from "./context.ts";

function session(title: string | undefined): SessionRow {
  return {
    sessionId: "s1",
    model: { provider: "p", model: "m" },
    folder: "/w",
    ...(title === undefined ? {} : { title }),
    createdAt: 0,
    updatedAt: 0,
    state: "idle",
  };
}

function renameEditor(frame: Awaited<ReturnType<typeof loadChat>>["tui"]): TextEditor {
  return frame.widgets.list().findLast((mount) => mount.widget instanceof TextEditor)?.widget as TextEditor;
}

test("Enter renames the fetched title, keeps the draft, and does not cancel", async () => {
  using frame = createFrame({ width: 50, height: 10 }, undefined, { sessionId: "s1", folder: "/w" });
  const sessions = fakeSessions();
  sessions.rows.push(session("old title"));
  const chat = await loadChat(frame, sessions);
  frame.start();
  const composer = chat.tui.widgets.list().find((mount) => mount.widget instanceof TextEditor)?.widget as TextEditor;
  composer.onPaste({ type: "paste", text: "draft" });
  assertEquals(chat.tui.commands.run("chat:rename"), true);
  await waitForSettled();
  frame.draw();
  const editor = renameEditor(chat.tui);
  assertEquals(editor.state.text, "old title");
  editor.replace(0, editor.state.text.length, "new title");
  frame.key("enter");
  await waitForSettled();
  frame.draw();

  assertEquals(
    [
      sessions.renames,
      sessions.rows[0]?.title,
      composer.state.text,
      sessions.state.cancels,
      frame.rows().some((line) => line.includes("Rename session")),
    ],
    [[["s1", "new title"]], "new title", "draft", 0, false],
  );

  const { ctx, notices } = fakeContext({
    name: "sessions",
    services: { tui: frame.surface("sessions").tui, sessions, chat: chat.chat },
  });
  applySessions(ctx);
  assertEquals(chat.tui.commands.run("sessions:open"), true);
  await waitForSettled();
  frame.paste("new title");
  frame.draw();
  assertEquals([frame.rows().some((line) => line.includes("○ new title")), notices], [true, []]);
});

test("a rename failure shows an error and retains the editor", async () => {
  using frame = createFrame({ width: 50, height: 10 }, undefined, { sessionId: "s1", folder: "/w" });
  const sessions = fakeSessions();
  sessions.rows.push(session("old title"));
  sessions.state.renameFails = true;
  const chat = await loadChat(frame, sessions);
  frame.start();
  chat.tui.commands.run("chat:rename");
  await waitForSettled();
  frame.draw();
  const editor = renameEditor(chat.tui);
  assertEquals(editor.state.text, "old title");
  editor.replace(0, editor.state.text.length, "new title");
  frame.key("enter");
  await waitForSettled();
  frame.draw();

  assertEquals(
    [editor.state.text, frame.rows().some((line) => line.includes("rename failed")), sessions.renames],
    ["new title", true, []],
  );
  frame.key("esc");
  frame.draw();
  assertEquals(
    frame.rows().some((line) => line.includes("Rename session")),
    false,
  );
});

test("Esc cancels rename, and an unbound pane does not expose the command", async () => {
  using frame = createFrame({ width: 50, height: 10 }, undefined, { folder: "/w" });
  const chat = await loadChat(frame);
  frame.start();
  assertEquals(chat.tui.commands.run("chat:rename"), false);

  const sessions = fakeSessions();
  sessions.rows.push(session("old title"));
  using bound = createFrame({ width: 50, height: 10 }, undefined, { sessionId: "s1", folder: "/w" });
  const loaded = await loadChat(bound, sessions);
  bound.start();
  loaded.tui.commands.run("chat:rename");
  await waitForSettled();
  bound.key("esc");
  await waitForSettled();
  bound.draw();
  assertEquals([sessions.renames, bound.rows().some((line) => line.includes("Rename session"))], [[], false]);
});
