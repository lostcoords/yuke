// The session tree in the chat: a child of the root shows read-only, with its label and the way back, and a question of
// the root still takes the input row.

import type { InteractionRequest, SessionUpdate } from "yuke:protocol";
import { assertEquals, createFrame, test, waitForSettled } from "yuke:test";
import { composerOf, fakeSessions, loadChat, replies, row } from "./chat.ts";

const QUESTION: InteractionRequest = {
  kind: "questions",
  questions: [{ id: "q", header: "Branch", question: "Delete?", options: [{ label: "Yes" }] }],
} as InteractionRequest;

/** The question `id` of the plugin `guard`. */
const asked = (id: number): SessionUpdate => ({
  kind: "interactionRequested",
  interactionId: id,
  source: "guard",
  request: QUESTION,
});

/** A chat on the root `p1` with the draft `draft`, which shows its child `s1` with a label. */
async function opened() {
  const frame = createFrame({ width: 30, height: 12 }, undefined, { folder: "/w", sessionId: "p1" });
  const sessions = fakeSessions(replies(3));
  sessions.rows.push(row("p1"), row("s1", { parent: "p1" }));
  const chat = await loadChat(frame, sessions);
  const end = chat.chat.addChildLabel((session) => (session === "s1" ? "A subagent" : undefined));
  frame.start();
  await waitForSettled();
  frame.paste("draft");
  // The composer leaves the widgets while the child shows.
  const composer = composerOf(chat);
  await chat.chat.show("s1");
  await waitForSettled();
  frame.draw();
  return { frame, sessions, chat, end, composer };
}

test("a child takes no message, no recall, no image, and no cancel, and the chat keeps the root and its draft", async () => {
  const { frame, sessions, chat, composer } = await opened();
  using _frame = frame;

  frame.paste("typed");
  frame.key("h");
  frame.key("enter");
  frame.key("up");
  frame.key("ctrl+v");
  frame.key("ctrl+c");
  frame.key("ctrl+b");
  await waitForSettled();
  frame.draw();

  assertEquals([sessions.inputs.length, sessions.state.cancels, sessions.state.backgrounds], [0, 0, 0]);
  assertEquals(frame.rows().at(-2), "A subagent · esc back");
  assertEquals(
    chat.opened.map((open) => [open.id, open.signal.aborted]),
    [
      ["p1", false],
      ["s1", false],
    ],
  );
  assertEquals([chat.chat.sessionId(), composer.state.text], ["s1", "draft"]);
});

test("a child turns off the commands that change the root, and keeps the commands that show it", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;

  const enabled = (name: string) => chat.tui.commands.list().find((command) => command.name === name)?.enabled;

  assertEquals(
    ["model", "send", "new", "clear", "background", "paste-image", "cancel-question", "page-up", "toggle-tools"].map(
      (name) => enabled(`chat:${name}`),
    ),
    [false, false, false, false, false, false, false, true, true],
  );
});

test("a question of the root takes the input row while a child shows, and its answer reaches the root", async () => {
  const { frame, sessions } = await opened();
  using _frame = frame;

  sessions.push(asked(1), "p1");
  await waitForSettled();
  frame.draw();
  const shown = frame.rows().join("\n");
  frame.key("enter");
  await waitForSettled();
  frame.draw();

  assertEquals([shown.includes("Delete?"), shown.includes("A subagent")], [true, false]);
  assertEquals(
    sessions.responses.map(([id]) => id),
    [1],
  );
  assertEquals(frame.rows().at(-2), "A subagent · esc back");
});

test("a question of a child shows no question", async () => {
  const { frame, sessions } = await opened();
  using _frame = frame;

  sessions.push(asked(2), "s1");
  await waitForSettled();
  frame.draw();

  assertEquals(frame.rows().at(-2), "A subagent · esc back");
  assertEquals(frame.rows().join("\n").includes("Delete?"), false);
});

test("the key back shows the root again and ends the handle of the child, and the composer gets the focus", async () => {
  const { frame, sessions, chat } = await opened();
  using _frame = frame;

  frame.click(2, 2);
  frame.key("esc");
  await waitForSettled();
  frame.paste(" more");
  frame.draw();

  assertEquals(
    chat.opened.map((open) => [open.id, open.signal.aborted]),
    [
      ["p1", false],
      ["s1", true],
    ],
  );
  assertEquals([sessions.state.cancels, chat.chat.sessionId(), frame.rows().at(-2)], [0, "p1", "draft more"]);
});

test("a selection in the transcript goes first, and the next key goes back", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;
  const view = chat.transcript();
  const item = view.document.items.find((entry) => entry.sections.some((section) => section.text.length > 1));
  const section = item?.sections.find((entry) => entry.text.length > 1)?.id ?? "";
  const place = { item: item?.id ?? "", section };
  view.selection = { anchor: { ...place, offset: 0 }, head: { ...place, offset: 1 } };

  frame.key("esc");
  const before = chat.chat.sessionId();
  frame.key("esc");

  assertEquals([before, chat.chat.sessionId()], ["s1", "p1"]);
});

test("a reload while a child shows saves the root and its draft, with no place and no folds of the child", async () => {
  const frame = createFrame({ width: 30, height: 12 }, undefined, { folder: "/w", sessionId: "p1" });
  using _frame = frame;
  const sessions = fakeSessions(replies(40));
  sessions.rows.push(row("p1"), row("s1", { parent: "p1" }));
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.paste("draft");
  await chat.chat.show("s1");
  await waitForSettled();
  chat.transcript().scroll.scrollTo(0);
  frame.draw();
  const state = JSON.parse(frame.snapshot()).main.state;

  assertEquals(
    [chat.transcript().scroll.state.following, state.session, state.draft.text, state.viewport, state.folds],
    [false, "p1", "draft", undefined, undefined],
  );
});

test("the labels answer in add order, a disposer removes only its own, and a child without a label says so", async () => {
  const { frame, chat, end } = await opened();
  using _frame = frame;
  const shown = () => frame.rows().at(-2);
  // A source that gives no answer for this session leaves the next source.
  chat.chat.addChildLabel((session) => (session === "s2" ? "Other" : undefined));
  const second = chat.chat.addChildLabel(() => "Second");
  const third = chat.chat.addChildLabel(() => "Third");
  assertEquals(shown(), "A subagent · esc back");
  // A later source leaves first, and the first answer stays.
  third();
  assertEquals(shown(), "A subagent · esc back");
  end();
  assertEquals(shown(), "Second · esc back");
  second();
  assertEquals(shown(), "Child session · esc back");
});
