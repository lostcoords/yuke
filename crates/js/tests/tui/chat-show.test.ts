// The service `chat` of the bundled chat: `show` puts another session in a pane, and the draft waits for the return.

import type { ChatService } from "yuke:chat";
import { apply } from "yuke:internal/bundled/chat";
import { createFrame, equal, test } from "yuke:test";
import { TextEditor, type View } from "yuke:tui";
import { commit, fakeSessions, loadChat, replies, rows, settle } from "./chat.ts";

/** The composer of the focused chat pane of `chat`. */
function composerOf(chat: ReturnType<typeof loadChat>): TextEditor {
  const mounts = chat.tui.widgets.list().filter((mount) => mount.widget instanceof TextEditor);
  return mounts.find((mount) => mount.pane?.view === chat.tui.panes.active?.view)?.widget as TextEditor;
}

/** The rejection text of `promise`, or `""` when it resolves. */
async function failure(promise: Promise<void>): Promise<string> {
  try {
    await promise;
    return "";
  } catch (error) {
    return String(error);
  }
}

test("show puts another session in the pane, ends the old handle, and the draft waits for the return", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(2));
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  const view = chat.tui.panes.active?.view as View;
  const moves: (string | undefined)[] = [];
  chat.chat.onChange((moved) => moves.push(chat.chat.session(moved)));
  frame.paste("draft of s1");
  await chat.chat.show("s2");
  sessions.push(commit(3, [{ assistant_text: "only in s2" }]), "s2");
  frame.draw();
  const shown = rows(frame).some((text) => text.includes("only in s2"));
  const away = composerOf(chat).state.text;
  frame.paste("draft of s2");
  await chat.chat.show("s1");
  equal(
    [chat.opened.map((open) => [open.id, open.signal.aborted]), moves, shown, away, composerOf(chat).state.text],
    [
      [
        ["s1", true],
        ["s2", true],
        ["s1", false],
      ],
      ["s2", "s1"],
      true,
      "",
      "draft of s1",
    ],
  );
  equal(chat.chat.session(view), "s1");
});

test("a failed show keeps the session, the handle, and the draft of the pane", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions(replies(2)));
  frame.start();
  await settle();
  frame.paste("keep");
  const error = await failure(chat.chat.show("missing"));
  equal(
    [
      error,
      chat.chat.session(chat.tui.panes.active?.view as View),
      chat.opened.map((open) => [open.id, open.signal.aborted]),
    ],
    [
      "Error: no session missing",
      "s1",
      [
        ["s1", false],
        ["missing", true],
      ],
    ],
  );
  equal(composerOf(chat).state.text, "keep");
});

test("show waits for the end of a send in the pane", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(2));
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  const { promise, resolve } = Promise.withResolvers<void>();
  sessions.state.accept = promise;
  frame.paste("hi");
  frame.key("enter");
  await settle();
  const refused = await failure(chat.chat.show("s2"));
  resolve();
  await settle();
  const later = await failure(chat.chat.show("s2"));
  equal([refused, later, chat.opened.map((open) => open.id)], ["Error: the pane is busy", "", ["s1", "s2"]]);
});

test("show in a pane of another plugin opens a new chat pane, and a pane without a session keeps its draft", async () => {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w" });
  const chat = loadChat(frame, {}, fakeSessions(replies(2)));
  frame.start();
  frame.paste("first words");
  await chat.chat.show("s1");
  const kept = composerOf(chat).state.text;
  frame.surface("other").tui.panes.split(() => ({ draw() {}, focusable: true }));
  await chat.chat.show("s2");
  const active = chat.tui.panes.active?.view as View;
  equal([kept, chat.opened.map((open) => open.id), chat.chat.session(active)], ["first words", ["s1", "s2"], "s2"]);
});

test("a failed show from a pane of another plugin closes the new chat pane again", async () => {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions(replies(2)));
  frame.start();
  const other = frame.surface("other").tui.panes.split(() => ({ draw() {}, focusable: true }));
  const error = await failure(chat.chat.show("missing"));
  equal([error, chat.tui.panes.active?.view === other.view], ["Error: no session missing", true]);
  equal(JSON.parse(frame.snapshot()).tree.split, "row");
});

test("a show of the shown session opens it again after a close by another client", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(2));
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.paste("keep");
  sessions.close("s1");
  await chat.chat.show("s1");
  equal(
    [chat.opened.map((open) => [open.id, open.signal.aborted]), composerOf(chat).state.text],
    [
      [
        ["s1", true],
        ["s1", false],
      ],
      "keep",
    ],
  );
});

test("each pane keeps its own draft of a session that it leaves", async () => {
  using frame = createFrame({ width: 60, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions(replies(2)));
  frame.start();
  await settle();
  frame.paste("left");
  chat.tui.commands.run("core:split-right");
  await chat.chat.show("s1");
  frame.paste("right");
  await chat.chat.show("s2");
  frame.draw();
  chat.tui.commands.run("core:focus-left");
  await chat.chat.show("s2");
  await chat.chat.show("s1");
  const left = composerOf(chat).state.text;
  chat.tui.commands.run("core:focus-right");
  await chat.chat.show("s1");
  equal([left, composerOf(chat).state.text], ["left", "right"]);
});

test("without the terminal interface the service shows no pane", async () => {
  const provided = new Map<string, unknown>();
  apply({
    get: (name: string) => (name === "tui" ? undefined : fakeSessions()),
    provide: (name: string, value: unknown) => provided.set(name, value),
    options: {},
    signal: new AbortController().signal,
    notify() {},
  } as never);
  const service = provided.get("chat") as ChatService;
  const error = await failure(service.show("s1"));
  equal(
    [error, service.session({ draw() {} })],
    ["Error: no chat pane: yuke runs without the terminal interface", undefined],
  );
});
