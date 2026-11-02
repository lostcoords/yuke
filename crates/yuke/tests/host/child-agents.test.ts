// The whole flow of a child agent: the smallest plugin that uses `parent` and `s.jobs` together.

import type { PluginApply, PluginSession, QuestionAnswer, Sessions } from "yuke:plugins";
import type { SessionSettings } from "yuke:protocol";
import { createHost, equal, type Reply, reply, test } from "yuke:test";

/** The plugin. Its tool `delegate` runs the one child of a session as the job `explorer`. */
function agents() {
  let sessions: Sessions | undefined;
  const state: { settings?: SessionSettings; child?: string } = {};
  const apply: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  const session: PluginSession = (s) => {
    // The child asks here. The plugin forwards the question to the parent.
    s.tools.define({
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
    s.tools.define({
      name: "delegate",
      description: "Run a child.",
      concurrency: "parallel",
      parameters: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
      execute: async (args) => {
        const job = s.jobs.start({ id: "explorer", label: args.message });
        const list = sessions as Sessions;
        state.child ??= await list.create(state.settings as SessionSettings, { parent: s.sessionId });
        const child = state.child;
        const handle = await list.open(child, {
          tail: 0,
          event: (event) => {
            if ("snapshot" in event || event.update.sessionUpdate !== "interaction_requested") return;
            const update = event.update;
            void s
              .ask({ questions: update.request.questions })
              .then((answers) =>
                handle.respond(
                  update.interactionId,
                  answers === undefined ? { kind: "canceled" } : { kind: "questions", answers },
                ),
              );
          },
        });
        job.signal.addEventListener("abort", () => handle.cancel());
        void handle
          .input([{ user_text: args.message }])
          .then(() => handle.idle())
          .then(() => list.events(child, { limit: 2 }))
          .then((events) => {
            const blocks = events.flatMap((event) => (event.sessionUpdate === "commit" ? event.commit.blocks : []));
            const text = blocks.flatMap((block) => ("assistant_text" in block ? [block.assistant_text] : [])).join("");
            job.end({ status: "completed", text });
          });
        return "started";
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
  plugin.state.settings = parent.settings;
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

  await parent.call("delegate", { message: "Read the store." });
  equal(host.requests.length, 2);
  const first = newest(host);
  const roots = (await list().list()).sessions.map((row) => row.session.sessionId);
  const children = (await list().list({ parent: parent.id })).sessions.map((row) => row.session.sessionId);
  const followup = await parent.call("delegate", { message: "And the indexes?" });
  equal(followup.isError, false);
  equal(host.requests.length, 4);

  equal(first, '<system_notification plugin="agents">explorer completed.\nTwo tables.</system_notification>');
  equal(roots, [parent.id]);
  equal(children, [state.child]);
  equal(newest(host), '<system_notification plugin="agents">explorer completed.\nThree indexes.</system_notification>');
});

test("a stop cancels the child, and the parent gets no report", async () => {
  const { host, parent } = await opened([reply.stall("Reading")]);
  await using _host = host;

  await parent.call("delegate", { message: "Read the store." });
  equal(host.requests.length, 1);
  const stopped = await parent.call("stop", { id: "explorer" });

  equal(stopped.text, "[explorer stopped.]");
  equal(host.requests.length, 1);
});

test("a question of the child reaches the parent, and its answer returns to the child", async () => {
  const { host, parent } = await opened(
    [reply.toolCall("ask", {}), reply.text("It said yes."), reply.text("Thanks.")],
    () => [{ id: "go", values: ["Yes"] }],
  );
  await using _host = host;

  await parent.call("delegate", { message: "Ask first." });
  equal(host.requests.length, 3);

  equal(
    host.questions.map((question) => question.sessionId),
    [parent.id],
  );
  equal(newest(host), '<system_notification plugin="agents">explorer completed.\nIt said yes.</system_notification>');
});
