// The whole flow of a child agent: the smallest plugin that uses `parent` and `context.jobs` together.

import type { PluginApply, PluginSession, Sessions } from "yuke:plugins";
import type { QuestionAnswer } from "yuke:protocol";
import { assertEquals, createHost, type Reply, reply, test, waitForSettled } from "yuke:test";

/** The plugin. Its tool `spawn_subagent` runs the one child of a session as the job `explorer`. */
function agents() {
  let sessions: Sessions | undefined;
  const opening = Promise.withResolvers<void>();
  const state: { child?: string; gate: Promise<void>; open: () => void } = {
    gate: opening.promise,
    open: opening.resolve,
  };
  const apply: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  const session: PluginSession = (s) => {
    // The child asks here. The plugin forwards the question to the parent.
    s.tools.add({
      name: "ask",
      description: "Ask the user.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: async () =>
        JSON.stringify(
          await s.ask({
            questions: [{ id: "go", header: "go", question: "Go?", options: [{ label: "Yes" }, { label: "No" }] }],
          }),
        ),
    });
    // The child waits here until a test opens the gate.
    s.tools.add({
      name: "gate",
      description: "Wait for the test.",
      concurrency: "parallel",
      parameters: { type: "object", properties: {} },
      execute: async () => {
        await state.gate;
        return "open";
      },
    });
    s.tools.add({
      name: "spawn_subagent",
      description: "Run a child.",
      concurrency: "parallel",
      parameters: {
        type: "object",
        properties: { message: { type: "string" }, background: { type: "boolean" } },
        required: ["message", "background"],
      },
      execute: async (args, context) => {
        const job = { id: "explorer", label: "explore the store", background: args.background };
        const outcome = await context.jobs.run(job, async (signal) => {
          const list = sessions as Sessions;
          state.child ??= await list.create(s.settings, { parent: s.sessionId });
          const child = state.child;
          const ended = new AbortController();
          const handle = await list.open(child, {
            tail: 0,
            signal: ended.signal,
            onEvent: (event) => {
              if (event.kind === "snapshot" || event.update.sessionUpdate !== "interactionRequested") return;
              const update = event.update;
              void s
                .ask({ questions: update.request.questions })
                .then((answers) =>
                  handle.respond(
                    update.interactionId,
                    answers === undefined ? { kind: "cancelled" } : { kind: "questions", answers },
                  ),
                );
            },
          });
          signal.addEventListener("abort", () => handle.cancel());
          await handle.sendMessage({ content: [{ kind: "userText", text: args.message }] });
          await handle.waitForIdle();
          const events = await list.events(child, { limit: 2 });
          ended.abort();
          const blocks = events.flatMap((event) => (event.sessionUpdate === "commit" ? event.commit.blocks : []));
          const text = blocks.flatMap((block) => (block.kind === "assistantText" ? [block.text] : [])).join("");
          return { status: "completed", text };
        });
        return outcome.kind === "background" ? `${outcome.id} runs in the background.` : (outcome.report?.text ?? "");
      },
    });
  };
  return { state, apply, session, list: () => sessions as Sessions };
}

/** A host with the plugin and `replies`, and an open parent session. */
async function opened(replies: readonly Reply[], answer?: () => QuestionAnswer[]) {
  const plugin = agents();
  const host = await createHost({
    plugins: [{ name: "agents", apply: plugin.apply, session: plugin.session }],
    replies,
    ...(answer === undefined ? {} : { answer }),
  });
  const parent = await host.openSession();
  return { host, parent, ...plugin };
}

/** The text of the newest request that the fake model got. */
const newest = (host: Awaited<ReturnType<typeof opened>>["host"]) => host.requests.at(-1)?.messages.at(-1)?.text;

test("a child reports to its parent, stays out of the list, and takes a follow-up with the same id", async () => {
  const { host, parent, state, list } = await opened([
    reply.text("Two tables."),
    reply.text("Thanks."),
    reply.text("Three indexes."),
    reply.text("Thanks again."),
  ]);
  await using _host = host;

  await parent.call("spawn_subagent", { message: "Read the store.", background: true });
  assertEquals(host.requests.length, 2);
  const first = newest(host);
  const roots = (await list().list()).sessions.map((row) => row.session.sessionId);
  const children = (await list().list({ parent: parent.id })).sessions.map((row) => row.session.sessionId);
  const followup = await parent.call("spawn_subagent", { message: "And the indexes?", background: true });
  assertEquals(followup.isError, false);
  assertEquals(host.requests.length, 4);

  assertEquals(
    first,
    '<system_notification plugin="agents">explorer explore the store: completed.\nTwo tables.</system_notification>',
  );
  assertEquals(roots, [parent.id]);
  assertEquals(children, [state.child]);
  assertEquals(
    newest(host),
    '<system_notification plugin="agents">explorer explore the store: completed.\nThree indexes.</system_notification>',
  );
});

test("a stop cancels the child, and the parent gets no report", async () => {
  const { host, parent } = await opened([reply.stall("Reading")]);
  await using _host = host;

  await parent.call("spawn_subagent", { message: "Read the store.", background: true });
  assertEquals(host.requests.length, 1);
  const stopped = await parent.call("stop", { id: "explorer" });

  assertEquals(stopped.text, "explorer stopped.");
  assertEquals(host.requests.length, 1);
});

test("a question of the child reaches the parent, and its answer returns to the child", async () => {
  const { host, parent } = await opened(
    [reply.toolCalls([{ name: "ask", args: {} }]), reply.text("It said yes."), reply.text("Thanks.")],
    () => [{ id: "go", values: ["Yes"] }],
  );
  await using _host = host;

  await parent.call("spawn_subagent", { message: "Ask first.", background: true });
  assertEquals(host.requests.length, 3);

  assertEquals(
    host.questions.map((question) => question.sessionId),
    [parent.id],
  );
  assertEquals(
    newest(host),
    '<system_notification plugin="agents">explorer explore the store: completed.\nIt said yes.</system_notification>',
  );
});

test("a foreground child answers as the tool result, shows no job, and sends no report", async () => {
  const { host, parent, list } = await opened([reply.text("Two tables.")]);
  await using _host = host;
  const handle = await list().open(parent.id, { tail: 0, onEvent() {} });

  const result = await parent.call("spawn_subagent", { message: "Read the store.", background: false });

  assertEquals(result.text, "Two tables.");
  assertEquals(handle.jobs(), []);
  assertEquals(host.requests.length, 1);
});

test("ctrl+b moves a foreground child: the call answers, the child goes on, and its report reaches the parent", async () => {
  const { host, parent, list, state } = await opened([
    reply.toolCalls([{ name: "gate", args: {} }]),
    reply.text("Two tables."),
    reply.text("Thanks."),
  ]);
  await using _host = host;
  const handle = await list().open(parent.id, { tail: 0, onEvent() {} });
  const running = parent.call("spawn_subagent", { message: "Read the store.", background: false });
  await waitForSettled();
  const movable = handle.canMoveJobsToBackground();

  handle.moveJobsToBackground();
  const result = await running;
  await waitForSettled();
  const jobs = handle.jobs().map((job) => [job.id, job.state]);
  state.open();
  await waitForSettled();

  assertEquals(movable, true);
  assertEquals(result.text, "explorer runs in the background.");
  assertEquals(jobs, [["explorer", "running"]]);
  assertEquals(handle.jobs(), []);
  assertEquals(
    newest(host),
    '<system_notification plugin="agents">explorer explore the store: completed.\nTwo tables.</system_notification>',
  );
});
