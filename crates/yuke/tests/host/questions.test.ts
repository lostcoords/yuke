// The questions of the plugins in a session of the test host.

import type { PluginSession } from "yuke:plugins";
import { createHost, equal, reply, test } from "yuke:test";
import { waitFor } from "./wait.ts";

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
  const replies = [reply.toolCall("ask", {}), reply.text("Done.")];
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }], replies, answer: () => false });
  const session = await host.openSession();

  await session.send("Ask me.");

  equal(
    host.requests[1]?.messages.some((message) => message.text.includes("false")),
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

test("an answer promise keeps the question open until it settles", async () => {
  let release = (_value: boolean): void => {};
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    answer: () =>
      new Promise<boolean>((resolve) => {
        release = resolve;
      }),
  });
  const session = await host.openSession();

  const pending = session.call("ask", {});
  await waitFor(() => host.questions.length === 1);
  release(true);

  equal((await pending).text, "true");
});

test("the close of a session ends its open question with undefined", async () => {
  let answered: unknown = "open";
  const early: PluginSession = async (s) => {
    answered = await s.confirm("Start?");
  };
  await using host = await createHost({
    plugins: [{ name: "early", session: early }],
    answer: () => new Promise<boolean>(() => {}),
  });
  const session = await host.openSession();
  await waitFor(() => host.questions.length === 1);

  await session.close();

  equal(answered, undefined);
  equal(
    host.questions.map((question) => [question.source, question.request]),
    [["early", { kind: "confirm", title: "Start?", message: "" }]],
  );
});

// A late failure is no fault either: the runner fails a test on any fault.
for (const [name, settle] of [
  ["fulfills", (resolve: (value: boolean) => void) => resolve(true)],
  ["rejects", (_resolve: unknown, reject: (error: Error) => void) => reject(new Error("late"))],
] as const) {
  test(`an answer that ${name} after the close of its session reaches no question`, async () => {
    let release = (): void => {};
    const early: PluginSession = async (s) => {
      await s.confirm("Start?");
    };
    await using host = await createHost({
      plugins: [{ name: "early", session: early }],
      answer: () =>
        new Promise<boolean>((resolve, reject) => {
          release = () => settle(resolve, reject);
        }),
    });
    const session = await host.openSession();
    await waitFor(() => host.questions.length === 1);
    await session.close();

    release();
    await new Promise((resolve) => setTimeout(resolve, 10));

    equal(host.questions.length, 1);
  });
}

/** A plugin whose tool `ask` runs `body` with the session context and the signal of the call, and gives its JSON. */
const asking =
  (body: (s: Parameters<PluginSession>[0], signal: AbortSignal) => Promise<unknown>): PluginSession =>
  (s) => {
    s.tools.define({
      name: "ask",
      description: "Ask the user.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: async (_args, context) => JSON.stringify(await body(s, context.signal)),
    });
  };

test("each question names its plugin and its fields, and gives the answer of the user", async () => {
  const answers = [true, "production", "v2", "t1"];
  const asker = asking(async (s, signal) => [
    await s.confirm("Run the migration?", "It drops a table.", { signal }),
    await s.select("Deploy to?", ["staging", "production"], { signal }),
    await s.input("Name?", { placeholder: "main", secret: true, signal }),
    await s.input("Tag?"),
  ]);
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }], answer: () => answers.shift() });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  equal(result.text, '[true,"production","v2","t1"]');
  equal(
    host.questions.map((question) => [question.source, question.request]),
    [
      ["asker", { kind: "confirm", title: "Run the migration?", message: "It drops a table." }],
      ["asker", { kind: "select", title: "Deploy to?", options: ["staging", "production"] }],
      ["asker", { kind: "input", title: "Name?", placeholder: "main", secret: true }],
      ["asker", { kind: "input", title: "Tag?", secret: false }],
    ],
  );
});

test("a cancel or an abort answers undefined, and an aborted signal asks nothing", async () => {
  const asker = asking(async (s) => {
    const canceled = await s.confirm("First?");
    const controller = new AbortController();
    const waiting = s.confirm("Second?", "", { signal: controller.signal });
    controller.abort();
    const aborted = await waiting;
    const late = await s.input("Third?", { signal: controller.signal });
    const refused = await s.confirm("Fourth?", "", { signal: 5 as never }).then(
      () => "answered",
      (error: unknown) => (error instanceof Error ? error.name : String(error)),
    );
    return [...[canceled, aborted, late].map((answer) => answer === undefined), refused];
  });
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    answer: (question) => (question.request.title === "First?" ? undefined : new Promise<boolean>(() => {})),
  });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  equal(result.text, '[true,true,true,"TypeError"]');
  // A `signal` option of another type throws a `TypeError` before the question.
  equal(
    host.questions.map((question) => question.request.title),
    ["First?", "Second?"],
  );
});

test("select refuses no choice and a repeated choice", async () => {
  const asker = asking(async (s) => {
    const failures: string[] = [];
    for (const choices of [[], ["a", "a"]]) {
      try {
        await s.select("Pick?", choices);
      } catch (error) {
        failures.push(error instanceof Error ? `${error.name}: ${error.message}` : String(error));
      }
    }
    return failures;
  });
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }] });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  equal(result.text, '["TypeError: select: choices is empty","TypeError: select: choices has a choice twice"]');
  equal(host.questions, []);
});
