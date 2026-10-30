// The composer of the bundled chat: the first send, the model picker, a refused input, long pastes, the messages of
// the user, the strip and the recall of waiting messages, and the keys of a pane.

import { mkdir, readTextFile, writeTextFile } from "yuke:fs";
import type { Block, ListCatalogResult, SessionUpdate, StoredEvent } from "yuke:protocol";
import { createFrame, equal, type FrameTest, folder, test } from "yuke:test";
import { type EditorState, TextEditor } from "yuke:tui";
import { CATALOG, commit, fakeSessions, loadChat, rows, SETTINGS, settle, transcriptRows } from "./chat.ts";

/** The composer of the chat in `frame`. */
function composerOf(chat: ReturnType<typeof loadChat>): TextEditor {
  return chat.tui.widgets.list().find((mount) => mount.widget instanceof TextEditor)?.widget as TextEditor;
}

/** Wait until `done` holds. The time limit of the test ends a wait that never ends. */
async function waitFor(done: () => boolean | Promise<boolean>): Promise<void> {
  while (!(await done())) await new Promise((resolve) => setTimeout(resolve, 5));
}

/** Draw the frame and report whether the model picker shows. */
function showsModelPicker(frame: FrameTest): boolean {
  frame.draw();
  return rows(frame).includes("p/m");
}

/** The update of the accepted input `id` with `content`, of the user, or a notification of the plugin `ci`. */
function accepted(id: number, content: Block[], source: "user" | "plugin" = "user"): SessionUpdate {
  return {
    sessionUpdate: "input_accepted",
    inputId: id,
    input:
      source === "user"
        ? { source: { kind: "user" }, kind: "message", content }
        : { source: { kind: "plugin", name: "ci" }, kind: "notification", content },
  };
}

/** The text and the spans of `state`. */
function draft(state: EditorState): [string, [number, number, string][]] {
  return [state.text, state.spans.map((span) => [span.from, span.to, span.label])];
}

