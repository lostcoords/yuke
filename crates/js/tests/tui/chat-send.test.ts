// The composer of the bundled chat: the first send, the model picker, a refused input, long pastes, the messages of
// the user, and the keys of a pane.

import type { StoredEvent } from "yuke:protocol";
import { createFrame, equal, test } from "yuke:test";
import { type EditorState, TextEditor } from "yuke:tui";
import { commit, fakeSessions, loadChat, rows, SETTINGS, settle, transcriptRows } from "./chat.ts";

/** The composer of the chat in `frame`. */
function composerOf(chat: ReturnType<typeof loadChat>): TextEditor {
  return chat.tui.widgets.list().find((mount) => mount.widget instanceof TextEditor)?.widget as TextEditor;
}

/** The text and the spans of `state`. */
function draft(state: EditorState): [string, [number, number, string][]] {
  return [state.text, state.spans.map((span) => [span.from, span.to, span.label])];
}

test("the first send with the model and the reasoning of the startup creates the session and sends the draft", async () => {
  const startup = { cwd: "/launch", model: { provider: "p", model: "m" }, reasoning: "high" } as const;
  using frame = createFrame({ width: 30, height: 6 }, undefined, startup);
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.paste("hello");
  frame.key("enter");
  await settle();
  equal(sessions.created, [
    {
      model: { provider: "p", model: "m" },
      settings: {
        maxOutputTokens: null,
        reasoning: { thinking: null, effort: "high" },
        temperature: null,
        topP: null,
        toolChoice: "auto",
        outputSchema: null,
      },
      cwd: "/launch",
    },
  ]);
  equal(
    [sessions.opened.map((open) => open.id), sessions.inputs, composerOf(chat).state.text],
    [["s-new"], [[{ user_text: "hello" }]], ""],
  );
  frame.draw();
  equal(JSON.parse(frame.snapshot()).tree.state.session, "s-new");
  equal(chat.transcript().document.key, "session:s-new");
});

test("without a model the first send asks for the model, then for an explicit level, and a cancel keeps the draft", async () => {
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/launch" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.paste("hi");
  frame.key("enter");
  await settle();
  frame.draw();
  equal(rows(frame).includes("p/m"), true, rows(frame).join("\n"));
  frame.key("enter");
  await settle();
  frame.draw();
  // The levels leave out default.
  equal(
    rows(frame).filter((row) => row === "off" || row === "high" || row === "default"),
    ["off", "high"],
  );
  frame.key("esc");
  await settle();
  equal([sessions.created, composerOf(chat).state.text], [[], "hi"]);
  frame.key("enter");
  await settle();
  frame.key("enter");
  await settle();
  frame.key("down");
  frame.key("enter");
  await settle();
  equal(
    [sessions.created.map((settings) => settings.settings.reasoning), sessions.inputs],
    [[{ thinking: null, effort: "high" }], [[{ user_text: "hi" }]]],
  );
});

test("a refused input comes back above the newer text with the spans of both, and Enter waits for the first send", async () => {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const refuse = Promise.withResolvers<void>();
  sessions.state.accept = refuse.promise;
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.paste("first");
  frame.key("enter");
  await settle();
  frame.paste("x".repeat(301));
  frame.key("enter");
  await settle();
  equal([sessions.inputs.length, composerOf(chat).state.text.length], [1, 301]);
  refuse.reject(new Error("full"));
  await settle();
  equal(draft(composerOf(chat).state), [`first\n${"x".repeat(301)}`, [[6, 307, "[Pasted text · 301 chars]"]]]);
  equal(chat.notices, ["error the message did not send: Error: full"]);
});

test("an accepted input followed by a failed turn does not come back", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.paste("go");
  frame.key("enter");
  await settle();
  equal([sessions.inputs, composerOf(chat).state.text], [[[{ user_text: "go" }]], ""]);
  sessions.push(commit(2, [], { end: { failed: "boom" } }));
  await settle();
  frame.draw();
  equal([composerOf(chat).state.text, chat.notices], ["", []]);
});

test("a pane whose open failed opens its session again at the next send", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  sessions.state.openFails = 1;
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.paste("again");
  frame.key("enter");
  await settle();
  equal(
    [sessions.opened.map((open) => open.id), sessions.inputs, chat.notices],
    [["s1", "s1"], [[{ user_text: "again" }]], ["error the session s1 did not open: Error: busy"]],
  );
});

