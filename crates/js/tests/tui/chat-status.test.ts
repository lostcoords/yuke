// The status items of the bundled chat: the folder, the model, the token share of the last answer, and the jobs of the
// focused pane.

import { writeTextFile } from "yuke:fs";
import { env } from "yuke:process";
import type { Job, ProviderInfo, ProviderState, StoredEvent } from "yuke:protocol";
import { assertEquals, createFrame, folder, test, waitForSettled } from "yuke:test";
import type { StatusItem } from "yuke:tui";
import { CATALOG, commit, fakeSessions, loadChat, SETTINGS } from "./chat.ts";
import { rows } from "./rows.ts";

/** The status items of the chat, without the folder, which a test of its own covers. */
function listed(chat: Awaited<ReturnType<typeof loadChat>>): readonly StatusItem[] {
  return chat.tui.status.list().filter((item) => item.id !== "chat:folder");
}

const HIGH = {
  ...SETTINGS,
  settings: { ...SETTINGS.settings, reasoning: { effort: "high" as const } },
};

/** A session on `p/m` at the level high, with one answer that used 30,000 input and 2,000 output tokens. */
const SAVED: StoredEvent[] = [
  { seq: 1, sessionUpdate: "settings", ...HIGH },
  commit(2, [{ kind: "assistantText", text: "hi" }], {
    answer: {
      origin: { model: "m", baseUrl: "https://p" },
      usage: { input: 30_000, output: 2000 },
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
  await waitForSettled();
  const items = (): string[][] => listed(chat).map((item) => [item.id, item.text]);
  const shown = items();
  sessions.push(
    commit(3, [{ kind: "assistantText", text: "more" }], {
      answer: {
        origin: { model: "m", baseUrl: "https://p" },
        usage: { input: 60_000, output: 2000 },
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
  assertEquals(
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
  await waitForSettled();
  assertEquals(
    listed(chat).map((item) => [item.id, item.text]),
    [
      ["chat:model", "m high"],
      ["chat:context", "32.0k tokens"],
    ],
  );
});

test("an answer without an input count shows no context item", async () => {
  const [settings] = SAVED;
  const unknown = commit(2, [{ kind: "assistantText", text: "hi" }], {
    answer: {
      origin: { model: "m", baseUrl: "https://p" },
      usage: { output: 2000 },
      finishReason: "stop",
    },
  });
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions([settings as StoredEvent, unknown]));
  frame.start();
  await waitForSettled();
  assertEquals(
    listed(chat).map((item) => item.id),
    ["chat:model"],
  );
});

test("the first send of a new pane shows the jobs of its session once the handle opens", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    cwd: folder(),
  });
  const sessions = fakeSessions();
  sessions.state.jobs = [JOB];
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w" });
  const chat = await loadChat(frame, sessions);
  await waitForSettled();
  frame.start();
  frame.paste("hi");
  frame.key("enter");
  await waitForSettled();
  assertEquals(sessions.inputs.length, 1);
  assertEquals(
    listed(chat).map((item) => item.id),
    ["chat:model", "chat:jobs"],
  );
});

/** The keys of the status items of `chat` and their texts. */
function shownItems(chat: Awaited<ReturnType<typeof loadChat>>): string[][] {
  return listed(chat).map((item) => [item.id, item.text]);
}

test("a pane without a session shows the saved pick, and a new pick replaces it", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    cwd: folder(),
  });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w" });
  const chat = await loadChat(frame);
  frame.start();
  const first = shownItems(chat);
  frame.key("ctrl+k m");
  await waitForSettled();
  frame.draw();
  assertEquals(rows(frame.frame).includes("p/m"), true);
  frame.key("down");
  frame.key("enter");
  await waitForSettled();
  frame.draw();
  assertEquals(rows(frame.frame).includes("low"), true);
  frame.key("down");
  frame.key("enter");
  await waitForSettled();
  assertEquals([first, shownItems(chat)], [[["chat:model", "m high"]], [["chat:model", "n low"]]]);
});

test("a saved pick that the catalog no longer has shows nothing", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"low"}', { cwd: folder() });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w" });
  const chat = await loadChat(frame);
  frame.start();
  assertEquals(shownItems(chat), []);
});

test("a pane whose session does not open shows no saved pick", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    cwd: folder(),
  });
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: "missing" });
  const chat = await loadChat(frame);
  frame.start();
  // Activation loaded the pick, so the new pane shows it at once.
  chat.tui.commands.run("core:split-right");
  frame.draw();
  chat.tui.commands.run("core:focus-left");
  frame.draw();
  assertEquals(shownItems(chat), []);
});

test("the bar of a session of a provider that was not ready at the start shows its level after a catalog change", async () => {
  using frame = createFrame({ width: 60, height: 10 }, undefined, { cwd: "/launch", session: "s1" });
  // The provider is not ready at the start, and a login makes it ready.
  let ready = false;
  const catalog = { list: async () => (ready ? CATALOG : { providers: [] }) };
  const chat = await loadChat(frame, fakeSessions(SAVED), catalog);
  frame.start();
  await waitForSettled();
  frame.draw();
  const model = (): string | undefined => listed(chat).find((item) => item.id === "chat:model")?.text;
  const before = model();

  ready = true;
  chat.fact("catalog.changed", undefined);
  await waitForSettled();

  assertEquals([before, model()], ["m", "m high"]);
});

test("the bar hides a saved pick of a provider that is not ready, and a new pick after a login shows", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"high"}', {
    cwd: folder(),
  });
  using frame = createFrame({ width: 60, height: 12 }, undefined, { cwd: "/launch" });
  let state: ProviderState = { kind: "needsLogin" };
  const providers = (): ProviderInfo[] => CATALOG.providers.map((provider) => ({ ...provider, state })) as never;
  const catalog = { list: async () => ({ providers: state.kind === "ready" ? providers() : [] }) };
  const chat = await loadChat(frame, fakeSessions(), catalog);
  frame.start();
  await waitForSettled();
  frame.draw();
  const model = (): string | undefined => listed(chat).find((item) => item.id === "chat:model")?.text;
  const before = model();

  state = { kind: "ready", credential: { kind: "storedApiKey" } };
  // As the host does after a login.
  chat.fact("catalog.changed", undefined);
  chat.tui.commands.run("chat:model");
  await waitForSettled();
  frame.key("enter");
  await waitForSettled();
  frame.key("h i g h enter");
  await waitForSettled();

  assertEquals([before, model()], [undefined, "m high"]);
});

test("the folder item shows the folder of the session, and a pane without one shows the start folder with ~ for home", async () => {
  const home = env.get("HOME") ?? "/home";
  using frame = createFrame({ width: 60, height: 10 }, undefined, { cwd: `${home}/launch` });
  const chat = await loadChat(frame, fakeSessions(SAVED));
  frame.start();
  await waitForSettled();
  const shown = (): string | undefined => chat.tui.status.list().find((item) => item.id === "chat:folder")?.text;
  const before = shown();

  await chat.chat.show("s1");
  await waitForSettled();

  assertEquals([before, shown()], ["~/launch", "/w"]);
});
