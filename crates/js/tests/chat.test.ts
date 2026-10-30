// The tests use the blocks of `yuke:chat` without a pane. They cover the sessions, the pages, the composer, and the
// questions.

import { ChatComposer, ChatQuestions, ChatSession } from "yuke:chat";
import type { Sessions } from "yuke:plugins";
import type { StoredEvent } from "yuke:protocol";
import { equal, test } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { commit, fakeSessions, replies, SETTINGS, settle } from "./tui/chat.ts";

/** The texts of the replies in the transcript of `chat`. */
function texts(chat: ChatSession): string[] {
  return chat.transcript.entries.flatMap((entry) => (entry.kind === "text" ? [entry.text] : []));
}

test("a failed open keeps the shown session, and a later open shows its own transcript and ends the old handle", async () => {
  const sessions = fakeSessions(replies(2));
  const chat = new ChatSession(sessions as unknown as Sessions, new AbortController().signal, "s1");
  await chat.open("s1");
  const first = chat.transcript;
  let failure = "";
  await chat.open("missing").catch((error: unknown) => {
    failure = String(error);
  });
  const kept = [chat.id, chat.transcript === first, chat.handle !== undefined];
  await chat.open("s2");
  sessions.push(commit(3, [{ assistant_text: "in s2" }]), "s2");
  equal(
    [failure, kept, chat.id, chat.transcript === first, texts(chat).at(-1)],
    ["Error: no session missing", ["s1", true, true], "s2", false, "in s2"],
  );
  equal(
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
  const chat = new ChatSession(sessions as unknown as Sessions, new AbortController().signal);
  const none = await chat.ensure(async () => undefined);
  const first = await chat.ensure(async () => SETTINGS);
  const again = await chat.ensure(async () => SETTINGS);
  equal([none, first === again, chat.id, sessions.created.length], [undefined, true, "s-new", 1]);
});

test("ensure opens the session again after the end of its handle", async () => {
  const sessions = fakeSessions(replies(2));
  const chat = new ChatSession(sessions as unknown as Sessions, new AbortController().signal, "s1");
  await chat.open("s1");
  const changes: (boolean | undefined)[] = [];
  chat.onChange(() => changes.push(chat.handle !== undefined));
  sessions.close("s1");
  const handle = await chat.ensure(async () => undefined);
  equal([changes.slice(0, 1), handle === chat.handle, sessions.opened.length], [[false], true, 2]);
});

test("a page that fails after the open of another session leaves the history of that session open", async () => {
  const sessions = fakeSessions(replies(250));
  const { promise, reject } = Promise.withResolvers<readonly StoredEvent[]>();
  let held = true;
  const store = {
    ...sessions,
    events: (id: string, page: { before?: number; limit: number }) => (held ? promise : sessions.events(id, page)),
  };
  const chat = new ChatSession(store as unknown as Sessions, new AbortController().signal, "s1");
  await chat.open("s1");
  const page = chat.older();
  await chat.open("s2");
  const before = chat.transcript.entries.length;
  reject(new Error("disk"));
  await page;
  held = false;
  await chat.older();
  equal([chat.historyError, chat.transcript.entries.length > before], [undefined, true]);
});

test("two calls of ensure without a session create one session", async () => {
  const sessions = fakeSessions(replies(2));
  const chat = new ChatSession(sessions as unknown as Sessions, new AbortController().signal);
  const [first, second] = await Promise.all([chat.ensure(async () => SETTINGS), chat.ensure(async () => SETTINGS)]);
  equal([first === second, sessions.created.length, sessions.opened.length], [true, 1, 1]);
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
  const chat = new ChatSession(store as unknown as Sessions, new AbortController().signal, "s1");
  await chat.open("s1");
  const failure = await chat
    .ensure(async () => undefined)
    .then(
      () => "",
      (error: unknown) => String(error),
    );
  equal([chat.id, chat.handle, texts(chat), failure], ["s1", undefined, ["reply 2"], "Error: the session s1 closed"]);
});

test("the end of the owner ends the handle and its hold", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, owner.signal, "s1");
  await chat.open("s1");
  owner.abort();
  equal([chat.handle, sessions.opened.map((open) => open.signal.aborted)], [undefined, [true]]);
});

test("a composer sends the draft, and a refused input comes back above newer text and rejects", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, owner.signal, "s1");
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
  await settle();
  editor.replace(0, 0, "newer");
  reject(new Error("refused"));
  equal(
    [sessions.inputs, await sending, editor.state.text],
    [[[{ user_text: "first" }], [{ user_text: "second" }]], "Error: refused", "second\nnewer"],
  );
});

test("older recalls the newest waiting message, and gives taken when a turn took it first", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, owner.signal, "s1");
  await chat.open("s1");
  const editor = new TextEditor();
  const composer = new ChatComposer(chat, editor, { handle: async () => chat.handle, signal: owner.signal });
  const waiting = (id: number, text: string) =>
    sessions.push({
      sessionUpdate: "input_accepted",
      inputId: id,
      input: { source: { kind: "user" }, kind: "message", content: [{ user_text: text }] },
    });
  waiting(5, "older");
  waiting(6, "newest");
  const recalled = await composer.older();
  const text = editor.state.text;
  sessions.state.removed = false;
  const taken = await composer.older();
  equal([recalled, text, taken, composer.waiting.map((entry) => entry[0])], [undefined, "newest", "taken", [5]]);
});

test("the questions show the first open one, a cancel answers it once, and a refused answer goes to failed and stays open", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, owner.signal, "s1");
  await chat.open("s1");
  const failures: string[] = [];
  const questions = new ChatQuestions(chat, { signal: owner.signal, failed: (error) => failures.push(String(error)) });
  let changes = 0;
  questions.onChange(() => {
    changes += 1;
  });
  const ask = (id: number) =>
    sessions.push({
      sessionUpdate: "interaction_requested",
      interactionId: id,
      source: "guard",
      request: { kind: "confirm", title: `Step ${id}?`, message: "" },
    });
  ask(7);
  ask(8);
  const first = questions.current;
  questions.cancel();
  questions.cancel();
  sessions.state.refuseAnswer = true;
  await settle();
  const second = questions.current;
  // A refused answer leaves the question open for the next answer.
  questions.cancel();
  questions.cancel();
  equal(
    [first !== undefined, second !== undefined && second !== first, sessions.responses, failures, changes],
    [true, true, [[7, { kind: "canceled" }]], ["Error: no open question 8", "Error: no open question 8"], 2],
  );
});

test("questions that start after a question opened show it at once", async () => {
  const sessions = fakeSessions(replies(2));
  const owner = new AbortController();
  const chat = new ChatSession(sessions as unknown as Sessions, owner.signal, "s1");
  await chat.open("s1");
  sessions.push({
    sessionUpdate: "interaction_requested",
    interactionId: 3,
    source: "guard",
    request: { kind: "confirm", title: "Go?", message: "" },
  });
  const questions = new ChatQuestions(chat, { signal: owner.signal, failed: () => {} });
  equal(questions.current !== undefined, true);
});