test("a cancel of the model picker, a catalog that fails, and a pane close each keep the draft and create nothing", async () => {
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/launch" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.paste("hi");
  frame.key("enter");
  await settle();
  frame.key("esc");
  await settle();
  equal([sessions.created, composerOf(chat).state.text], [[], "hi"]);
  // A close of the pane closes its open picker.
  frame.key("enter");
  await settle();
  frame.draw();
  equal(rows(frame).includes("p/m"), true);
  chat.tui.commands.run("core:close");
  await settle();
  frame.draw();
  equal([rows(frame).includes("p/m"), sessions.created], [false, []]);
  using other = createFrame({ width: 30, height: 6 }, undefined, { cwd: "/launch" });
  const failing = loadChat(other, {}, fakeSessions(), { list: () => Promise.reject(new Error("offline")) });
  other.start();
  other.paste("hi");
  other.key("enter");
  await settle();
  equal([composerOf(failing).state.text, failing.notices], ["hi", ["error the models did not load: Error: offline"]]);
});

test("a paste over 300 characters shows a label, and the input gets the whole text", async () => {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  // A draft of white space sends nothing and stays.
  frame.paste("  ");
  frame.key("enter");
  await settle();
  equal([sessions.inputs, composerOf(chat).state.text], [[], "  "]);
  frame.key("ctrl+c");
  frame.paste("a".repeat(300));
  equal(composerOf(chat).state.spans, []);
  frame.key("ctrl+c");
  frame.paste("b".repeat(301));
  equal(rows(frame).at(-1), "[Pasted text · 301 chars]");
  frame.key("enter");
  await settle();
  equal(sessions.inputs, [[{ user_text: "b".repeat(301) }]]);
});

test("up in an empty composer shows the older messages of the user, down brings back the draft, and an edit ends it", () => {
  const user = { kind: "user" } as const;
  const message = (seq: number, text: string, source: "user" | "plugin" = "user"): StoredEvent => ({
    seq,
    sessionUpdate: "commit",
    commit: { replaced: null, blocks: [{ user_text: text }], answer: null, end: null },
    consumed: [
      {
        id: seq,
        source: source === "user" ? user : { kind: "plugin", name: "ci" },
        kind: source === "user" ? "message" : "notification",
        blockCount: 1,
      },
    ],
  });
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    message(2, "one"),
    message(3, "two"),
    message(4, "build done", "plugin"),
  ];
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions(saved));
  frame.start();
  const text = () => composerOf(chat).state.text;
  frame.key("up");
  equal(text(), "two");
  frame.key("up");
  frame.key("up");
  equal(text(), "one");
  frame.key("down");
  frame.key("down");
  equal(text(), "");
  // A draft with text keeps the arrows for the caret.
  frame.paste("ab");
  frame.key("up");
  equal(text(), "ab");
  frame.key("ctrl+c");
  frame.key("up");
  frame.paste("!");
  frame.key("down");
  equal(text(), "two!");
});

test("ctrl+c clears the draft, then stops the turn, and esc drops the selection before it stops the turn", async () => {
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ assistant_text: "hello" }]),
  ];
  using frame = createFrame({ width: 20, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(saved);
  const chat = loadChat(frame, { copyOnRelease: false }, sessions);
  frame.start();
  await settle();
  frame.paste("draft");
  frame.key("ctrl+c");
  equal([composerOf(chat).state.text, sessions.state.cancels], ["", 0]);
  frame.key("ctrl+c");
  equal(sessions.state.cancels, 1);
  chat.transcript().selection = {
    anchor: { item: "2:0", section: "text", offset: 0 },
    head: { item: "2:0", section: "text", offset: 3 },
  };
  frame.key("esc");
  equal([chat.transcript().selection, sessions.state.cancels], [undefined, 1]);
  frame.key("esc");
  equal(sessions.state.cancels, 2);
});

