// The bundled plugin `chat` on the sessions of a test host: the transcript of a pane, live and after a reopen.

import type { ChatService } from "yuke:chat";
import { mkdir, writeTextFile } from "yuke:fs";
import type { PluginContext, PluginSession, SessionContext, Sessions } from "yuke:plugins";
import type { SessionSettings } from "yuke:protocol";
import {
  assert,
  assertEquals,
  createFrame,
  createHost,
  type FrameTest,
  folder,
  type PluginUnderTest,
  reply,
  test,
  waitForSettled,
} from "yuke:test";

/** A plugin whose session defines the tool `greet`, which answers `hello` and its argument. */
const greeter: PluginSession = (s) => {
  s.tools.add({
    name: "greet",
    description: "Greet someone.",
    concurrency: "serial",
    inputSchema: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
    execute: (args) => `hello ${args.who}`,
  });
};

/** The services that the plugin `probe` reads at its load. */
interface Probed {
  chat: ChatService;
  sessions: Sessions;
  settings: SessionSettings;
}

/** The plugin `probe`, which keeps the chat service, the sessions, and the settings of its last session in `probed`. */
function probe(probed: Partial<Probed>): PluginUnderTest {
  return {
    name: "probe",
    uses: ["chat"],
    apply: (ctx: PluginContext) => {
      probed.chat = ctx.get("chat");
      probed.sessions = ctx.get("sessions");
      return undefined;
    },
    session: (s: SessionContext) => {
      probed.settings = s.settings;
    },
  };
}

/** Let the host work, then give the text of the rows of the frame. */
async function shown(frame: FrameTest): Promise<string> {
  await waitForSettled();
  return frame.rows().join("\n");
}

test("a pane draws the same transcript live and after a reopen", async () => {
  const probed: Partial<Probed> = {};
  using frame = createFrame({ width: 30, height: 14 }, undefined, { folder: "/w" });
  await using host = await createHost({
    frame,
    plugins: [{ bundled: "chat" }, probe(probed), { name: "greeter", session: greeter }],
    replies: [reply.toolCalls([{ name: "greet", args: { who: "Ada" } }]), reply.text("**Done**.")],
  });
  const chat = probed.chat as ChatService;
  const session = await host.openSession();
  const other = await host.openSession();
  frame.start();
  await chat.show(session.id);
  await session.sendMessage("Greet Ada.");
  const live = await shown(frame);
  await chat.show(other.id);
  await chat.show(session.id);
  const reopened = await shown(frame);

  for (const text of ["Greet Ada.", "hello Ada", "Done."]) assert(live.includes(text), `the live pane lacks ${text}`);
  assertEquals(reopened, live);
});

test("the first send of a pane with a saved choice creates its session and gets the answer", async () => {
  const dataDir = `${folder()}/chat`;
  await mkdir(dataDir);
  await writeTextFile(
    `${dataDir}/choice.json`,
    '{"model":{"provider":"minimax","model":"MiniMax-M3"},"reasoning":"high"}',
  );
  using frame = createFrame({ width: 30, height: 10 }, undefined, { folder: folder() });
  await using host = await createHost({
    frame,
    plugins: [{ bundled: "chat", dataDir }],
    replies: [reply.text("Hi there.")],
  });
  frame.start();
  frame.paste("hello");
  frame.key("enter");
  await waitForSettled();

  assertEquals(frame.rows().slice(0, 4), ["", " hello", "", " Hi there."]);
  assertEquals(host.requests.at(-1)?.messages.at(-1)?.text, "hello");
});

