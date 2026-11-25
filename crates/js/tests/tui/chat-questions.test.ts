// The questions of plugins in the bundled chat: the place of the composer, the keys of the pages, the count, and a late
// answer.

import type { InteractionRequest, InteractionResponse, Question, SessionUpdate, StoredEvent } from "yuke:protocol";
import { assertEquals, createFrame, test, waitForSettled } from "yuke:test";
import { composerOf, fakeSessions, loadChat, SETTINGS } from "./chat.ts";

/** The update of the question `id` of the plugin `guard`. */
function asked(id: number, request: InteractionRequest): SessionUpdate {
  return { kind: "interactionRequested", interactionId: id, source: "guard", request };
}

/** A request of one question with `options`. */
function one(question: Partial<Question> & { readonly options: Question["options"] }): InteractionRequest {
  return { kind: "questions", questions: [{ id: "q", header: "Q", question: "Q?", ...question }] };
}

/** The answer of the user to the question `q`. */
function answered(values: string[], other?: string): InteractionResponse {
  return { kind: "questions", answers: [{ id: "q", values, ...(other === undefined ? {} : { other }) }] };
}

const DELETE = one({
  header: "Branch",
  question: "Delete branch?\nfeat/x",
  options: [{ label: "Yes" }, { label: "No" }],
});

test("a single question takes the place of the composer, enter picks the cursor option, and the draft comes back", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.paste("draft");
  sessions.push(asked(1, DELETE));
  frame.draw();
  const shown = frame.rows().slice(-7, -1);
  // The composer takes no message while the question shows.
  const off = chat.tui.commands
    .list()
    .filter((command) => ["chat:send", "chat:model", "chat:older-message"].includes(command.name))
    .map((command) => command.enabled);
  // The second enter comes before the close of the question, and it sends nothing.
  frame.key("down enter enter");
  await waitForSettled();
  frame.draw();
  assertEquals(
    [shown, off, sessions.responses, sessions.inputs, frame.rows().at(-2), chat.tui.focusedView === composerOf(chat)],
    [
      [" guard · Branch", " Delete branch?", " feat/x", "❯ Yes", "  No", " ↑↓ choose · enter send · esc cancel"],
      [false, false, false],
      [[1, answered(["No"])]],
      [],
      "draft",
      true,
    ],
  );
});

test("a question from yuke shows its source without host:", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ ...asked(1, DELETE), source: "host:mcp" } as SessionUpdate);
  frame.draw();

  assertEquals(frame.rows().at(-7), " mcp · Branch");
});