test("tab moves the focus to the transcript, where y copies the selection and enter acts on the caret", async () => {
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ assistant_text: "see [docs](https://docs.rs)" }]),
  ];
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, { copyOnRelease: false }, fakeSessions(saved));
  frame.start();
  frame.key("tab");
  equal(chat.tui.focused === chat.transcript(), true);
  const transcript = chat.transcript();
  transcript.selection = {
    anchor: { item: "2:0", section: "text", offset: 0 },
    head: { item: "2:0", section: "text", offset: 3 },
  };
  frame.key("y");
  transcript.caret = { item: "2:0", section: "text", offset: 6 };
  frame.key("enter");
  equal(frame.copies, ["see", "https://docs.rs"]);
  frame.key("shift+tab");
  equal(chat.tui.focused === composerOf(chat), true);
});

test("page keys scroll the transcript, and a pane of one row keeps the composer", () => {
  const saved: StoredEvent[] = [{ seq: 1, sessionUpdate: "settings", ...SETTINGS }];
  for (let seq = 2; seq <= 20; seq += 1) saved.push(commit(seq, [{ assistant_text: `reply ${seq}` }]));
  using frame = createFrame({ width: 20, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions(saved));
  frame.start();
  const bottom = chat.transcript().scroll.state.top;
  frame.key("page_up");
  equal(chat.transcript().scroll.state.top, bottom - 5);
  frame.key("ctrl+home");
  equal(transcriptRows(frame)[1], " reply 2");
  frame.key("ctrl+end");
  equal(chat.transcript().scroll.state.top, bottom);
  frame.resize({ width: 20, height: 1 });
  equal(rows(frame), ["Message…"]);
});

test("a refusal while the user browses the messages ends the browse, so down keeps the restored draft", async () => {
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    {
      seq: 2,
      sessionUpdate: "commit",
      commit: { replaced: null, blocks: [{ user_text: "old" }], answer: null, end: null },
      consumed: [{ id: 1, source: { kind: "user" }, kind: "message", blockCount: 1 }],
    },
  ];
  using frame = createFrame({ width: 30, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(saved);
  const refuse = Promise.withResolvers<void>();
  sessions.state.accept = refuse.promise;
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.paste("first");
  frame.key("enter");
  await settle();
  frame.key("up");
  equal(composerOf(chat).state.text, "old");
  refuse.reject(new Error("full"));
  await settle();
  frame.key("down");
  equal(composerOf(chat).state.text, "first\nold");
});

test("ctrl+k m in a new pane keeps the chosen model and level for the first send, even with a startup model", async () => {
  const startup = { cwd: "/launch", model: { provider: "p", model: "m" }, reasoning: "off" } as const;
  using frame = createFrame({ width: 30, height: 14 }, undefined, startup);
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.key("ctrl+k m");
  await settle();
  frame.key("down");
  frame.key("enter");
  await settle();
  // A send while the picker is open does nothing.
  chat.tui.commands.run("chat:send");
  frame.key("enter");
  await settle();
  equal(sessions.created, []);
  frame.paste("hi");
  frame.key("enter");
  await settle();
  equal(
    [sessions.created.map((settings) => [settings.model, settings.settings.reasoning, settings.cwd]), sessions.inputs],
    [[[{ provider: "p", model: "n" }, { thinking: null, effort: "low" }, "/launch"]], [[{ user_text: "hi" }]]],
  );
});

test("ctrl+k m in a pane with a session changes its model and level and keeps its other settings", async () => {
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions([{ seq: 1, sessionUpdate: "settings", ...SETTINGS }]);
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  // The session has its own folder, model, and output limit, so the change must keep the first and the last.
  const own = {
    model: { provider: "q", model: "n" },
    settings: { ...SETTINGS.settings, maxOutputTokens: 1000 },
    cwd: "/session",
  };
  sessions.push({ seq: 2, sessionUpdate: "settings", ...own });
  frame.key("ctrl+k m");
  await settle();
  frame.key("enter");
  await settle();
  frame.key("enter");
  await settle();
  equal(sessions.changes, [
    {
      model: { provider: "p", model: "m" },
      settings: { ...own.settings, reasoning: { thinking: "off", effort: null } },
      cwd: "/session",
    },
  ]);
  // A refused change gives one notice.
  sessions.state.refuseSettings = true;
  frame.key("ctrl+k m");
  await settle();
  frame.key("enter");
  await settle();
  frame.key("enter");
  await settle();
  equal(chat.notices, ["error the model did not change: Error: a turn runs"]);
});
