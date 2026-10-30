// The status items of the bundled chat: the model, the token share of the last answer, and the jobs of the focused pane.

import { writeTextFile } from "yuke:fs";
import type { Job, ListCatalogResult, StoredEvent } from "yuke:protocol";
import { createFrame, equal, folder, test } from "yuke:test";
import { CATALOG, commit, fakeSessions, loadChat, SETTINGS, settle } from "./chat.ts";

const HIGH = {
  ...SETTINGS,
  settings: { ...SETTINGS.settings, reasoning: { thinking: null, effort: "high" as const } },
};

/** A session on `p/m` at the level high, with one answer that used 30,000 input and 2,000 output tokens. */
const SAVED: StoredEvent[] = [
  { seq: 1, sessionUpdate: "settings", ...HIGH },
  commit(2, [{ assistant_text: "hi" }], {
    answer: {
      origin: { model: "m", baseUrl: "https://p" },
      usage: { input: 30_000, output: 2000, reasoning: null, cacheRead: null, cacheWrite: null },
      finishReason: "stop",
    },
  }),
];

const JOB = { id: "j1", command: "npm run dev", log: "/tmp/j1.log", state: "running" } as unknown as Job;

/** `CATALOG` with a context window of `window` tokens for `p/m`. */
function withWindow(window: number): ListCatalogResult {
  const [provider] = CATALOG.providers;
  const [model, ...others] = provider?.models ?? [];
  return {
    providers: [{ ...provider, models: [{ ...model, contextWindow: window }, ...others] }],
  } as ListCatalogResult;
}

test("the focused chat pane shows its model, its context use, and its jobs, and a focus elsewhere hides them", async () => {
  const sessions = fakeSessions(SAVED);
  sessions.state.jobs = [JOB];
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, sessions, { list: async () => withWindow(100_000) });
  // The catalog comes first, so only the open of the handle can show the jobs of the snapshot.
  await settle();
  frame.start();
  await settle();
  const items = (): string[][] => chat.tui.status.list().map((item) => [item.key, item.text]);
  const shown = items();
  sessions.push(
    commit(3, [{ assistant_text: "more" }], {
      answer: {
        origin: { model: "m", baseUrl: "https://p" },
        usage: { input: 60_000, output: 2000, reasoning: null, cacheRead: null, cacheWrite: null },
        finishReason: "stop",
      },
    }),
  );
  const live = items()[1];
  // A close by another client ends the handle, and its jobs leave the bar.
  sessions.close("s1");
  const closed = items().map((item) => item[0]);
  frame.surface("other").tui.panes.split(() => ({ draw() {}, focusable: true }));
  frame.draw();
  equal(
    [shown, live, closed, items()],
    [
      [
        ["chat:model", "m high"],
        ["chat:context", "▰▰▱▱▱▱ 32%"],
        ["chat:jobs", "jobs 1"],
      ],
      ["chat:context", "▰▰▰▰▱▱ 62%"],
      ["chat:model", "chat:context"],
      [],
    ],
  );
});

test("without a context window the context use is a token count", async () => {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions(SAVED));
  frame.start();
  await settle();
  equal(
    chat.tui.status.list().map((item) => [item.key, item.text]),
    [
      ["chat:model", "m high"],
      ["chat:context", "32.0k tokens"],
    ],
  );
});

test("an answer without an input count shows no context item", async () => {
  const [settings, saved] = SAVED;
  const unknown = commit(2, [{ assistant_text: "hi" }], {
    answer: {
      origin: { model: "m", baseUrl: "https://p" },
      usage: { input: null, output: 2000, reasoning: null, cacheRead: null, cacheWrite: null },
      finishReason: "stop",
    },
  });
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = loadChat(frame, {}, fakeSessions([settings as StoredEvent, unknown]));
  frame.start();
  await settle();
  equal([saved !== undefined, chat.tui.status.list().map((item) => item.key)], [true, ["chat:model"]]);
});

test("the first send of a new pane shows the jobs of its session once the handle opens", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  const sessions = fakeSessions();
  sessions.state.jobs = [JOB];
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w" });
  const chat = loadChat(frame, {}, sessions);
  await settle();
  frame.start();
  frame.paste("hi");
  frame.key("enter");
  while (sessions.inputs.length === 0) await settle();
  equal(
    chat.tui.status.list().map((item) => item.key),
    ["chat:model", "chat:jobs"],
  );
});

/** The keys of the status items of `chat` and their texts. */
function shownItems(chat: ReturnType<typeof loadChat>): string[][] {
  return chat.tui.status.list().map((item) => [item.key, item.text]);
}

/** Wait until `done` holds. A file operation ends on another thread. */
async function until(done: () => boolean): Promise<void> {
  while (!done()) await new Promise((resolve) => setTimeout(resolve, 5));
}

test("a pane without a session shows the saved pick, and a new pick replaces it", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w" });
  const chat = loadChat(frame);
  frame.start();
  await until(() => shownItems(chat).length > 0);
  const first = shownItems(chat);
  frame.key("ctrl+k m");
  await settle();
  frame.key("down");
  frame.key("enter");
  await settle();
  frame.key("down");
  frame.key("enter");
  await until(() => shownItems(chat)[0]?.[1] !== "m high");
  equal([first, shownItems(chat)], [[["chat:model", "m high"]], [["chat:model", "n low"]]]);
});

test("a saved pick that the catalog no longer has shows nothing", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"low"}', { baseDir: folder() });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w" });
  const chat = loadChat(frame);
  frame.start();
  // Nothing shows when the check works, so the test gives the read of the file a bounded time.
  for (let tries = 0; tries < 50 && shownItems(chat).length === 0; tries += 1) await settle();
  equal(shownItems(chat), []);
});

test("a pane whose session does not open shows no saved pick", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: "missing" });
  const chat = loadChat(frame);
  frame.start();
  // A new pane without a session shows the pick when the read of the file ends.
  chat.tui.commands.run("core:split-right");
  frame.draw();
  await until(() => shownItems(chat).length > 0);
  chat.tui.commands.run("core:focus-left");
  frame.draw();
  equal(shownItems(chat), []);
});
