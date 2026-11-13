// The questions of plugins in the bundled chat: the place of the composer, the keys of the pages, the count, a late
// answer, and two panes on one session.

import type { InteractionRequest, InteractionResponse, Question, SessionUpdate, StoredEvent } from "yuke:protocol";
import { assertEquals, createFrame, test, waitForSettled } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { EMPTY, fakeSessions, loadChat, mouse, SETTINGS } from "./chat.ts";
import { rows } from "./rows.ts";

/** The update of the question `id` of the plugin `guard`. */
function asked(id: number, request: InteractionRequest): SessionUpdate {
  return { sessionUpdate: "interactionRequested", interactionId: id, source: "guard", request };
}

/** The composer of the chat in `frame`. */
function composerOf(chat: Awaited<ReturnType<typeof loadChat>>): TextEditor {
  return chat.tui.widgets.list().find((mount) => mount.widget instanceof TextEditor && mount.widget.role === "composer")
    ?.widget as TextEditor;
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
  using frame = createFrame({ width: 40, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.paste("draft");
  sessions.push(asked(1, DELETE));
  frame.draw();
  const shown = rows(frame.frame).slice(-7, -1);
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
    [shown, off, sessions.responses, sessions.inputs, rows(frame.frame).at(-2), chat.tui.focused === composerOf(chat)],
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
  using frame = createFrame({ width: 40, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push({ ...asked(1, DELETE), source: "host:mcp" } as SessionUpdate);
  frame.draw();

  assertEquals(rows(frame.frame).at(-7), " mcp · Branch");
});

test("a request of several questions shows one page each, with ticks and typed answers, and the last enter sends", async () => {
  using frame = createFrame({ width: 64, height: 20 }, undefined, { cwd: "/w", session: "s1" });
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
    return rows(frame.frame).some((row) => row.includes(text));
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
  using frame = createFrame({ width: 50, height: 14 }, undefined, { cwd: "/w", session: "s1" });
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
    return [rows(frame.frame).at(-6), rows(frame.frame).at(-2)];
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
  using frame = createFrame({ width: 40, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.push(asked(14, one({ options: [{ label: "X" }], other: true })));
  frame.key("down");
  frame.draw();
  // The field row is the row above the hint.
  frame.mouse(mouse(3, 11, "press"));
  frame.mouse(mouse(3, 11, "release"));
  frame.key("up enter");
  assertEquals(sessions.responses, [[14, answered(["X"])]]);
});

test("a tall question keeps its options in view and counts the lines that do not show", async () => {
  using frame = createFrame({ width: 40, height: 15 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const text = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join("\n");
  sessions.push(asked(13, one({ question: text, options: [{ label: "Yes" }, { label: "No" }] })));
  frame.draw();
  assertEquals(rows(frame.frame).slice(-8, -2), [
    " guard · Q",
    " line 1",
    " line 2",
    " … 8 more lines",
    "❯ Yes",
    "  No",
  ]);
});

test("a short pane keeps the first line of a tall question above its options", async () => {
  using frame = createFrame({ width: 40, height: 9 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  const text = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join("\n");
  const options = ["A", "B", "C", "D"].map((label) => ({ label }));
  sessions.push(asked(15, one({ question: text, options })));
  frame.draw();
  assertEquals(rows(frame.frame).slice(-5, -1), [
    " guard · Q",
    " line 1",
    "❯ A",
    " ↑↓ choose · enter send · esc cancel",
  ]);
});

test("Esc and Ctrl+C cancel the question and leave the turn and the draft", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { cwd: "/w", session: "s1" });
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
  using frame = createFrame({ width: 40, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  sessions.state.refuseAnswer = true;
  sessions.push(asked(6, DELETE));
  frame.key("enter");
  frame.draw();
  const stays = rows(frame.frame).at(-7);
  sessions.push({ sessionUpdate: "interactionClosed", interactionId: 6 });
  frame.draw();
  assertEquals(
    [chat.notices, stays, rows(frame.frame).at(-2)],
    [["error the answer did not reach the plugin: Error: no open question 6"], " guard · Branch", "Message…"],
  );
});

test("each pane of a session shows its question, and the focused pane takes the keys", async () => {
  const pane = { type: "chat:pane", state: { session: "s1", draft: EMPTY } };
  const saved = JSON.stringify({ tree: { split: "row", first: pane, second: pane }, focus: 0 });
  using frame = createFrame({ width: 61, height: 6 });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start(saved);
  await waitForSettled();
  sessions.push(asked(7, DELETE));
  frame.draw();
  const both = rows(frame.frame).at(-3);
  frame.key("enter");
  assertEquals(
    [both, sessions.responses],
    [` guard · Branch${" ".repeat(15)}│ guard · Branch`, [[7, answered(["Yes"])]]],
  );
});

test("a close of the session by another client drops its question, and the next send opens the session again", async () => {
  using frame = createFrame({ width: 32, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.paste("draft");
  sessions.push(asked(10, DELETE));
  sessions.close("s1");
  frame.draw();
  const shown = rows(frame.frame).at(-2);
  frame.key("enter");
  await waitForSettled();
  assertEquals([shown, sessions.opened.length, sessions.inputs], ["draft", 2, [[{ kind: "userText", text: "draft" }]]]);
});

test("a browse of the messages stops while a question shows", async () => {
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    {
      seq: 2,
      sessionUpdate: "commit",
      commit: { blocks: [{ kind: "userText", text: "old" }] },
      consumed: [{ id: 2, source: { kind: "user" }, kind: "message", blockCount: 1 }],
    },
  ];
  using frame = createFrame({ width: 32, height: 8 }, undefined, { cwd: "/w", session: "s1" });
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
