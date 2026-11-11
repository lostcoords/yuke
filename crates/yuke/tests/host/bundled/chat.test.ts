// The bundled plugin `chat` on the sessions of a test host: the transcript of a pane, live and after a reload.

import type { ChatService } from "yuke:chat";
import { writeTextFile } from "yuke:fs";
import { apply as chat } from "yuke:internal/bundled/chat";
import type { PluginSession, Sessions } from "yuke:plugins";
import type { SessionSettings } from "yuke:protocol";
import { assert, createFrame, createHost, equal, type FrameTest, folder, reply, test, waitForSettled } from "yuke:test";

/** A plugin whose session defines the tool `greet`, which answers `hello` and its argument. */
const greeter: PluginSession = (s) => {
  s.tools.add({
    name: "greet",
    description: "Greet someone.",
    concurrency: "serial",
    parameters: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
    execute: (args) => `hello ${args.who}`,
  });
};

/** A frame with a chat pane on the session `id` of `sessions`. */
async function chatFrame(sessions: Sessions, id: string): Promise<FrameTest> {
  const frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: id });
  const surface = frame.surface("chat");
  const services: Record<string, unknown> = {
    tui: surface.tui,
    sessions,
    catalog: { list: async () => ({ providers: [] }) },
  };
  await chat({
    get: (name: string) => services[name],
    addListener: () => () => {},
    provide() {},
    options: {},
    signal: surface.signal,
    dataDir: folder(),
    notify() {},
  } as never);
  frame.start();
  return frame;
}

function rows(frame: FrameTest): string[] {
  return frame.frame.cells.map((row) =>
    row
      .map((cell) => cell.text)
      .join("")
      .trimEnd(),
  );
}

test("a pane draws the same transcript live and after a reload", async () => {
  let sessions: Sessions | undefined;
  await using host = await createHost({
    plugins: [
      {
        name: "keeper",
        apply: (ctx) => {
          sessions = ctx.get("sessions");
          return undefined;
        },
      },
      { name: "greeter", session: greeter },
    ],
    replies: [reply.toolCall("greet", { who: "Ada" }), reply.text("**Done**.")],
  });
  const session = await host.openSession();
  const service = sessions as Sessions;
  using live = await chatFrame(service, session.id);
  await session.sendMessage("Greet Ada.");
  await waitForSettled();
  live.draw();
  using reloaded = await chatFrame(service, session.id);
  await waitForSettled();
  reloaded.draw();
  for (const text of ["Greet Ada.", "hello Ada", "Done."]) {
    assert(
      rows(live).some((row) => row.includes(text)),
      `the live pane lacks ${text}`,
    );
  }
  equal(rows(reloaded), rows(live));
});

test("the first send of a pane with a saved choice creates its session and gets the answer", async () => {
  let services: { readonly sessions: Sessions; readonly catalog: unknown } | undefined;
  await using host = await createHost({
    plugins: [
      {
        name: "keeper",
        apply: (ctx) => {
          services = { sessions: ctx.get("sessions"), catalog: ctx.get("catalog") };
          return undefined;
        },
      },
    ],
    replies: [reply.text("Hi there.")],
  });
  await writeTextFile("choice.json", '{"model":{"provider":"minimax","model":"MiniMax-M3"},"reasoning":"high"}', {
    cwd: folder(),
  });
  const startup = { cwd: folder() };
  using frame = createFrame({ width: 30, height: 10 }, undefined, startup);
  const surface = frame.surface("chat");
  const known = services as { readonly sessions: Sessions; readonly catalog: unknown };
  const get = (name: string) => (name === "tui" ? surface.tui : name === "catalog" ? known.catalog : known.sessions);
  await chat({
    get,
    addListener: () => () => {},
    provide() {},
    options: {},
    signal: surface.signal,
    dataDir: folder(),
    notify() {},
  } as never);
  frame.start();
  frame.paste("hello");
  frame.key("enter");
  await waitForSettled();
  frame.draw();
  equal(rows(frame).slice(0, 4), ["", " hello", "", " Hi there."]);
  equal(host.requests.at(-1)?.messages.at(-1)?.text, "hello");
});

test("chat.show opens a session with a parent: the pane shows its transcript, and a message goes to it", async () => {
  let sessions: Sessions | undefined;
  let settings: SessionSettings | undefined;
  await using host = await createHost({
    plugins: [
      {
        name: "keeper",
        apply: (ctx) => {
          sessions = ctx.get("sessions");
          return undefined;
        },
        session: (s) => {
          settings = s.settings;
        },
      },
    ],
    replies: [reply.text("Two tables."), reply.text("Three indexes.")],
  });
  const parent = await host.openSession();
  const list = sessions as unknown as Sessions;
  const child = await list.create(settings as unknown as SessionSettings, { parent: parent.id });
  const held = await list.open(child, { tail: 0, onEvent() {} });
  await held.sendMessage({ content: [{ user_text: "Read the store." }] });
  await held.waitForIdle();

  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: parent.id });
  const surface = frame.surface("chat");
  const services: Record<string, unknown> = {
    tui: surface.tui,
    sessions: list,
    catalog: { list: async () => ({ providers: [] }) },
  };
  let shown: ChatService | undefined;
  await chat({
    get: (name: string) => services[name],
    addListener: () => () => {},
    provide: (_name: string, service: ChatService) => {
      shown = service;
    },
    options: {},
    signal: surface.signal,
    dataDir: folder(),
    notify() {},
  } as never);
  frame.start();
  await waitForSettled();
  await (shown as unknown as ChatService).show(child);
  await waitForSettled();
  frame.draw();
  const text = rows(frame).join("\n");

  frame.paste("And the indexes?");
  frame.key("enter");
  await waitForSettled();
  await held.waitForIdle();
  await waitForSettled();
  frame.draw();

  equal(text.includes("Two tables."), true);
  equal(rows(frame).join("\n").includes("Three indexes."), true);
  equal(host.requests.at(-1)?.messages.at(-1)?.text, "And the indexes?");
});
