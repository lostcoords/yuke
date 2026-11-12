// A read-only session in a chat pane: the row in place of the composer, the keys that stop working, and the way back.

import type { InteractionRequest, SessionUpdate } from "yuke:protocol";
import { createFrame, equal, test, waitForSettled } from "yuke:test";
import { click, fakeSessions, loadChat, replies } from "./chat.ts";
import { rows } from "./rows.ts";

const RULE = "─".repeat(30);

const QUESTION: InteractionRequest = {
  kind: "questions",
  questions: [{ id: "q", header: "Branch", question: "Delete?", options: [{ label: "Yes" }] }],
} as InteractionRequest;

/** A chat pane on the session `s1`, which is read-only with the session `p1` behind it. */
async function opened() {
  const frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(3));
  const chat = await loadChat(frame, sessions);
  const end = chat.chat.addReadOnly((session) =>
    session === "s1" ? { text: "A child session", back: "p1" } : undefined,
  );
  frame.start();
  await waitForSettled();
  frame.draw();
  return { frame, sessions, chat, end };
}

test("a read-only session shows its row with the key back, in place of the composer", async () => {
  const { frame } = await opened();
  using _frame = frame;

  equal(rows(frame.frame).slice(-3), [RULE, "A child session · esc back", RULE]);
});

test("a read-only session takes no message, no recall, no image, and no cancel", async () => {
  const { frame, sessions } = await opened();
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

  equal([sessions.inputs.length, sessions.state.cancels, sessions.state.backgrounds], [0, 0, 0]);
  equal(rows(frame.frame).at(-2), "A child session · esc back");
});

test("a read-only session turns off the commands that change it, and keeps the commands that show it", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;

  const enabled = (name: string) => chat.tui.commands.list().find((command) => command.name === name)?.enabled;

  equal(
    ["model", "send", "clear", "background", "paste-image", "cancel-question", "page-up", "toggle-tools"].map((name) =>
      enabled(`chat:${name}`),
    ),
    [false, false, false, false, false, false, true, true],
  );
});

test("a read-only session shows no question in its pane", async () => {
  const { frame, sessions } = await opened();
  using _frame = frame;

  const update: SessionUpdate = {
    sessionUpdate: "interactionRequested",
    interactionId: 1,
    source: "guard",
    request: QUESTION,
  };
  sessions.push(update);
  await waitForSettled();
  frame.draw();

  equal(rows(frame.frame).at(-2), "A child session · esc back");
  equal(rows(frame.frame).join("\n").includes("Delete?"), false);
});

test("the key back shows the session behind the pane, and the composer gets the focus and the paste", async () => {
  const { frame, sessions, chat } = await opened();
  using _frame = frame;

  frame.key("esc");
  await waitForSettled();
  frame.draw();
  frame.paste("draft");
  frame.draw();

  equal(chat.opened.at(-1)?.id, "p1");
  equal(sessions.state.cancels, 0);
  equal(rows(frame.frame).at(-2), "draft");
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
  await waitForSettled();
  const before = chat.opened.at(-1)?.id;
  frame.key("esc");
  await waitForSettled();

  equal([before, chat.opened.at(-1)?.id], ["s1", "p1"]);
});

test("the key back gives the composer the focus after a press on the transcript", async () => {
  const { frame, chat } = await opened();
  using _frame = frame;

  click(frame, 2, 2);
  frame.key("esc");
  await waitForSettled();
  frame.draw();
  frame.paste("draft");
  frame.draw();

  equal(chat.opened.at(-1)?.id, "p1");
  equal(rows(frame.frame).at(-2), "draft");
});

test("the sources answer in add order, and a disposer removes only its own source", async () => {
  const { frame, chat, end } = await opened();
  using _frame = frame;
  const row = () => rows(frame.draw()).at(-2);
  // A source that gives no answer for this session leaves the next source.
  chat.chat.addReadOnly((session) => (session === "s2" ? { text: "Other", back: "p1" } : undefined));
  const second = chat.chat.addReadOnly(() => ({ text: "Second", back: "p1" }));
  const third = chat.chat.addReadOnly(() => ({ text: "Third", back: "p1" }));
  equal(row(), "A child session · esc back");
  // A later source leaves first, and the first answer stays.
  third();
  equal(row(), "A child session · esc back");
  end();
  equal(row(), "Second · esc back");
  second();
  equal(row(), "Message…");
});
