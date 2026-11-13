// The tests use the blocks of `yuke:chat` without a pane. They cover the sessions, the pages, the composer, the
// questions, and the working row.

import { ChatComposer, ChatQuestions, ChatSession, ChatWorking } from "yuke:chat";
import type { Sessions } from "yuke:plugins";
import type { StoredEvent } from "yuke:protocol";
import { assertEquals, test, waitForSettled } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { commit, fakeSessions, replies, SETTINGS } from "./tui/chat.ts";

/** The texts of the replies in the transcript of `chat`. */
function texts(chat: ChatSession): string[] {
  return chat.transcript.entries.flatMap((entry) => (entry.kind === "text" ? [entry.text] : []));
}

test("a failed open keeps the shown session, and a later open shows its own transcript and ends the old handle", async () => {
  const sessions = fakeSessions(replies(2));
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: new AbortController().signal, id: "s1" });
  await chat.open("s1");
  const first = chat.transcript;
  let failure = "";
  await chat.open("missing").catch((error: unknown) => {
    failure = String(error);
  });
  const kept = [chat.id, chat.transcript === first, chat.handle !== undefined];
  await chat.open("s2");
  sessions.push(commit(3, [{ kind: "assistantText", text: "in s2" }]), "s2");
  assertEquals(
    [failure, kept, chat.id, chat.transcript === first, texts(chat).at(-1)],
    ["Error: no session missing", ["s1", true, true], "s2", false, "in s2"],
  );
  assertEquals(
    sessions.opened.map((open) => [open.id, open.signal.aborted]),
    [
      ["s1", true],
      ["missing", true],
      ["s2", false],
    ],
  );
});

test("ensure creates the first session once, and a missing choice creates none", async () => {
  const sessions = fakeSessions(replies(2));
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: new AbortController().signal });
  const none = await chat.ensure(async () => undefined);
  const first = await chat.ensure(async () => SETTINGS);
  const again = await chat.ensure(async () => SETTINGS);
  assertEquals([none, first === again, chat.id, sessions.created.length], [undefined, true, "s-new", 1]);
});

test("ensure opens the session again after the end of its handle", async () => {
  const sessions = fakeSessions(replies(2));
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: new AbortController().signal, id: "s1" });
  await chat.open("s1");
  const changes: (boolean | undefined)[] = [];
  chat.addChangeListener(() => changes.push(chat.handle !== undefined));
  sessions.close("s1");
  const handle = await chat.ensure(async () => undefined);
  assertEquals([changes.slice(0, 1), handle === chat.handle, sessions.opened.length], [[false], true, 2]);
});

test("a page that fails after the open of another session leaves the history of that session open", async () => {
  const sessions = fakeSessions(replies(250));
  const { promise, reject } = Promise.withResolvers<readonly StoredEvent[]>();
  let held = true;
  const store = {
    ...sessions,
    events: (id: string, page: { before?: number; limit: number }) => (held ? promise : sessions.events(id, page)),
  };
  const chat = new ChatSession(store as unknown as Sessions, { signal: new AbortController().signal, id: "s1" });
  await chat.open("s1");
  const page = chat.loadOlderHistory();
  await chat.open("s2");
  const before = chat.transcript.entries.length;
  reject(new Error("disk"));
  await page;
  held = false;
  await chat.loadOlderHistory();
  assertEquals([chat.historyError, chat.transcript.entries.length > before], [undefined, true]);
});

test("trimHistory drops the history older than an open one page late, and a page loads it again", async () => {
  const sessions = fakeSessions(replies(201));
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: new AbortController().signal, id: "s1" });
  await chat.open("s1");
  await chat.loadOlderHistory();
  await chat.loadOlderHistory();
  const reply = (seq: number) => commit(seq, [{ kind: "assistantText", text: `reply ${seq}` }]);
  for (let seq = 202; seq <= 300; seq += 1) sessions.push(reply(seq));
  chat.trimHistory();
  const within = [chat.transcript.held, chat.historyComplete];
  sessions.push(reply(301));
  chat.trimHistory();
  const trimmed = [chat.transcript.held, chat.transcript.first, chat.historyComplete, texts(chat).at(0)];
  await chat.loadOlderHistory();
  assertEquals(
    [within, trimmed, chat.transcript.held, texts(chat).at(0)],
    [[300, true], [200, 102, false, "reply 102"], 300, "reply 2"],
  );
});