test("a saved choice skips the picker on the first send and sends the draft", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  const startup = { cwd: "/launch" };
  using frame = createFrame({ width: 30, height: 6 }, undefined, startup);
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.paste("hello");
  frame.key("enter");
  await waitFor(() => sessions.inputs.length === 1);
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

test("without a saved choice the first send asks for the model and level, and a cancel keeps the draft", async () => {
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/launch" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.paste("hi");
  frame.key("enter");
  await waitFor(() => showsModelPicker(frame));
  frame.key("enter");
  await settle();
  frame.draw();
  equal(
    rows(frame).filter((row) => row === "off" || row === "high" || row === "default"),
    ["default", "off", "high"],
  );
  frame.key("esc");
  await settle();
  equal([sessions.created, composerOf(chat).state.text], [[], "hi"]);
  frame.key("enter");
  await waitFor(() => showsModelPicker(frame));
  frame.key("enter");
  await settle();
  frame.key("down down");
  frame.key("enter");
  await waitFor(() => sessions.inputs.length === 1);
  equal(
    [sessions.created.map((settings) => settings.settings.reasoning), sessions.inputs],
    [[{ thinking: null, effort: "high" }], [[{ user_text: "hi" }]]],
  );
  equal(JSON.parse(await readTextFile("choice.json", { baseDir: folder() })), {
    model: { provider: "p", model: "m" },
    reasoning: "high",
  });
  equal(chat.notices, []);
});

for (const choice of [
  { model: { provider: "p", model: "gone" }, reasoning: "high" },
  { model: { provider: "p", model: "m" }, reasoning: "low" },
]) {
  test(`a stale choice ${JSON.stringify(choice)} opens the picker without a notice`, async () => {
    await writeTextFile("choice.json", JSON.stringify(choice), { baseDir: folder() });
    using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/launch" });
    const sessions = fakeSessions();
    const chat = loadChat(frame, {}, sessions);
    frame.start();
    frame.paste("hi");
    frame.key("enter");
    await waitFor(() => showsModelPicker(frame));
    frame.draw();
    equal([rows(frame).includes("p/m"), chat.notices, composerOf(chat).state.text], [true, [], "hi"]);
    frame.key("enter");
    await settle();
    frame.key("enter");
    await waitFor(() => sessions.inputs.length === 1);
    equal(
      [sessions.created.map((settings) => [settings.model, settings.settings.reasoning]), sessions.inputs],
      [
        [
          [
            { provider: "p", model: "m" },
            { thinking: null, effort: null },
          ],
        ],
        [[{ user_text: "hi" }]],
      ],
    );
    equal(JSON.parse(await readTextFile("choice.json", { baseDir: folder() })), {
      model: { provider: "p", model: "m" },
      reasoning: "default",
    });
  });
}

for (const failure of ["read", "parse"]) {
  test(`a choice file ${failure} failure gives one notice and opens the picker`, async () => {
    if (failure === "read") await mkdir("choice.json", { baseDir: folder() });
    else await writeTextFile("choice.json", "{", { baseDir: folder() });
    using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/launch" });
    const chat = loadChat(frame);
    frame.start();
    frame.paste("hi");
    frame.key("enter");
    await waitFor(() => showsModelPicker(frame));
    frame.draw();
    equal(
      [
        rows(frame).includes("p/m"),
        chat.notices.length,
        chat.notices[0]?.startsWith("error the model choice did not load:"),
      ],
      [true, 1, true],
    );
  });
}

test("a choice that does not save gives a notice and the send goes on", async () => {
  await mkdir("choice.json", { baseDir: folder() });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/launch" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.paste("hi");
  frame.key("enter");
  await waitFor(() => showsModelPicker(frame));
  frame.key("enter");
  await settle();
  frame.key("enter");
  await waitFor(() => sessions.inputs.length === 1);
  equal(
    [chat.notices.map((notice) => notice.split(":")[0]), sessions.inputs],
    [["error the model choice did not load", "error the model choice did not save"], [[{ user_text: "hi" }]]],
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
  await waitFor(() => showsModelPicker(frame));
  frame.key("esc");
  await settle();
  equal([sessions.created, composerOf(chat).state.text], [[], "hi"]);
  // A close of the pane closes its open picker.
  frame.key("enter");
  await waitFor(() => showsModelPicker(frame));
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

test("up in an empty composer shows the older messages of the user, down past the newest empties it, and an edit ends it", () => {
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

test("ctrl+k m in a new pane saves a new choice for the first send", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"off"}', { baseDir: folder() });
  const startup = { cwd: "/launch" };
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
  frame.key("down");
  frame.key("enter");
  await settle();
  await waitFor(async () => JSON.parse(await readTextFile("choice.json", { baseDir: folder() })).model.model === "n");
  await settle();
  equal(sessions.created, []);
  equal(JSON.parse(await readTextFile("choice.json", { baseDir: folder() })), {
    model: { provider: "p", model: "n" },
    reasoning: "low",
  });
  frame.paste("hi");
  frame.key("enter");
  await waitFor(() => sessions.inputs.length === 1);
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
  await waitFor(() => sessions.changes.length === 1);
  equal(sessions.changes, [
    {
      model: { provider: "p", model: "m" },
      settings: { ...own.settings, reasoning: { thinking: null, effort: null } },
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
  await waitFor(() => chat.notices.length === 1);
  equal(chat.notices, ["error the model did not change: Error: a turn runs"]);
});

test("a slash in an empty composer opens the palette, Esc gives the slash back, and a pasted slash stays text", async () => {
  using frame = createFrame({ width: 60, height: 14 });
  const chat = loadChat(frame);
  frame.start();
  const composer = composerOf(chat);
  frame.key("/ m o d e l");
  frame.draw();
  equal(rows(frame).slice(2, 4), ["model", "/chat:model  Choose the model and the reasoning · ctrl+k m"]);
  // A choice runs the command in the pane and leaves no slash.
  frame.key("enter");
  await settle();
  frame.draw();
  equal([rows(frame).includes("p/m"), composer.state.text], [true, ""]);
  frame.key("esc");
  frame.key("/ m o d e l");
  frame.key("esc");
  equal([composer.state.text, composer.caret], ["/", 1]);
  frame.key("/");
  frame.key("ctrl+c");
  frame.paste("/a");
  equal(composer.state.text, "/a");
});

test("a pane close with an open palette closes it and puts no slash in the composer", () => {
  using frame = createFrame({ width: 30, height: 14 });
  const chat = loadChat(frame);
  frame.start();
  const composer = composerOf(chat);
  frame.key("/");
  chat.tui.commands.run("core:close");
  frame.draw();
  equal([composer.state.text, rows(frame).some((row) => row.startsWith("/quit"))], ["", false]);
});

test("the commands of the chat are disabled in a pane of another plugin", () => {
  using frame = createFrame({ width: 30, height: 6 });
  const chat = loadChat(frame);
  frame.start();
  const enabled = (): boolean[] =>
    chat.tui.commands
      .list()
      .filter((command) => command.name === "chat:model")
      .map((command) => command.enabled);
  const before = enabled();
  frame.surface("notes").tui.panes.split(() => ({ draw() {}, focusable: true }));
  frame.draw();
  equal([before, enabled()], [[true], [false]]);
});

test("the strip shows the waiting messages of the user oldest first, cut to one row, and no input of a plugin", async () => {
  using frame = createFrame({ width: 24, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  sessions.push(accepted(5, [{ user_text: "fix the test" }]));
  sessions.push(accepted(6, [{ user_text: "CI failed" }], "plugin"));
  sessions.push(accepted(7, [{ user_text: "and the docs\nthen push them" }]));
  frame.draw();
  equal(rows(frame).slice(3), [
    "",
    " fix the test",
    " and the docs th… ↑ edit",
    "────────────────────────",
    "Message…",
  ]);
  // The transcript gives the strip its rows.
  equal(chat.transcript().scroll.state.height, 4);
});

test("up recalls the newest waiting message with its images, the next up puts the older one above, and an edit or a caret move ends it", async () => {
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  const media = { blob: { digest: "abc", len: 3 }, mime: "image/png" };
  sessions.push(accepted(1, [{ user_text: "first" }]));
  sessions.push(accepted(3, [{ user_text: "zero" }]));
  sessions.push(accepted(5, [{ user_text: "one" }]));
  sessions.push(accepted(6, [{ user_text: "CI failed" }], "plugin"));
  sessions.push(accepted(9, [{ user_text: "see " }, { media }]));
  frame.key("up");
  await settle();
  const recalled = draft(composerOf(chat).state);
  // The image span keeps the blob of the recalled input, not only its label.
  const span = composerOf(chat).state.spans[0];
  const blob = span?.kind === "image" ? span.media : undefined;
  frame.key("up");
  await settle();
  equal(
    [recalled, blob, draft(composerOf(chat).state), sessions.removals],
    [["see \uFFFC", [[4, 5, "[image 1]"]]], media, ["one\nsee \uFFFC", [[8, 9, "[image 1]"]]], [9, 5]],
  );
  // An edit ends the recall, so up moves the caret, and the older message waits on.
  frame.paste("!");
  frame.key("up");
  await settle();
  frame.draw();
  equal(
    [sessions.removals, rows(frame).some((row) => row.includes("CI failed")), rows(frame).at(-4)],
    [[9, 5], false, `${" zero".padEnd(23)} ↑ edit`],
  );
  // A caret move ends a recall too.
  frame.key("ctrl+c");
  frame.key("up");
  await settle();
  frame.key("left up");
  await settle();
  equal([composerOf(chat).state.text, sessions.removals], ["zero", [9, 5, 3]]);
});

test("a message that a turn took stays sent and the next up recalls an older one, up during a recall does nothing, and text typed meanwhile stays", async () => {
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  sessions.push(accepted(3, [{ user_text: "zero" }]));
  sessions.push(accepted(5, [{ user_text: "one" }]));
  sessions.state.removed = false;
  frame.key("up");
  await settle();
  equal([composerOf(chat).state.text, chat.notices], ["", ["info the message reached the turn already"]]);
  // The next up goes on with the older message, so it never asks for the sent one again.
  sessions.state.removed = true;
  const { promise, resolve } = Promise.withResolvers<void>();
  sessions.state.removal = promise;
  frame.key("up");
  frame.key("up");
  frame.paste("x");
  resolve();
  await settle();
  equal([composerOf(chat).state.text, sessions.removals], ["zero\nx", [5, 3]]);
});

test("a pane close during a recall leaves the composer and gives no notice", async () => {
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  const composer = composerOf(chat);
  sessions.push(accepted(5, [{ user_text: "one" }]));
  const { promise, resolve } = Promise.withResolvers<void>();
  sessions.state.removal = promise;
  frame.key("up");
  chat.tui.commands.run("core:close");
  resolve();
  await settle();
  equal([composer.state.text, chat.notices, sessions.removals], ["", [], [5]]);
});

test("up during a browse goes on with the history, and the end of the browse gives up to a recall", async () => {
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    {
      seq: 2,
      sessionUpdate: "commit",
      commit: { replaced: null, blocks: [{ user_text: "old" }], answer: null, end: null },
      consumed: [{ id: 2, source: { kind: "user" }, kind: "message", blockCount: 1 }],
    },
  ];
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions(saved);
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.key("up");
  sessions.push(accepted(7, [{ user_text: "wait" }]));
  frame.key("up");
  await settle();
  const browsed = [composerOf(chat).state.text, [...sessions.removals]];
  frame.key("down up");
  await settle();
  equal([browsed, composerOf(chat).state.text, sessions.removals], [["old", []], "wait", [7]]);
});

test("the strip keeps the newest messages when rows run out, and a failed recall keeps the composer", async () => {
  using frame = createFrame({ width: 20, height: 4 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  for (const [id, text] of [
    [9, "c"],
    [3, "a"],
    [5, "b"],
  ] as const)
    sessions.push(accepted(id, [{ user_text: text }]));
  frame.draw();
  const strip = rows(frame).slice(0, 2);
  sessions.state.removal = Promise.reject(new Error("disk"));
  frame.key("up");
  await settle();
  equal(
    [strip, composerOf(chat).state.text, chat.notices],
    [[" b", `${" c".padEnd(13)} ↑ edit`], "", ["error the message did not come back: Error: disk"]],
  );
});

test("a send after a close of the session by another client opens the session again", async () => {
  using frame = createFrame({ width: 30, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  sessions.close("s1");
  frame.paste("hi");
  frame.key("enter");
  await settle();
  equal([sessions.opened.map((open) => open.id), sessions.inputs], [["s1", "s1"], [[{ user_text: "hi" }]]]);
});

const PNG = Object.freeze({ bytes: new Uint8Array([1, 2, 3]), mime: "image/png" as const });

test("ctrl+v puts the image of the clipboard at the caret with the next number, and a send keeps the order", async () => {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.clipboard = PNG;
  frame.paste("see ");
  frame.key("ctrl+v");
  await settle();
  frame.paste(" and ");
  frame.key("ctrl+v");
  await settle();
  const shown = draft(composerOf(chat).state);
  frame.key("enter");
  await settle();
  const media = (digest: string) => ({ media: { blob: { digest, len: 3 }, mime: "image/png" } });
  equal(
    [shown, sessions.blobs, sessions.inputs],
    [
      [
        "see ￼ and ￼",
        [
          [4, 5, "[image 1]"],
          [10, 11, "[image 2]"],
        ],
      ],
      [
        [1, 2, 3],
        [1, 2, 3],
      ],
      [[{ user_text: "see " }, media("d1"), { user_text: " and " }, media("d2")]],
    ],
  );
});

test("ctrl+v without an image gives a notice, a failed store gives a notice, and a new pane creates its session first", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  const startup = { cwd: "/w" };
  using frame = createFrame({ width: 40, height: 6 }, undefined, startup);
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.key("ctrl+v");
  await settle();
  const none = [...chat.notices];
  frame.clipboard = PNG;
  const store = Promise.withResolvers<void>();
  sessions.state.store = store.promise;
  frame.key("ctrl+v");
  await waitFor(() => sessions.blobs.length === 1);
  store.reject(new Error("disk full"));
  await waitFor(() => chat.notices.length === 2);
  equal(
    [
      none,
      chat.notices.slice(1),
      sessions.created.length,
      sessions.opened.map((open) => open.id),
      composerOf(chat).state.text,
    ],
    [["info the clipboard holds no image"], ["error the image did not attach: Error: disk full"], 1, ["s-new"], ""],
  );
});

test("a cancel of the model picker or a pane close during ctrl+v puts nothing in the composer", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { cwd: "/w" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  frame.clipboard = PNG;
  const composer = composerOf(chat);
  frame.key("ctrl+v");
  await waitFor(() => showsModelPicker(frame));
  frame.key("esc");
  await settle();
  const cancelled = [sessions.created.length, composer.state.text];
  using other = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const later = fakeSessions();
  const closing = loadChat(other, {}, later);
  other.start();
  await settle();
  other.clipboard = PNG;
  const { promise, resolve } = Promise.withResolvers<void>();
  later.state.store = promise;
  const held = composerOf(closing);
  other.key("ctrl+v");
  await settle();
  closing.tui.commands.run("core:close");
  resolve();
  await settle();
  equal([cancelled, held.state.text, closing.notices], [[0, ""], "", []]);
});

test("text typed while the first send sets up the session goes with the message", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  const startup = { cwd: "/w" };
  using frame = createFrame({ width: 40, height: 6 }, undefined, startup);
  const sessions = fakeSessions();
  const { promise, resolve } = Promise.withResolvers<ListCatalogResult>();
  loadChat(frame, {}, sessions, { list: () => promise });
  frame.start();
  frame.paste("fix the ");
  frame.key("enter");
  frame.paste("test");
  resolve(CATALOG);
  await waitFor(() => sessions.inputs.length === 1);
  equal(sessions.inputs, [[{ user_text: "fix the test" }]]);
});

test("ctrl+k m after a failed open gives the notice of the open only", async () => {
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  sessions.state.openFails = 2;
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.key("ctrl+k m");
  await settle();
  frame.key("enter");
  await settle();
  frame.key("enter");
  await waitFor(() => chat.notices.length === 2);
  equal(chat.notices, [
    "error the session s1 did not open: Error: busy",
    "error the session s1 did not open: Error: busy",
  ]);
});

test("an image whose store finishes after an edit goes where the caret is then", async () => {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = loadChat(frame, {}, sessions);
  frame.start();
  await settle();
  frame.clipboard = PNG;
  const { promise, resolve } = Promise.withResolvers<void>();
  sessions.state.store = promise;
  frame.paste("ab");
  frame.key("ctrl+v");
  await settle();
  frame.key("home");
  frame.paste("x");
  resolve();
  await settle();
  equal(draft(composerOf(chat).state), ["x\uFFFCab", [[1, 2, "[image 1]"]]]);
});