test("chat.show opens a session with a parent: the pane shows its transcript, and a message goes to it", async () => {
  const probed: Partial<Probed> = {};
  using frame = createFrame({ width: 30, height: 14 }, undefined, { folder: "/w" });
  await using host = await createHost({
    frame,
    plugins: [{ bundled: "chat" }, probe(probed)],
    replies: [reply.text("Two tables."), reply.text("Three indexes.")],
  });
  const parent = await host.openSession();
  const sessions = probed.sessions as Sessions;
  const child = await sessions.create(probed.settings as SessionSettings, { parent: parent.id });
  const held = await sessions.open(child, { tail: 0, onEvent() {} });
  await held.sendMessage({ content: [{ kind: "userText", text: "Read the store." }] });
  await held.waitForIdle();
  frame.start();
  await (probed.chat as ChatService).show(child);
  const before = await shown(frame);

  frame.paste("And the indexes?");
  frame.key("enter");
  await waitForSettled();
  await held.waitForIdle();

  assert(before.includes("Two tables."), before);
  assert((await shown(frame)).includes("Three indexes."));
  assertEquals(host.requests.at(-1)?.messages.at(-1)?.text, "And the indexes?");
});

test("a question of a tool takes the place of the composer, and enter gives the tool the answer", async () => {
  const probed: Partial<Probed> = {};
  const asker: PluginSession = (s) => {
    s.tools.add({
      name: "delete_branch",
      description: "Delete a branch after the user agrees.",
      concurrency: "serial",
      inputSchema: { type: "object", properties: {} },
      execute: async (_args, context) => {
        const question = { id: "q", header: "Branch", question: "Delete feat/x?", options: [{ label: "Yes" }] };
        const answers = await s.ask({ questions: [question] }, { signal: context.signal });
        return answers?.[0]?.values.join(",") ?? "cancelled";
      },
    });
  };
  using frame = createFrame({ width: 40, height: 14 }, undefined, { folder: "/w" });
  await using host = await createHost({
    frame,
    plugins: [{ bundled: "chat" }, probe(probed), { name: "asker", session: asker }],
    replies: [reply.toolCalls([{ name: "delete_branch", args: {} }]), reply.text("Deleted.")],
    // The pane answers the question, so the host keeps it open.
    onQuestion: () => new Promise(() => {}),
  });
  const session = await host.openSession();
  frame.start();
  await (probed.chat as ChatService).show(session.id);
  const sent = session.sendMessage("Delete feat/x.");
  const asked = await shown(frame);
  frame.key("enter");
  await sent;

  assert(asked.includes("Delete feat/x?"), asked);
  assertEquals(host.requests.at(-1)?.messages.at(-1)?.text, "Yes");
  assert((await shown(frame)).includes("Deleted."));
});

test("/new beside a running job of a plugin says that the work goes on", async () => {
  const probed: Partial<Probed> = {};
  const reader: PluginSession = (s) => {
    void s.jobs.start(
      { id: "reader", label: "Read the store" },
      (signal) => new Promise((resolve) => signal.addEventListener("abort", () => resolve(undefined))),
    );
  };
  using frame = createFrame({ width: 60, height: 14 }, undefined, { folder: "/w" });
  await using host = await createHost({
    frame,
    plugins: [{ bundled: "chat" }, probe(probed), { name: "reader", session: reader }],
  });
  const session = await host.openSession();
  frame.start();
  await (probed.chat as ChatService).show(session.id);
  await waitForSettled();
  frame.key("/ n e w enter");
  await waitForSettled();

  assertEquals(
    host.notices.filter((notice) => notice.source === "chat").map((notice) => notice.text),
    ["The session is still running: use /sessions to check it"],
  );
});

test("a read-only session shows the row of its source in place of the composer", async () => {
  const probed: Partial<Probed> = {};
  using frame = createFrame({ width: 40, height: 10 }, undefined, { folder: "/w" });
  await using host = await createHost({ frame, plugins: [{ bundled: "chat" }, probe(probed)] });
  const parent = await host.openSession();
  const child = await (probed.sessions as Sessions).create(probed.settings as SessionSettings, { parent: parent.id });
  const chat = probed.chat as ChatService;
  chat.addReadOnly((id) => (id === child ? { text: "A child session", back: parent.id } : undefined));
  frame.start();
  await chat.show(child);

  assert((await shown(frame)).includes("A child session"));
});