test("two calls of ensure without a session create one session", async () => {
  const sessions = fakeSessions(replies(2));
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: new AbortController().signal });
  const [first, second] = await Promise.all([chat.ensure(async () => SETTINGS), chat.ensure(async () => SETTINGS)]);
  assertEquals([first === second, sessions.created.length, sessions.opened.length], [true, 1, 1]);
});

test("an end of the handle after the snapshot leaves the target shown without a handle", async () => {
  const sessions = fakeSessions(replies(2));
  const store = {
    ...sessions,
    open: async (id: string, options: never) => {
      await sessions.open(id, options);
      throw new Error(`the session ${id} closed`);
    },
  };
  const chat = new ChatSession(store as unknown as Sessions, { signal: new AbortController().signal, id: "s1" });
  await chat.open("s1");
  const failure = await chat
    .ensure(async () => undefined)
    .then(
      () => "",
      (error: unknown) => String(error),
    );
  assertEquals(
    [chat.id, chat.handle, texts(chat), failure],
    ["s1", undefined, ["reply 2"], "Error: the session s1 closed"],
  );
});

test("the end of the owner ends the handle and its hold", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  await chat.open("s1");
  owner.abort();
  assertEquals([chat.handle, sessions.opened.map((open) => open.signal.aborted)], [undefined, [true]]);
});

test("a composer sends the draft, and a refused input comes back above newer text and rejects", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  await chat.open("s1");
  const editor = new TextEditor();
  const composer = new ChatComposer(chat, editor, { handle: async () => chat.handle, signal: owner.signal });
  editor.replace(0, 0, "first");
  await composer.send();
  const { promise, reject } = Promise.withResolvers<void>();
  sessions.state.accept = promise;
  editor.replace(0, 0, "second");
  const sending = composer.send().then(
    () => "",
    (error: unknown) => String(error),
  );
  // The send takes the draft after the handle comes, so later text stays in the editor.
  await waitForSettled();
  editor.replace(0, 0, "newer");
  reject(new Error("refused"));
  assertEquals(
    [sessions.inputs, await sending, editor.state.text],
    [
      [[{ kind: "userText", text: "first" }], [{ kind: "userText", text: "second" }]],
      "Error: refused",
      "second\nnewer",
    ],
  );
});

test("a composer makes one span of a long paste, and a paste handler added later takes a paste first", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  const editor = new TextEditor();
  new ChatComposer(chat, editor, { handle: async () => chat.handle, signal: owner.signal });
  editor.onPaste("a".repeat(301));
  const spanCount = editor.state.spans.length;
  editor.reset({ text: "", selection: { anchor: 0, head: 0 }, spans: [] });
  editor.extend(owner.signal).addPasteHandler((text) => {
    editor.replace(0, 0, "claimed");
    return text.length > 0;
  });
  editor.onPaste("b".repeat(301));
  assertEquals([spanCount, editor.state.text, editor.state.spans], [1, "claimed", []]);
});

test("attachImage stores the image and puts it over the selection, and an abort during the handle stores nothing", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  await chat.open("s1");
  const editor = new TextEditor({ state: { text: "abc", selection: { anchor: 2, head: 1 }, spans: [] } });
  const composer = new ChatComposer(chat, editor, { handle: async () => chat.handle, signal: owner.signal });
  await composer.attachImage({ bytes: new Uint8Array([1, 2]), mimeType: "image/png" });
  const attached = [editor.state.text, editor.state.spans.map((span) => [span.from, span.label])];
  const closed = new AbortController();
  const handle = async () => {
    closed.abort();
    return chat.handle;
  };
  await new ChatComposer(chat, new TextEditor(), { handle, signal: closed.signal }).attachImage({
    bytes: new Uint8Array([3]),
    mimeType: "image/png",
  });
  assertEquals([attached, sessions.blobs], [["a\uFFFCc", [[1, "[image 1]"]]], [[1, 2]]]);
});