test("a request of several questions shows one page each, with ticks and typed answers, and the last enter sends", async () => {
  using frame = createFrame({ width: 64, height: 20 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const request: InteractionRequest = {
    kind: "questions",
    questions: [
      {
        id: "db",
        header: "Database",
        question: "Which database?",
        options: [{ label: "SQLite", description: "embedded" }, { label: "Postgres" }],
        multiple: true,
        other: true,
      },
      { id: "token", header: "Token", question: "API token?", options: [], other: true, secret: true },
      { id: "go", header: "Go", question: "Go on?", options: [{ label: "Yes" }, { label: "No" }] },
    ],
  };
  sessions.push(asked(2, request));
  sessions.push(asked(3, DELETE));
  /** Whether a row of the drawn frame holds `text`. */
  const shows = (text: string) => {
    frame.draw();
    return frame.rows().some((row) => row.includes(text));
  };
  const first = shows("· 1/3");
  // Enter without a tick or a text keeps the page.
  frame.key("enter space down down");
  frame.paste("with pgvector");
  frame.key("enter");
  frame.paste("sk-1");
  const secret = [shows("· 2/3"), shows("••••"), shows("sk-1")];
  frame.key("enter");
  const last = shows("· 3/3");
  frame.key("enter");
  assertEquals(
    [first, secret, last, sessions.responses],
    [
      true,
      [true, true, false],
      true,
      [
        [
          2,
          {
            kind: "questions",
            answers: [
              { id: "db", values: ["SQLite"], other: "with pgvector" },
              { id: "token", values: [], other: "sk-1" },
              { id: "go", values: ["Yes"] },
            ],
          },
        ],
      ],
    ],
  );
});

test("shift+tab or left goes back, and enter answers the page again", async () => {
  using frame = createFrame({ width: 50, height: 14 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const questions: Question[] = [
    { id: "a", header: "a", question: "a?", options: [{ label: "X" }, { label: "Y" }] },
    { id: "b", header: "b", question: "b?", options: [], other: true },
  ];
  sessions.push(asked(12, { kind: "questions", questions }));
  const shown = (): (string | undefined)[] => {
    frame.draw();
    return [frame.rows().at(-6), frame.rows().at(-2)];
  };
  frame.key("enter");
  frame.paste("hi");
  // The field takes Left, so Shift+Tab goes back from it.
  const field = shown();
  frame.key("shift+tab");
  const back = shown();
  // Space does nothing without `multiple`.
  frame.key("space down enter left right");
  const again = shown();
  frame.key("enter");
  assertEquals(
    [field, back, again, sessions.responses],
    [
      [" guard · b · 2/2", " enter send · shift+tab back · esc cancel"],
      [" guard · a · 1/2", " ↑↓ choose · enter next · esc cancel"],
      [" guard · b · 2/2", " enter send · shift+tab back · esc cancel"],
      [
        [
          12,
          {
            kind: "questions",
            answers: [
              { id: "a", values: ["Y"] },
              { id: "b", values: [], other: "hi" },
            ],
          },
        ],
      ],
    ],
  );
});

test("a press on the field row keeps the page keys with the question", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push(asked(14, one({ options: [{ label: "X" }], other: true })));
  frame.key("down");
  frame.draw();
  // The field row is the row above the hint.
  frame.click(3, 11);
  frame.key("up enter");
  assertEquals(sessions.responses, [[14, answered(["X"])]]);
});

test("a tall question keeps its options in view and counts the lines that do not show", async () => {
  using frame = createFrame({ width: 40, height: 15 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const text = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join("\n");
  sessions.push(asked(13, one({ question: text, options: [{ label: "Yes" }, { label: "No" }] })));
  frame.draw();
  assertEquals(frame.rows().slice(-8, -2), [" guard · Q", " line 1", " line 2", " … 8 more lines", "❯ Yes", "  No"]);
});

test("a short chat keeps the first line of a tall question above its options", async () => {
  using frame = createFrame({ width: 40, height: 9 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const text = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join("\n");
  const options = ["A", "B", "C", "D"].map((label) => ({ label }));
  sessions.push(asked(15, one({ question: text, options })));
  frame.draw();
  assertEquals(frame.rows().slice(-5, -1), [" guard · Q", " line 1", "❯ A", " ↑↓ choose · enter send · esc cancel"]);
});

test("Esc and Ctrl+C cancel the question and leave the turn and the draft", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.paste("draft");
  sessions.push(asked(4, DELETE));
  frame.key("esc");
  await waitForSettled();
  sessions.push(asked(5, one({ header: "Name", question: "Name?", options: [], other: true })));
  frame.paste("abc");
  frame.key("ctrl+c");
  await waitForSettled();
  frame.draw();
  assertEquals(
    [sessions.responses, sessions.state.cancels, composerOf(chat).state.text],
    [
      [
        [4, { kind: "cancelled" }],
        [5, { kind: "cancelled" }],
      ],
      0,
      "draft",
    ],
  );
});

test("a late answer gives a notice and the question stays until it closes", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.state.refuseAnswer = true;
  sessions.push(asked(6, DELETE));
  frame.key("enter");
  frame.draw();
  const stays = frame.rows().at(-7);
  sessions.push({ kind: "interactionClosed", interactionId: 6 });
  frame.draw();
  assertEquals(
    [chat.notices, stays, frame.rows().at(-2)],
    [["error The answer did not reach the plugin: Error: no open question 6"], " guard · Branch", "Message…"],
  );
});

test("a close of the session by another client drops its question, and the next send opens the session again", async () => {
  using frame = createFrame({ width: 32, height: 8 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.paste("draft");
  sessions.push(asked(10, DELETE));
  sessions.close("s1");
  frame.draw();
  const shown = frame.rows().at(-2);
  frame.key("enter");
  await waitForSettled();
  assertEquals([shown, sessions.opened.length, sessions.inputs], ["draft", 2, [[{ kind: "userText", text: "draft" }]]]);
});

test("a browse of the messages stops while a question shows", async () => {
  const saved: StoredEvent[] = [
    { seq: 1, kind: "settings", ...SETTINGS },
    {
      seq: 2,
      kind: "commit",
      commit: { blocks: [{ kind: "userText", text: "old" }] },
      consumed: [{ id: 2, source: { kind: "user" }, kind: "message", blockCount: 1 }],
    },
  ];
  using frame = createFrame({ width: 32, height: 8 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(saved);
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.key("up");
  const enabled = () => chat.tui.commands.list().find((command) => command.name === "chat:newer-message")?.enabled;
  const browsing = enabled();
  sessions.push(asked(11, DELETE));
  assertEquals([browsing, enabled()], [true, false]);
});
