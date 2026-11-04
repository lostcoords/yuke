// The rename command: its dialog, save failure, draft preservation, and disabled unbound pane.

import { apply as applySessions } from "yuke:internal/bundled/sessions";
import type { SessionRow } from "yuke:protocol";
import { createFrame, equal, settled, test } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { fakeSessions, loadChat } from "./chat.ts";
import { rows } from "./rows.ts";

function session(title: string | null): SessionRow {
  return {
    session: {
      sessionId: "s1",
      model: { provider: "p", model: "m" },
      cwd: "/w",
      title,
      createdAt: 0,
      updatedAt: 0,
    },
    activity: "idle",
  };
}

function renameEditor(frame: Awaited<ReturnType<typeof loadChat>>["tui"]): TextEditor {
  return frame.widgets.list().findLast((mount) => mount.widget instanceof TextEditor)?.widget as TextEditor;
}

test("Enter renames the fetched title, keeps the draft, and does not cancel", async () => {
  using frame = createFrame({ width: 50, height: 10 }, undefined, { session: "s1", cwd: "/w" });
  const sessions = fakeSessions();
  sessions.rows.push(session("old title"));
  const chat = await loadChat(frame, sessions);
  frame.start();
  const composer = chat.tui.widgets.list().find((mount) => mount.widget instanceof TextEditor)?.widget as TextEditor;
  composer.paste("draft");
  equal(chat.tui.commands.run("chat:rename"), true);
  await settled();
  frame.draw();
  const editor = renameEditor(chat.tui);
  equal(editor.state.text, "old title");
  editor.replace(0, editor.state.text.length, "new title");
  frame.key("enter");
  await settled();
  frame.draw();

  equal(
    [
      sessions.renames,
      sessions.rows[0]?.session.title,
      composer.state.text,
      sessions.state.cancels,
      rows(frame.frame).some((line) => line.includes("Rename session")),
    ],
    [[["s1", "new title"]], "new title", "draft", 0, false],
  );

  const notices: string[] = [];
  const surface = frame.surface("sessions");
  applySessions({
    get: (name: string) => (name === "tui" ? surface.tui : name === "sessions" ? sessions : chat.chat),
    notify: (_level: string, text: string) => notices.push(text),
  } as never);
  equal(chat.tui.commands.run("sessions:open"), true);
  await settled();
  frame.paste("new title");
  frame.draw();
  equal([rows(frame.frame).some((line) => line.includes("○ new title")), notices], [true, []]);
});

test("a rename failure shows an error and retains the editor", async () => {
  using frame = createFrame({ width: 50, height: 10 }, undefined, { session: "s1", cwd: "/w" });
  const sessions = fakeSessions();
  sessions.rows.push(session("old title"));
  sessions.state.renameFails = true;
  const chat = await loadChat(frame, sessions);
  frame.start();
  chat.tui.commands.run("chat:rename");
  await settled();
  frame.draw();
  const editor = renameEditor(chat.tui);
  equal(editor.state.text, "old title");
  editor.replace(0, editor.state.text.length, "new title");
  frame.key("enter");
  await settled();
  frame.draw();

  equal(
    [editor.state.text, rows(frame.frame).some((line) => line.includes("Error: rename failed")), sessions.renames],
    ["new title", true, []],
  );
  frame.key("esc");
  frame.draw();
  equal(
    rows(frame.frame).some((line) => line.includes("Rename session")),
    false,
  );
});

test("Esc cancels rename, and an unbound pane does not expose the command", async () => {
  using frame = createFrame({ width: 50, height: 10 }, undefined, { cwd: "/w" });
  const chat = await loadChat(frame);
  frame.start();
  equal(chat.tui.commands.run("chat:rename"), false);

  const sessions = fakeSessions();
  sessions.rows.push(session("old title"));
  using bound = createFrame({ width: 50, height: 10 }, undefined, { session: "s1", cwd: "/w" });
  const loaded = await loadChat(bound, sessions);
  bound.start();
  loaded.tui.commands.run("chat:rename");
  await settled();
  bound.key("esc");
  await settled();
  bound.draw();
  equal([sessions.renames, rows(bound.frame).some((line) => line.includes("Rename session"))], [[], false]);
});