test("a send before the store of an attach ends does nothing, so the image goes with its draft", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  await chat.open("s1");
  const editor = new TextEditor({ state: { text: "hello", selection: { anchor: 5, head: 5 }, spans: [] } });
  const composer = new ChatComposer(chat, editor, { handle: async () => chat.handle, signal: owner.signal });
  const store = Promise.withResolvers<void>();
  sessions.state.store = store.promise;
  const attaching = composer.attachImage({ bytes: new Uint8Array([1]), mimeType: "image/png" });
  await waitForSettled();
  const busy = composer.busy;
  await composer.send();
  const early = [...sessions.inputs];
  store.resolve();
  await attaching;
  await composer.send();
  assertEquals(
    [busy, early, sessions.inputs, composer.busy],
    [
      true,
      [],
      [
        [
          { kind: "userText", text: "hello" },
          { kind: "media", blob: { digest: "d1", len: 1 }, mimeType: "image/png" },
        ],
      ],
      false,
    ],
  );
});

test("older recalls the newest waiting message, and gives taken when a turn took it first", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  await chat.open("s1");
  const editor = new TextEditor();
  const composer = new ChatComposer(chat, editor, { handle: async () => chat.handle, signal: owner.signal });
  const waiting = (id: number, text: string) =>
    sessions.push({
      sessionUpdate: "inputAccepted",
      inputId: id,
      input: { source: { kind: "user" }, kind: "message", content: [{ kind: "userText", text: text }] },
    });
  waiting(5, "older");
  waiting(6, "newest");
  const recalled = await composer.olderMessage();
  const text = editor.state.text;
  sessions.state.removed = false;
  const taken = await composer.olderMessage();
  assertEquals([recalled, text, taken, composer.waiting.map((entry) => entry[0])], [undefined, "newest", "taken", [5]]);
});

test("the questions show the first open one, a cancel answers it once, and a refused answer goes to failed and stays open", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  await chat.open("s1");
  const failures: string[] = [];
  const questions = new ChatQuestions(chat, { signal: owner.signal, onError: (error) => failures.push(String(error)) });
  let changes = 0;
  questions.addChangeListener(() => {
    changes += 1;
  });
  const ask = (id: number) =>
    sessions.push({
      sessionUpdate: "interactionRequested",
      interactionId: id,
      source: "guard",
      request: {
        kind: "questions",
        questions: [{ id: "go", header: "Go", question: `Step ${id}?`, options: [{ label: "Yes" }, { label: "No" }] }],
      },
    });
  ask(7);
  ask(8);
  const first = questions.current;
  questions.cancel();
  questions.cancel();
  sessions.state.refuseAnswer = true;
  await waitForSettled();
  const second = questions.current;
  // A refused answer leaves the question open for the next answer.
  questions.cancel();
  questions.cancel();
  assertEquals(
    [first !== undefined, second !== undefined && second !== first, sessions.responses, failures, changes],
    [true, true, [[7, { kind: "cancelled" }]], ["Error: no open question 8", "Error: no open question 8"], 2],
  );
});

test("questions that start after a question opened show it at once", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  await chat.open("s1");
  sessions.push({
    sessionUpdate: "interactionRequested",
    interactionId: 3,
    source: "guard",
    request: {
      kind: "questions",
      questions: [{ id: "go", header: "Go", question: "Go?", options: [{ label: "Yes" }, { label: "No" }] }],
    },
  });
  const questions = new ChatQuestions(chat, { signal: owner.signal, onError: () => {} });
  assertEquals(questions.current !== undefined, true);
});

test("the timer counts from observation, resets for another session, and stops when the handle ends", async () => {
  // Each open gives a snapshot of a running turn.
  const sessions = fakeSessions([...replies(2), { sessionUpdate: "state", state: "running" } as never]);
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, { signal: owner.signal, id: "s1" });
  await chat.open("s1");
  let now = 10_000;
  const working = new ChatWorking(chat, { signal: owner.signal, now: () => now });
  const changes: boolean[] = [];
  working.addChangeListener(() => changes.push(working.active));
  now = 71_000;
  const first = working.text({ cancelKey: "esc" })?.text;
  await chat.open("s2");
  const second = working.text()?.text;
  // An event that keeps the turn running changes no `active`.
  sessions.push(commit(3, [{ kind: "assistantText", text: "more" }]), "s2");
  sessions.close("s2");
  assertEquals(
    [first, second, working.text(), changes],
    ["Working… (1m 01s · esc to interrupt)", "Working… (0s)", undefined, [false, true, false]],
  );
});
