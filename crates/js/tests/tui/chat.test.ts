// The bundled chat pane in a frame: the default pane of each split, its own draft and session handle, a reload, and a
// drag over the transcript.

import type { StoredEvent } from "yuke:protocol";
import { createFrame, equal, settled, test } from "yuke:test";
import { click, commit, EMPTY, fakeSessions, loadChat, mouse, replies, SETTINGS, transcriptRows } from "./chat.ts";
import { rows } from "./rows.ts";

test("a split opens a new empty chat with its own draft", async () => {
  using frame = createFrame({ width: 21, height: 4 });
  const chat = await loadChat(frame);
  frame.start();
  equal(rows(frame.frame), ["", "", "─────────────────────", "Message…"]);
  frame.paste("hi");
  chat.tui.commands.run("core:split-right");
  frame.paste("yo");
  equal(rows(frame.frame), ["          │", "          │", "──────────│──────────", "hi        │yo"]);
  // The transcript and the composer of a pane share a group, and each pane has its own.
  const groups = new Map<unknown, Set<object>>();
  for (const mount of chat.tui.widgets.list())
    groups.set(mount.pane, (groups.get(mount.pane) ?? new Set()).add(mount.group));
  const perPane = [...groups.values()];
  equal(
    [perPane.length, perPane.map((set) => set.size), new Set(perPane.flatMap((set) => [...set])).size],
    [2, [1, 1], 2],
  );
});

test("a reload keeps the draft of each pane and the focus", async () => {
  using before = createFrame({ width: 21, height: 4 });
  const chat = await loadChat(before);
  before.start();
  before.paste("a");
  chat.tui.commands.run("core:split-right");
  before.paste("x");
  const snapshot = before.snapshot();
  using after = createFrame({ width: 21, height: 4 });
  await loadChat(after);
  after.start(snapshot);
  after.paste("b");
  equal(rows(after.frame).at(-1), "a         │xb");
});

