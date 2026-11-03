// The status items of the bundled chat: the model, the token share of the last answer, and the jobs of the focused pane.

import { writeTextFile } from "yuke:fs";
import type { Job, StoredEvent } from "yuke:protocol";
import { createFrame, equal, folder, settled, test } from "yuke:test";
import { CATALOG, commit, fakeSessions, loadChat, SETTINGS } from "./chat.ts";
import { rows } from "./rows.ts";

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

const JOB: Job = {
  id: "j1",
  label: "npm run dev",
  state: "running",
  kind: "process",
  command: "npm run dev",
  log: "/tmp/j1.log",
};

test("the focused chat pane shows its model, its context use, and its process jobs, and a focus elsewhere hides them", async () => {
  const sessions = fakeSessions(SAVED);
  // A plugin shows its own jobs, so the count holds only the command.
  sessions.state.jobs = [
    JOB,
    { id: "reader", label: "Read the store", state: "running", kind: "plugin", plugin: "agents" },
  ];
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, sessions, {
    list: async () => ({
      providers: CATALOG.providers.map((provider) => ({
        ...provider,
        models: provider.models.map((model) => ({ ...model, contextWindow: 100_000 })),
      })),
    }),
  });
  frame.start();
  await settled();
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
  const chat = await loadChat(frame, fakeSessions(SAVED));
  frame.start();
  await settled();
  equal(
    chat.tui.status.list().map((item) => [item.key, item.text]),
    [
      ["chat:model", "m high"],
      ["chat:context", "32.0k tokens"],
    ],
  );
});

test("an answer without an input count shows no context item", async () => {
  const [settings] = SAVED;
  const unknown = commit(2, [{ assistant_text: "hi" }], {
    answer: {
      origin: { model: "m", baseUrl: "https://p" },
      usage: { input: null, output: 2000, reasoning: null, cacheRead: null, cacheWrite: null },
      finishReason: "stop",
    },
  });
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions([settings as StoredEvent, unknown]));
  frame.start();
  await settled();
  equal(
    chat.tui.status.list().map((item) => item.key),
    ["chat:model"],
  );
});

test("the first send of a new pane shows the jobs of its session once the handle opens", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  const sessions = fakeSessions();
  sessions.state.jobs = [JOB];
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w" });
  const chat = await loadChat(frame, sessions);
  await settled();
  frame.start();
  frame.paste("hi");
  frame.key("enter");
  await settled();
  equal(sessions.inputs.length, 1);
  equal(
    chat.tui.status.list().map((item) => item.key),
    ["chat:model", "chat:jobs"],
  );
});

/** The keys of the status items of `chat` and their texts. */
function shownItems(chat: Awaited<ReturnType<typeof loadChat>>): string[][] {
  return chat.tui.status.list().map((item) => [item.key, item.text]);
}

test("a pane without a session shows the saved pick, and a new pick replaces it", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w" });
  const chat = await loadChat(frame);
  frame.start();
  const first = shownItems(chat);
  frame.key("ctrl+k m");
  await settled();
  frame.draw();
  equal(rows(frame.frame).includes("p/m"), true);
  frame.key("down");
  frame.key("enter");
  await settled();
  frame.draw();
  equal(rows(frame.frame).includes("low"), true);
  frame.key("down");
  frame.key("enter");
  await settled();
  equal([first, shownItems(chat)], [[["chat:model", "m high"]], [["chat:model", "n low"]]]);
});

test("a saved pick that the catalog no longer has shows nothing", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"low"}', { baseDir: folder() });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w" });
  const chat = await loadChat(frame);
  frame.start();
  equal(shownItems(chat), []);
});

test("a pane whose session does not open shows no saved pick", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    baseDir: folder(),
  });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: "missing" });
  const chat = await loadChat(frame);
  frame.start();
  // Activation loaded the pick, so the new pane shows it at once.
  chat.tui.commands.run("core:split-right");
  frame.draw();
  chat.tui.commands.run("core:focus-left");
  frame.draw();
  equal(shownItems(chat), []);
});
