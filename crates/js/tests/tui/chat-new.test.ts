// The command `new` of the bundled chat: the pane lets go of its session, shows the empty header, and its next message
// creates a session in the folder of the session before.

import { writeTextFile } from "yuke:fs";
import { assertEquals, createFrame, folder, test, waitForSettled } from "yuke:test";
import type { View } from "yuke:tui";
import { commit, fakeSessions, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

/** Save the pick `p/m` at the level high, so a send needs no picker. */
async function savedPick(): Promise<void> {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    cwd: folder(),
  });
}

/** The status items of `chat` as key and text. */
function items(chat: Awaited<ReturnType<typeof loadChat>>): string[][] {
  return chat.tui.status.list().map((item) => [item.id, item.text]);
}

/** A session in `/w` with one answer, so the bar shows a context item. */
const SAVED = [
  ...replies(1),
  commit(2, [{ kind: "assistantText", text: "old answer" }], {
    answer: {
      origin: { model: "m", baseUrl: "https://p" },
      usage: { input: 3000, output: 200 },
      finishReason: "stop",
    },
  }),
];

test("/new empties the pane, ends the old handle, and shows the header with the saved model and the old folder", async () => {
  await savedPick();
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(SAVED));
  frame.start();
  await waitForSettled();
  const view = chat.tui.panes.active?.view as View;
  const before = items(chat);
  frame.key("/ n e w enter");
  await waitForSettled();
  frame.draw();
  const shown = rows(frame.frame).join("\n");

  assertEquals(
    [
      before,
      items(chat),
      chat.chat.session(view),
      chat.opened.map((open) => [open.id, open.signal.aborted]),
      shown.includes("old answer"),
      shown.includes("m high · /w"),
      chat.notices,
    ],
    [
      [
        ["chat:folder", "/w"],
        ["chat:model", "m default"],
        ["chat:context", "3.2k tokens"],
      ],
      [
        ["chat:folder", "/w"],
        ["chat:model", "m high"],
      ],
      undefined,
      [["s1", true]],
      false,
      true,
      [],
    ],
  );
});

test("the next message after /new creates a session in the folder of the old session", async () => {
  await savedPick();
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(SAVED);
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.key("/ n e w enter");
  frame.key("h i enter");
  await waitForSettled();

  assertEquals(
    [sessions.created.map((settings) => settings.cwd), chat.opened.map((open) => open.id), sessions.inputs],
    [["/w"], ["s1", "s-new"], [[{ kind: "userText", text: "hi" }]]],
  );
});

test("ctrl+k n empties a draft", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(SAVED));
  frame.start();
  await waitForSettled();
  frame.paste("half a thought");
  frame.key("ctrl+k n");
  frame.draw();

  assertEquals(
    [chat.chat.session(chat.tui.panes.active?.view as View), rows(frame.frame).at(-2)],
    [undefined, "Message…"],
  );
});

test("a pane with a session lists /new, and a pane without a session does not", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  await loadChat(frame, fakeSessions(SAVED));
  frame.start();
  await waitForSettled();
  frame.key("/ n e");
  frame.draw();
  const listed = rows(frame.frame).some((text) => text.startsWith(" /new"));
  frame.key("backspace backspace backspace");
  frame.key("ctrl+k n");
  frame.key("/ n e");
  frame.draw();

  assertEquals([listed, rows(frame.frame).some((text) => text.startsWith(" /new"))], [true, false]);
});

test("ctrl+k n during a send keeps the session and its handle", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(SAVED);
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const { promise, resolve } = Promise.withResolvers<void>();
  sessions.state.accept = promise;
  frame.key("h i enter");
  await waitForSettled();
  frame.key("ctrl+k n");
  resolve();
  await waitForSettled();

  assertEquals(
    [chat.chat.session(chat.tui.panes.active?.view as View), chat.opened.map((open) => [open.id, open.signal.aborted])],
    ["s1", [["s1", false]]],
  );
});

test("/new during a turn leaves the turn running and says so", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(SAVED);
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ sessionUpdate: "state", state: "running" });
  frame.key("/ n e w enter");
  await waitForSettled();
  frame.draw();
  const shown = rows(frame.frame).join("\n");

  assertEquals(
    [
      chat.chat.session(chat.tui.panes.active?.view as View),
      sessions.state.cancels,
      chat.notices,
      shown.includes("Type / for commands"),
      shown.includes("esc to interrupt"),
    ],
    [undefined, 0, ["info the work goes on: /sessions shows it"], true, false],
  );
});

test("/new with a running job of a subagent says that the work goes on", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(SAVED);
  sessions.state.jobs = [{ id: "reader", label: "Read the store", state: "running", kind: "plugin", plugin: "agents" }];
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.key("/ n e w enter");
  await waitForSettled();

  assertEquals(chat.notices, ["info the work goes on: /sessions shows it"]);
});

test("a reload after /new keeps the folder of the old session", async () => {
  await savedPick();
  using before = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  await loadChat(before, fakeSessions(SAVED));
  before.start();
  await waitForSettled();
  before.key("/ n e w enter");
  await waitForSettled();
  const snapshot = before.snapshot();
  using after = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start" });
  const sessions = fakeSessions();
  const chat = await loadChat(after, sessions);
  after.start(snapshot);
  await waitForSettled();
  const shown = items(chat).find((item) => item[0] === "chat:folder");
  after.key("h i enter");
  await waitForSettled();

  assertEquals([shown, sessions.created.map((settings) => settings.cwd)], [["chat:folder", "/w"], ["/w"]]);
});

test("a draft that a pane left before /new does not come back after a later return", async () => {
  using frame = createFrame({ width: 80, height: 20 }, undefined, { cwd: "/start", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(SAVED));
  frame.start();
  await waitForSettled();
  frame.paste("a");
  await chat.chat.show("s2");
  frame.key("ctrl+k n");
  frame.paste("b");
  await chat.chat.show("s1");
  frame.key("ctrl+c");
  await chat.chat.show("s2");
  await chat.chat.show("s1");
  frame.draw();

  assertEquals(rows(frame.frame).at(-2), "Message…");
});
