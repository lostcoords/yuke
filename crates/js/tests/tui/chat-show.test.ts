// The service `chat` of the bundled chat: `show` makes another session the root, or shows a child of the root.

import type { ChatService } from "yuke:chat";
import { apply } from "yuke:internal/bundled/chat";
import { assertEquals, assertRejects, createFrame, test, waitForSettled } from "yuke:test";
import { commit, composerOf, fakeSessions, loadChat, replies, row } from "./chat.ts";
import { fakeContext } from "./context.ts";

test("a show of another root ends the old handle, closes the old root, clears the draft, and tells each listener", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(replies(2));
  sessions.rows.push(row("s1"), row("s2"));
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const moves: (string | undefined)[] = [];
  chat.chat.addChangeListener(() => moves.push(chat.chat.sessionId()));
  frame.paste("draft of s1");
  await chat.chat.show("s2");
  sessions.push(commit(3, [{ kind: "assistantText", text: "only in s2" }]), "s2");
  frame.draw();
  assertEquals(
    [
      chat.opened.map((open) => [open.id, open.signal.aborted]),
      sessions.closes,
      moves,
      frame.rows().some((text) => text.includes("only in s2")),
      composerOf(chat).state.text,
    ],
    [
      [
        ["s1", true],
        ["s2", false],
      ],
      ["s1"],
      ["s2"],
      true,
      "",
    ],
  );
});

test("a failed show keeps the root, its handle, and the draft", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(replies(2));
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.paste("keep");
  const error = String(await assertRejects(() => chat.chat.show("missing")));
  assertEquals(
    [
      error,
      chat.chat.sessionId(),
      chat.opened.map((open) => [open.id, open.signal.aborted]),
      sessions.closes,
      composerOf(chat).state.text,
    ],
    ["Error: no session missing", "s1", [["s1", false]], [], "keep"],
  );
});

test("show rejects during a send and succeeds after the send ends", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(replies(2));
  sessions.rows.push(row("s2"));
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const { promise, resolve } = Promise.withResolvers<void>();
  sessions.state.accept = promise;
  frame.paste("hi");
  frame.key("enter");
  await waitForSettled();
  const refused = String(await assertRejects(() => chat.chat.show("s2")));
  resolve();
  await waitForSettled();
  await chat.chat.show("s2");
  assertEquals([refused, chat.opened.map((open) => open.id)], ["Error: the chat is busy", ["s1", "s2"]]);
});

test("show carries the draft of a chat without a session, and rejects while another plugin shows the main view", async () => {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { folder: "/w" });
  const chat = await loadChat(frame, fakeSessions(replies(2)));
  frame.start();
  frame.paste("first words");
  await chat.chat.show("s1");
  const kept = composerOf(chat).state.text;
  frame.surface("other").tui.setMain(() => ({ draw() {} }));
  const error = String(await assertRejects(() => chat.chat.show("s2")));
  assertEquals(
    [kept, error, chat.opened.map((open) => open.id), chat.chat.sessionId()],
    ["first words", "Error: no chat: another plugin shows the main view", ["s1"], undefined],
  );
});

test("a show of the shown session opens it again after a close by another client", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(replies(2));
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.paste("keep");
  sessions.close("s1");
  await chat.chat.show("s1");
  assertEquals(
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

test("without the terminal interface the service shows no chat", async () => {
  const { ctx, provided } = fakeContext({ name: "chat", services: { sessions: fakeSessions() } });
  await apply(ctx);
  const service = provided.get("chat") as ChatService;
  const error = String(await assertRejects(() => service.show("s1")));
  assertEquals([error, service.sessionId()], ["Error: no chat: yuke runs without the terminal interface", undefined]);
});
