// The operations of the `chat` service on the focused pane: its folder, its next session, the start of its session,
// and the model picker.

import { assertEquals, assertRejects, createFrame, test, waitForSettled } from "yuke:test";
import type { View } from "yuke:tui";
import { composerOf, fakeSessions, loadChat, replies } from "./chat.ts";

test("newSession empties the focused pane and starts the next session in the given folder", async () => {
  using frame = createFrame({ width: 60, height: 12 }, undefined, { cwd: "/start", session: "s1" });
  const sessions = fakeSessions(replies(1));
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const view = chat.tui.panes.active?.view as View;
  const before = chat.chat.folder(view);
  chat.chat.newSession({ cwd: "/elsewhere" });
  const after = [chat.chat.session(view), chat.chat.folder(view)];
  await chat.chat.chooseModel(async () => ({ model: { provider: "p", model: "m" }, reasoning: "high" }));
  frame.paste("hello");
  frame.key("enter");
  await waitForSettled();

  assertEquals(
    [before, after, sessions.created.map((settings) => settings.cwd)],
    ["/w", [undefined, "/elsewhere"], ["/elsewhere"]],
  );
});

test("ensureSession creates the session of the focused pane, sends nothing, and keeps the draft", async () => {
  using frame = createFrame({ width: 60, height: 12 }, undefined, { cwd: "/start" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  chat.chat.setModelPicker(async () => ({ model: { provider: "p", model: "n" }, reasoning: "low" }));
  frame.paste("draft");
  const id = await chat.chat.ensureSession();
  await waitForSettled();

  assertEquals(
    [id, sessions.created.map((settings) => settings.cwd), composerOf(chat).state.text, sessions.inputs.length],
    ["s-new", ["/start"], "draft", 0],
  );
});

test("a picker of one call wins over the picker of setModelPicker, and its remover brings back the lists", async () => {
  using frame = createFrame({ width: 60, height: 12 });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  let calls = 0;
  const stop = chat.chat.setModelPicker(async () => {
    calls += 1;
    return { model: { provider: "p", model: "m" }, reasoning: "high" };
  });
  await chat.chat.chooseModel(async () => ({ model: { provider: "p", model: "n" }, reasoning: "low" }));
  frame.paste("hello");
  frame.key("enter");
  await waitForSettled();
  await chat.chat.chooseModel();
  await waitForSettled();
  stop();
  // The lists of the default picker open, and Esc cancels them.
  const choice = chat.chat.chooseModel();
  await waitForSettled();
  frame.key("esc");
  await choice;

  assertEquals(
    [
      sessions.created.map((settings) => [settings.model.model, settings.settings.reasoning]),
      calls,
      sessions.changes.map((settings) => settings.model.model),
    ],
    [[["n", { effort: "low" }]], 1, ["m"]],
  );
});

test("a choice that no ready provider has keeps the draft, creates no session, and says why", async () => {
  using frame = createFrame({ width: 60, height: 12 });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  frame.paste("keep draft");
  await chat.chat.chooseModel(async () => undefined);
  await chat.chat.chooseModel(async () => ({ model: { provider: "p", model: "missing" }, reasoning: "high" }));

  assertEquals(
    [composerOf(chat).state.text, sessions.created.length, chat.notices],
    ["keep draft", 0, ["error the model did not change: Error: p/missing at high is not ready"]],
  );
});

test("the operations on the focused pane reject when the focused pane is no chat pane", async () => {
  using frame = createFrame({ width: 60, height: 12 });
  const chat = await loadChat(frame);
  chat.tui.panes.split(() => ({ draw() {} }));
  frame.start();

  await assertRejects(() => chat.chat.ensureSession());
  assertEquals(chat.chat.folder(chat.tui.panes.active?.view as View), undefined);
});