test("a drag over the transcript copies at the release, and the composer keeps the focus", async () => {
  using frame = createFrame({ width: 10, height: 4 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions([commit(2, [{ assistant_text: "hello" }])]));
  frame.start();
  // Row 0 is the gap before the reply, and column 0 is its indent.
  frame.mouse(mouse(1, 1, "press"));
  frame.mouse(mouse(5, 1, "drag"));
  frame.mouse(mouse(5, 1, "release"));
  frame.paste("x");
  frame.draw();
  equal([frame.copies, chat.tui.focused === chat.transcript(), rows(frame.frame).at(-1)], [["hello"], false, "x"]);
});

test("the start pane holds the session of the startup, and a split opens a new chat without one", async () => {
  using frame = createFrame({ width: 21, height: 4 }, undefined, { cwd: "/work", session: "s1" });
  const chat = await loadChat(frame);
  frame.start();
  chat.tui.commands.run("core:split-right");
  equal(
    chat.opened.map((open) => [open.id, open.tail]),
    [["s1", 200]],
  );
  // The close of the start pane ends its handle. Focus by direction reads the rects of the last frame.
  frame.draw();
  chat.tui.commands.run("core:focus-left");
  chat.tui.commands.run("core:close");
  equal(chat.opened[0]?.signal.aborted, true);
  equal(JSON.parse(frame.snapshot()).tree.state.session, undefined);
});

test("two panes on one session hold their own handles, and a reload keeps the session of each", async () => {
  const pane = { type: "chat:pane", state: { session: "s1", draft: EMPTY } };
  const saved = JSON.stringify({ tree: { split: "row", first: pane, second: pane }, focus: 0 });
  using frame = createFrame({ width: 21, height: 4 });
  const chat = await loadChat(frame);
  frame.start(saved);
  equal(
    chat.opened.map((open) => open.id),
    ["s1", "s1"],
  );
  chat.tui.commands.run("core:close");
  equal(
    chat.opened.map((open) => open.signal.aborted),
    [true, false],
  );
  equal(JSON.parse(frame.snapshot()).tree.state.session, "s1");
  // A session that does not open gives one notice, and the pane keeps the session for the next reload.
  using other = createFrame({ width: 21, height: 4 });
  const failed = await loadChat(other);
  other.start(JSON.stringify({ tree: { type: "chat:pane", state: { session: "missing", draft: EMPTY } }, focus: 0 }));
  await settled();
  equal(failed.notices, ["error the session missing did not open: Error: no session missing"]);
  equal(JSON.parse(other.snapshot()).tree.state.session, "missing");
});

test("each kind of entry draws its rows, and a click on a thought opens it", async () => {
  const user = { kind: "user" } as const;
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    {
      seq: 2,
      sessionUpdate: "commit",
      commit: {
        replaced: null,
        blocks: [
          { user_text: "fix the test" },
          { reasoning: { text: "the test expects 3" } } as never,
          { assistant_text: "**Found** it" },
          { tool_call: { callId: "c1", name: "exec", arguments: "{}" } },
        ],
        answer: null,
        end: null,
      },
      consumed: [{ id: 1, source: user, kind: "message", blockCount: 1 }],
    },
    {
      seq: 3,
      sessionUpdate: "commit",
      commit: {
        replaced: null,
        blocks: [{ user_text: "build done" }, { tool_result: { callId: "c1", content: "ok", isError: false } }],
        answer: null,
        end: { failed: "boom" },
      },
      consumed: [{ id: 2, source: { kind: "plugin", name: "ci" }, kind: "notification", blockCount: 1 }],
    },
    {
      seq: 4,
      sessionUpdate: "commit",
      commit: { replaced: { head: [], keep: 0 }, blocks: [], answer: null, end: { outcome: "stopped" } },
      consumed: [],
    },
  ];
  using frame = createFrame({ width: 30, height: 23 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(saved);
  await loadChat(frame, sessions);
  frame.start();
  sessions.push({ sessionUpdate: "retry_scheduled", afterMs: 2500, error: "overloaded" });
  frame.draw();
  const before = transcriptRows(frame);
  equal(before.slice(0, 21), [
    "",
    " fix the test",
    "",
    " thought",
    "",
    " Found it",
    "",
    " exec",
    " ok",
    "",
    " notification · ci",
    " build done",
    "",
    " failed: boom",
    "",
    " context replaced",
    "",
    " stopped",
    "",
    " retry in 3 s: overloaded",
    "",
  ]);
  click(frame, 2, 3);
  equal(transcriptRows(frame).slice(3, 6), [" thought", " the test expects 3", ""]);
  click(frame, 2, 3);
  equal(transcriptRows(frame), before);
});

test("the top loads older pages, keeps the shown rows, and stops at the first event", async () => {
  using frame = createFrame({ width: 20, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(250));
  const chat = await loadChat(frame, sessions);
  frame.start();
  equal(transcriptRows(frame).at(-1), " reply 250");
  for (let visit = 0; visit < 3; visit += 1) {
    chat.transcript().scroll.scrollTo(0);
    frame.draw();
    const shown = transcriptRows(frame);
    await settled();
    frame.draw();
    // A prepend keeps the item at the top and its row.
    equal(transcriptRows(frame), shown);
  }
  // A live event while the view shows the top asks for no page past the first event.
  sessions.push(commit(251, [{ assistant_text: "reply 251" }]));
  frame.draw();
  await settled();
  equal(sessions.pages, [
    { before: 51, limit: 100 },
    { before: 1, limit: 100 },
  ]);
  equal(chat.transcript().document.items[0]?.key, "2:0");
});

test("a failed page shows its error in the rule and loads no more pages", async () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(250));
  sessions.state.failing = true;
  const chat = await loadChat(frame, sessions);
  frame.start();
  for (let visit = 0; visit < 2; visit += 1) {
    chat.transcript().scroll.scrollTo(0);
    frame.draw();
    await settled();
  }
  sessions.push(commit(251, [{ assistant_text: "reply 251" }]));
  chat.transcript().scroll.scrollTo(0);
  frame.draw();
  await settled();
  frame.draw();
  equal(rows(frame.frame).at(-2), "─ the history did not load: Error: disk");
  equal(sessions.pages.length, 1);
});

test("output below a scrolled transcript shows the hint, and the bottom follows the tail again", async () => {
  using frame = createFrame({ width: 20, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(replies(30));
  const chat = await loadChat(frame, sessions);
  frame.start();
  chat.transcript().scroll.scrollBy(-4);
  sessions.push(commit(31, [{ assistant_text: "reply 31" }]));
  frame.draw();
  equal(rows(frame.frame).at(-2), "─ new output ↓ ─────");
  chat.transcript().scroll.followTail();
  frame.draw();
  equal(rows(frame.frame).at(-2), "────────────────────");
  sessions.push(commit(32, [{ assistant_text: "reply 32" }]));
  frame.draw();
  equal(transcriptRows(frame).at(-1), " reply 32");
});

test("a reload keeps the folds and the scrolled place of a pane", async () => {
  const saved = replies(40);
  saved[1] = commit(2, [{ reasoning: { text: "deep" } } as never, { assistant_text: "ok" }]);
  using before = createFrame({ width: 20, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(before, fakeSessions(saved));
  before.start();
  chat.transcript().scroll.scrollTo(0);
  before.draw();
  click(before, 2, 1);
  chat.transcript().scroll.scrollBy(1);
  before.draw();
  const shown = transcriptRows(before);
  equal(shown.slice(0, 2), [" thought", " deep"]);
  using after = createFrame({ width: 20, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(after, fakeSessions(saved));
  after.start(before.snapshot());
  after.draw();
  await settled();
  after.draw();
  equal(transcriptRows(after), shown);
});

test("a live event after a gap loads the missing events, and an unchanged entry keeps its item", async () => {
  using frame = createFrame({ width: 20, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const saved = replies(10);
  const sessions = fakeSessions(saved);
  const chat = await loadChat(frame, sessions);
  frame.start();
  const first = chat.transcript().document.items[0];
  // The event 11 is saved, but the handle gets only the event 12.
  saved.push(commit(11, [{ assistant_text: "reply 11" }]));
  sessions.push(commit(12, [{ assistant_text: "reply 12" }]));
  frame.draw();
  await settled();
  frame.draw();
  equal(sessions.pages, [{ before: 12, limit: 1 }]);
  equal(
    chat
      .transcript()
      .document.items.slice(-3)
      .map((item) => item.key),
    ["10:0", "11:0", "12:0"],
  );
  equal(chat.transcript().document.items[0] === first, true);
});

test("a notification from yuke shows its source without host:, and a plugin keeps its whole name", async () => {
  const notification = (seq: number, id: number, name: string, text: string): StoredEvent => ({
    seq,
    sessionUpdate: "commit",
    commit: { replaced: null, blocks: [{ user_text: text }], answer: null, end: null },
    consumed: [{ id, source: { kind: "plugin", name }, kind: "notification", blockCount: 1 }],
  });
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    notification(2, 1, "host:jobs", "make · exited 0"),
    notification(3, 2, "myhost:ci", "build done"),
  ];
  using frame = createFrame({ width: 40, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  frame.draw();

  equal(transcriptRows(frame).slice(1, 6), [
    " notification · jobs",
    " make · exited 0",
    "",
    " notification · myhost:ci",
    " build done",
  ]);
});
