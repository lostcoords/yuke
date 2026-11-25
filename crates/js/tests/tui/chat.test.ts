// The bundled chat in a frame: the main view, its draft and session handle, a reload, and a drag over the transcript.

import type { StoredEvent } from "yuke:protocol";
import { assert, assertEquals, createFrame, test, waitForSettled } from "yuke:test";
import { commit, EMPTY, fakeSessions, loadChat, replies, SETTINGS, transcriptRows } from "./chat.ts";

test("a reload keeps the draft", async () => {
  using before = createFrame({ width: 21, height: 4 });
  await loadChat(before);
  before.start();
  before.paste("a");
  const snapshot = before.snapshot();
  using after = createFrame({ width: 21, height: 4 });
  await loadChat(after);
  after.start(snapshot);
  after.paste("b");
  assertEquals(after.rows().at(-2), "ab");
});

test("a drag over the transcript copies at the release, and the composer keeps the focus", async () => {
  using frame = createFrame({ width: 10, height: 6 }, undefined, { folder: "/w", sessionId: "s1" });
  const chat = await loadChat(frame, fakeSessions([commit(2, [{ kind: "assistantText", text: "hello" }])]));
  frame.start();
  // Row 0 is the gap before the reply, and column 0 is its indent.
  frame.drag({ column: 1, row: 1 }, { column: 5, row: 1 });
  frame.paste("x");
  frame.draw();
  assertEquals(
    [frame.copies, chat.tui.focusedView === chat.transcript(), frame.rows().at(-2)],
    [["hello"], false, "x"],
  );
});

test("the chat starts on the session of the startup, and a reload keeps its session", async () => {
  using frame = createFrame({ width: 21, height: 4 }, undefined, { folder: "/work", sessionId: "s1" });
  const chat = await loadChat(frame);
  frame.start();
  const snapshot = frame.snapshot();
  using after = createFrame({ width: 21, height: 4 }, undefined, { folder: "/work", sessionId: "s2" });
  const restored = await loadChat(after);
  after.start(snapshot);
  assertEquals([chat.opened.map((open) => open.id), restored.opened.map((open) => open.id)], [["s1"], ["s1"]]);
  assertEquals(JSON.parse(snapshot).main, { owner: "chat", state: { session: "s1", draft: EMPTY, folds: [] } });
});

test("a saved session that does not open gives one notice, and the chat keeps it for the next reload", async () => {
  using frame = createFrame({ width: 21, height: 4 });
  const chat = await loadChat(frame);
  frame.start(JSON.stringify({ main: { owner: "chat", state: { session: "missing", draft: EMPTY } } }));
  await waitForSettled();
  assertEquals(chat.notices, ["error The session missing did not open: Error: no session missing"]);
  assertEquals(JSON.parse(frame.snapshot()).main.state.session, "missing");
});

