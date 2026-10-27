// The questions of the plugins in a session of the test host.

import type { PluginSession } from "yuke:plugins";
import { createFakeModel, createHost, equal, reply, test } from "yuke:test";

/** A plugin whose tool `ask` asks the user to confirm, and answers with the answer. */
const asker: PluginSession = (s) => {
  s.tools.define({
    name: "ask",
    description: "Ask the user.",
    concurrency: "serial",
    parameters: { type: "object", properties: {} },
    execute: async (_args, context) => String(await s.confirm("Go on?", "It runs.", { signal: context.signal })),
  });
};

test("the answer function answers each question, and the host records it", async () => {
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }], answer: () => true });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  equal(result.text, "true");
  equal(
    host.questions.map((question) => [question.source, question.request.kind, question.sessionId === session.id]),
    [["asker", "confirm", true]],
  );
});

test("without an answer function, each question gets undefined as with no client", async () => {
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }] });
  const session = await host.openSession();

  equal((await session.call("ask", {})).text, "undefined");
  equal(host.questions.length, 1);
});

test("a question during a turn gets its answer before the turn goes on", async () => {
  const model = createFakeModel([reply.toolCall("ask", {}), reply.text("Done.")]);
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }], model, answer: () => false });
  const session = await host.openSession();

  await session.send("Ask me.");

  equal(
    model.requests[1]?.messages.some((message) => message.text.includes("false")),
    true,
  );
});

test("each kind of question gets the answer of its kind, and undefined cancels it", async () => {
  const kinds: PluginSession = (s) => {
    s.tools.define({
      name: "kinds",
      description: "Ask each kind of question.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: async (_args, context) => {
        const signal = context.signal;
        const answers = [
          await s.confirm("Go on?", undefined, { signal }),
          await s.select("Which?", ["red", "blue"], { signal }),
          await s.input("Name?", { signal }),
          await s.select("Again?", ["red", "blue"], { signal }),
        ];
        return JSON.stringify(answers);
      },
    });
  };
  const answers: Record<string, boolean | string | undefined> = {
    "Go on?": true,
    "Which?": "blue",
    "Name?": "Ada",
    "Again?": undefined,
  };
  await using host = await createHost({
    plugins: [{ name: "kinds", session: kinds }],
    answer: (question) => answers[question.request.title],
  });
  const session = await host.openSession();

  const result = await session.call("kinds", {});

  equal(JSON.parse(result.text), [true, "blue", "Ada", null]);
  equal(
    host.questions.map((question) => question.request.kind),
    ["confirm", "select", "input", "select"],
  );
});

test("a question in the setup of a session gets its answer", async () => {
  const early: PluginSession = async (s) => {
    s.notify("info", `the answer is ${await s.confirm("Start?")}`);
  };
  await using host = await createHost({ plugins: [{ name: "early", session: early }], answer: () => true });

  await host.openSession();

  equal(
    host.notices.map((notice) => notice.message),
    ["the answer is true"],
  );
});
