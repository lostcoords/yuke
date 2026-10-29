// The questions of plugins in the bundled chat: the place of the composer and the modal, the keys of each kind, the
// count, a late answer, and two panes on one session.

import type { InteractionRequest, SessionUpdate, StoredEvent } from "yuke:protocol";
import { createFrame, equal, test } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { EMPTY, fakeSessions, loadChat, rows, SETTINGS, settle } from "./chat.ts";

/** The update of the question `id` of the plugin `guard`. */
function asked(id: number, request: InteractionRequest): SessionUpdate {
  return { sessionUpdate: "interaction_requested", interactionId: id, source: "guard", request };
}

/** The composer of the chat in `frame`. */
function composerOf(chat: ReturnType<typeof loadChat>): TextEditor {
  return chat.tui.widgets.list().find((mount) => mount.widget instanceof TextEditor && mount.widget.role === "composer")
    ?.widget as TextEditor;
}

const DELETE: InteractionRequest = { kind: "confirm", title: "Delete branch?", message: "feat/x" };

test("a confirm takes the place of the composer, waits for y or n, and the draft comes back after it", async () => {
  using frame = createFrame({ width: 32, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.paste("draft");
  sessions.push(asked(1, DELETE));
  frame.draw();
  const shown = rows(frame).slice(-3);
  // The composer takes no message while the question shows.
  const off = chat.tui.commands
    .list()
    .filter((command) => ["chat:send", "chat:model", "chat:older-message"].includes(command.name))
    .map((command) => command.enabled);
  frame.key("enter");
  const afterEnter = [...sessions.responses];
  // The second y comes before the close of the question, and it sends nothing.
  frame.key("y y");
  await settle();
  frame.draw();
  equal(
    [
      shown,
      off,
      afterEnter,
      sessions.responses,
      sessions.inputs,
      rows(frame).at(-1),
      chat.tui.focused === composerOf(chat),
    ],
    [
      [" guard · Delete branch?", " feat/x", " y yes · n no · Esc cancel"],
      [false, false, false],
      [],
      [[1, { kind: "confirm", value: true }]],
      [],
      "draft",
      true,
    ],
  );
});

test("a select picks an option, a secret input shows dots, and the count shows the open questions", async () => {
  using frame = createFrame({ width: 32, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  sessions.push(asked(2, { kind: "select", title: "Deploy to?", options: ["staging", "prod"] }));
  sessions.push(asked(3, { kind: "input", title: "API key?", placeholder: null, secret: true }));
  frame.draw();
  const select = rows(frame).slice(-4);
  frame.key("down enter");
  await settle();
  frame.paste("sk-1");
  frame.draw();
  const secret = rows(frame).slice(-2);
  frame.key("enter");
  equal(
    [select, secret, sessions.responses],
    [
      [" guard · Deploy to? · 1 of 2", "", "staging", "prod"],
      [" guard · API key?", "••••"],
      [
        [2, { kind: "select", value: "prod" }],
        [3, { kind: "input", value: "sk-1" }],
      ],
    ],
  );
});

test("Esc and Ctrl+C cancel the question and leave the turn and the draft", async () => {
  using frame = createFrame({ width: 32, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.paste("draft");
  sessions.push(asked(4, DELETE));
  frame.key("esc");
  await settle();
  sessions.push(asked(5, { kind: "input", title: "Name?", placeholder: "a name", secret: false }));
  frame.paste("abc");
  frame.key("ctrl+c");
  await settle();
  frame.draw();
  equal(
    [sessions.responses, sessions.state.cancels, composerOf(chat).state.text],
    [
      [
        [4, { kind: "canceled" }],
        [5, { kind: "canceled" }],
      ],
      0,
      "draft",
    ],
  );
});

test("a late answer gives a notice and the question stays until it closes", async () => {
  using frame = createFrame({ width: 32, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  sessions.state.refuseAnswer = true;
  sessions.push(asked(6, DELETE));
  frame.key("y");
  frame.draw();
  const stays = rows(frame).at(-3);
  sessions.push({ sessionUpdate: "interaction_closed", interactionId: 6 });
  frame.draw();
  equal(
    [chat.notices, stays, rows(frame).at(-1)],
    [["error the answer did not reach the plugin: Error: no open question 6"], " guard · Delete branch?", "Message…"],
  );
});

test("each pane of a session shows its question, the focused pane takes the keys, and tab reaches the transcript", async () => {
  const pane = { type: "chat:pane", state: { session: "s1", draft: EMPTY } };
  const saved = JSON.stringify({ tree: { split: "row", ratio: 0.5, first: pane, second: pane }, focus: 0 });
  using frame = createFrame({ width: 61, height: 6 });
  const sessions = fakeSessions();
  loadChat(frame, {}, sessions);
  frame.start(saved);
  await settle();
  sessions.push(asked(7, DELETE));
  frame.draw();
  const both = rows(frame).at(-3);
  frame.key("tab");
  frame.key("y");
  const fromTranscript = [...sessions.responses];
  frame.key("tab y");
  equal(
    [both, fromTranscript, sessions.responses],
    [` guard · Delete branch?${" ".repeat(7)}│ guard · Delete branch?`, [], [[7, { kind: "confirm", value: true }]]],
  );
});

test("a modal question opens over the focused pane, waits for another modal, and gives the focus back", async () => {
  using frame = createFrame({ width: 32, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, { questions: "modal" }, sessions);
  frame.start();
  await settle();
  frame.paste("draft");
  chat.tui.palette();
  frame.draw();
  sessions.push(asked(8, DELETE));
  frame.draw();
  const waits = rows(frame).some((row) => row.includes("Delete branch?"));
  frame.key("esc");
  frame.draw();
  const opens = rows(frame).slice(-3);
  frame.key("n");
  await settle();
  frame.draw();
  const back = [chat.tui.focused === composerOf(chat), rows(frame).at(-1)];
  // The field of a select in a modal takes the keys.
  sessions.push(asked(9, { kind: "select", title: "Deploy to?", options: ["staging", "prod"] }));
  frame.key("p enter");
  equal(
    [waits, opens, back, sessions.responses],
    [
      false,
      [" guard · Delete branch?", " feat/x", " y yes · n no · Esc cancel"],
      [true, "draft"],
      [
        [8, { kind: "confirm", value: false }],
        [9, { kind: "select", value: "prod" }],
      ],
    ],
  );
});

test("a close of the session by another client drops its question, and the next send opens the session again", async () => {
  using frame = createFrame({ width: 32, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.paste("draft");
  sessions.push(asked(10, DELETE));
  sessions.close("s1");
  frame.draw();
  const shown = rows(frame).at(-1);
  frame.key("enter");
  await settle();
  equal([shown, sessions.opened.length, sessions.inputs], ["draft", 2, [[{ user_text: "draft" }]]]);
});

test("a browse of the messages stops while a question shows", async () => {
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    {
      seq: 2,
      sessionUpdate: "commit",
      commit: { replaced: null, blocks: [{ user_text: "old" }], answer: null, end: null },
      consumed: [{ id: 2, source: { kind: "user" }, kind: "message", blockCount: 1 }],
    },
  ];
  using frame = createFrame({ width: 32, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(saved);
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.key("up");
  const enabled = () => chat.tui.commands.list().find((command) => command.name === "chat:newer-message")?.enabled;
  const browsing = enabled();
  sessions.push(asked(11, DELETE));
  equal([browsing, enabled()], [true, false]);
});