test("each kind of entry draws its rows, and a click on a thought opens it", async () => {
  const user = { kind: "user" } as const;
  const saved: StoredEvent[] = [
    { seq: 1, kind: "settings", ...SETTINGS },
    {
      seq: 2,
      kind: "commit",
      commit: {
        blocks: [
          { kind: "userText", text: "fix the test" },
          { kind: "reasoning", text: "the test expects 3" } as never,
          { kind: "assistantText", text: "**Found** it" },
          { kind: "toolCall", callId: "c1", name: "exec", arguments: "{}" },
        ],
      },
      consumed: [{ id: 1, source: user, kind: "message", blockCount: 1 }],
    },
    {
      seq: 3,
      kind: "commit",
      commit: {
        blocks: [
          { kind: "userText", text: "build done" },
          { kind: "toolResult", callId: "c1", content: "ok", isError: false },
        ],
        end: { kind: "failed", error: "boom" },
      },
      consumed: [{ id: 2, source: { kind: "plugin", name: "ci" }, kind: "notification", blockCount: 1 }],
    },
    {
      seq: 4,
      kind: "commit",
      commit: { replaced: { head: [], keep: 0 }, blocks: [], end: { kind: "stopped" } },
      consumed: [],
    },
  ];
  using frame = createFrame({ width: 30, height: 24 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(saved);
  await loadChat(frame, sessions);
  frame.start();
  sessions.push({ kind: "retryScheduled", afterMs: 2500, error: "overloaded" });
  frame.draw();
  const before = transcriptRows(frame);
  // The blank rows between the entries are a layout choice, so the test reads only the rows with text.
  const texts = (all: readonly string[]) => all.filter((text) => text.trim() !== "");
  assertEquals(texts(before.slice(0, 21)), [
    " fix the test",
    " Thought",
    " Found it",
    " exec",
    " ok",
    " Notification · ci",
    " build done",
    " Failed: boom",
    " Context replaced",
    " Stopped",
    " Retrying in 3s: overloaded",
  ]);
  frame.click(2, 3);
  assertEquals(
    [before.includes(" the test expects 3"), transcriptRows(frame).includes(" the test expects 3")],
    [false, true],
  );
  frame.click(2, 3);
  assertEquals(transcriptRows(frame), before);
});

test("a refusal and a failed round have a label before their text", async () => {
  const answer = { origin: { model: "m", baseUrl: "https://p" }, usage: {}, finishReason: "refusal" } as const;
  const saved = [
    { seq: 1, kind: "settings", ...SETTINGS } as const,
    commit(2, [{ kind: "assistantText", text: "no" }], { answer }),
  ];
  using frame = createFrame({ width: 30, height: 8 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(saved);
  await loadChat(frame, sessions);
  frame.start();
  sessions.push({ kind: "roundFailed", error: "denied" });
  frame.draw();

  assertEquals(
    transcriptRows(frame).filter((text) => text.trim() !== ""),
    [" Refused", " no", " Round failed: denied"],
  );
});

test("a hidden note draws no row, and an interrupted turn tells the user what to do", async () => {
  const note =
    '<system_notification plugin="host:session">The user cancelled the previous turn before it ended.</system_notification>';
  const saved: StoredEvent[] = [
    { seq: 1, kind: "settings", ...SETTINGS },
    {
      seq: 2,
      kind: "commit",
      commit: { blocks: [{ kind: "userText", text: "one" }], end: { kind: "cancelled" } },
      consumed: [{ id: 1, source: { kind: "user" }, kind: "message", blockCount: 1 }],
    },
    {
      seq: 3,
      kind: "commit",
      commit: {
        blocks: [
          { kind: "userText", text: "two" },
          { kind: "userText", text: note },
          { kind: "assistantText", text: "done" },
        ],
        end: { kind: "completed", finishReason: "stop" },
      },
      consumed: [
        { id: 2, source: { kind: "user" }, kind: "message", blockCount: 1 },
        {
          id: 3,
          source: { kind: "plugin", name: "host:session" },
          kind: "notification",
          displayContent: [],
          blockCount: 1,
        },
      ],
    },
  ];
  using frame = createFrame({ width: 60, height: 12 }, undefined, { folder: "/w", sessionId: "s1" });
  await loadChat(frame, fakeSessions(saved));
  frame.start();

  assertEquals(
    transcriptRows(frame).filter((text) => text.trim() !== ""),
    [" one", " Interrupted · tell yuke what to do instead", " two", " done"],
  );
});

test("the top loads older pages, keeps the shown rows, and stops at the first event", async () => {
  using frame = createFrame({ width: 20, height: 8 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(replies(250));
  const chat = await loadChat(frame, sessions);
  frame.start();
  assertEquals(transcriptRows(frame).slice(-2), [" reply 250", ""]);
  for (let visit = 0; visit < 3; visit += 1) {
    chat.transcript().scroll.scrollTo(0);
    frame.draw();
    const shown = transcriptRows(frame);
    await waitForSettled();
    frame.draw();
    // A prepend keeps the item at the top and its row.
    assertEquals(transcriptRows(frame), shown);
  }
  // A live event while the view shows the top asks for no page past the first event.
  const loaded = sessions.pages.length;
  sessions.push(commit(251, [{ kind: "assistantText", text: "reply 251" }]));
  frame.draw();
  await waitForSettled();
  assertEquals(sessions.pages.length, loaded);
  const starts = sessions.pages.map((page) => page.before);
  // Each page asks for events before the page that came before it.
  assert(starts.every((start, at) => at === 0 || (start ?? 0) < (starts[at - 1] ?? 0)));
  assertEquals(chat.transcript().document.items[0]?.id, "2:0");
});

test("a failed page shows its error below the transcript and loads no more pages", async () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(replies(250));
  sessions.state.failing = true;
  const chat = await loadChat(frame, sessions);
  frame.start();
  for (let visit = 0; visit < 2; visit += 1) {
    chat.transcript().scroll.scrollTo(0);
    frame.draw();
    await waitForSettled();
  }
  sessions.push(commit(251, [{ kind: "assistantText", text: "reply 251" }]));
  chat.transcript().scroll.scrollTo(0);
  frame.draw();
  await waitForSettled();
  frame.draw();
  assertEquals(frame.rows().at(-4), " the history did not load: Error: disk");
  assertEquals(sessions.pages.length, 1);
});

test("output below a scrolled transcript shows the hint, and the bottom follows the tail again", async () => {
  using frame = createFrame({ width: 20, height: 8 }, undefined, { folder: "/w", sessionId: "s1" });
  const sessions = fakeSessions(replies(30));
  const chat = await loadChat(frame, sessions);
  frame.start();
  chat.transcript().scroll.scrollBy(-4);
  sessions.push(commit(31, [{ kind: "assistantText", text: "reply 31" }]));
  frame.draw();
  assertEquals(frame.rows().at(-4), " new output ↓");
  chat.transcript().scroll.followTail();
  frame.draw();
  assertEquals(frame.rows().at(-4), "");
  sessions.push(commit(32, [{ kind: "assistantText", text: "reply 32" }]));
  frame.draw();
  assertEquals(transcriptRows(frame).slice(-2), [" reply 32", ""]);
});

test("a reload keeps the folds and the scrolled place of a chat", async () => {
  const saved = replies(40);
  saved[1] = commit(2, [{ kind: "reasoning", text: "deep" } as never, { kind: "assistantText", text: "ok" }]);
  using before = createFrame({ width: 20, height: 8 }, undefined, { folder: "/w", sessionId: "s1" });
  const chat = await loadChat(before, fakeSessions(saved));
  before.start();
  chat.transcript().scroll.scrollTo(0);
  before.draw();
  before.click(2, 1);
  chat.transcript().scroll.scrollBy(1);
  before.draw();
  const shown = transcriptRows(before);
  assertEquals(shown.slice(0, 2), [" Thought", " deep"]);
  using after = createFrame({ width: 20, height: 8 }, undefined, { folder: "/w", sessionId: "s1" });
  await loadChat(after, fakeSessions(saved));
  after.start(before.snapshot());
  after.draw();
  await waitForSettled();
  after.draw();
  assertEquals(transcriptRows(after), shown);
});

test("a live event after a gap loads the missing events, and an unchanged entry keeps its item", async () => {
  using frame = createFrame({ width: 20, height: 10 }, undefined, { folder: "/w", sessionId: "s1" });
  const saved = replies(10);
  const sessions = fakeSessions(saved);
  const chat = await loadChat(frame, sessions);
  frame.start();
  const first = chat.transcript().document.items[0];
  // The event 11 is saved, but the handle gets only the event 12.
  saved.push(commit(11, [{ kind: "assistantText", text: "reply 11" }]));
  sessions.push(commit(12, [{ kind: "assistantText", text: "reply 12" }]));
  frame.draw();
  await waitForSettled();
  frame.draw();
  assertEquals(sessions.pages, [{ before: 12, limit: 1 }]);
  assertEquals(
    chat
      .transcript()
      .document.items.slice(-3)
      .map((item) => item.id),
    ["10:0", "11:0", "12:0"],
  );
  assertEquals(chat.transcript().document.items[0] === first, true);
});

test("a notification from yuke shows its source without host:, and a plugin keeps its whole name", async () => {
  const notification = (seq: number, id: number, name: string, text: string): StoredEvent => ({
    seq,
    kind: "commit",
    commit: { blocks: [{ kind: "userText", text: text }] },
    consumed: [{ id, source: { kind: "plugin", name }, kind: "notification", blockCount: 1 }],
  });
  const saved: StoredEvent[] = [
    { seq: 1, kind: "settings", ...SETTINGS },
    notification(2, 1, "host:jobs", "make · exited 0"),
    notification(3, 2, "myhost:ci", "build done"),
  ];
  using frame = createFrame({ width: 40, height: 12 }, undefined, { folder: "/w", sessionId: "s1" });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  frame.draw();

  assertEquals(transcriptRows(frame).slice(1, 6), [
    " Notification · jobs",
    " make · exited 0",
    "",
    " Notification · myhost:ci",
    " build done",
  ]);
});
