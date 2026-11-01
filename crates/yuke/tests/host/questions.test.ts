// The questions of the plugins in a session of the test host.

import type { PluginSession, Question, QuestionAnswer } from "yuke:plugins";
import { createHost, equal, reply, test } from "yuke:test";
import { waitFor } from "./wait.ts";

/** A yes or no question. */
const yesNo = (id: string, question: string): Question => ({
  id,
  header: id,
  question,
  options: [{ label: "Yes" }, { label: "No" }],
});

/** The answer `value` to the question `id`. */
const picked = (id: string, value: string): QuestionAnswer[] => [{ id, values: [value] }];

/** A plugin whose tool `ask` runs `body` with the session context and the signal of the call, and gives its JSON. */
const asking =
  (body: (s: Parameters<PluginSession>[0], signal: AbortSignal) => Promise<unknown>): PluginSession =>
  (s) => {
    s.tools.define({
      name: "ask",
      description: "Ask the user.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: async (_args, context) => JSON.stringify(await body(s, context.signal)) ?? "undefined",
    });
  };

/** A plugin whose tool `ask` asks one yes or no question, and gives the answers. */
const asker = asking((s, signal) => s.ask({ questions: [yesNo("go", "Go on?")] }, { signal }));

test("the answer function answers each request, and the host records it", async () => {
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    answer: () => picked("go", "Yes"),
  });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  equal(JSON.parse(result.text), picked("go", "Yes"));
  equal(
    host.questions.map((question) => [question.source, question.request.kind, question.sessionId === session.id]),
    [["asker", "questions", true]],
  );
});

test("without an answer function, each request gets undefined as with no client", async () => {
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }] });
  const session = await host.openSession();

  equal((await session.call("ask", {})).text, "undefined");
  equal(host.questions.length, 1);
});

test("a request during a turn gets its answer before the turn goes on", async () => {
  const replies = [reply.toolCall("ask", {}), reply.text("Done.")];
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    replies,
    answer: () => picked("go", "No"),
  });
  const session = await host.openSession();

  await session.send("Ask me.");

  equal(
    host.requests[1]?.messages.some((message) => message.text.includes('"values":["No"]')),
    true,
  );
});

test("a request of several questions gets one answer per question, and yuke sends each flag", async () => {
  const questions: Question[] = [
    {
      id: "db",
      header: "Database",
      question: "Which database?",
      options: [{ label: "SQLite", description: "embedded" }, { label: "Postgres" }],
      multiple: true,
      other: true,
    },
    { id: "token", header: "Token", question: "The API token?", options: [], other: true, secret: true },
    yesNo("go", "Go on?"),
  ];
  const answers: QuestionAnswer[] = [
    { id: "db", values: ["SQLite", "Postgres"], other: "with pgvector" },
    { id: "token", values: [], other: "t1" },
    { id: "go", values: ["Yes"] },
  ];
  await using host = await createHost({
    plugins: [{ name: "asker", session: asking((s, signal) => s.ask({ questions }, { signal })) }],
    answer: () => answers,
  });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  equal(JSON.parse(result.text), answers);
  equal(host.questions[0]?.request, {
    kind: "questions",
    questions: [
      { ...questions[0], secret: false },
      { ...questions[1], multiple: false },
      { ...yesNo("go", "Go on?"), multiple: false, other: false, secret: false },
    ],
  });
});

test("a request in the setup of a session gets its answer", async () => {
  const early: PluginSession = async (s) => {
    const answers = await s.ask({ questions: [yesNo("start", "Start?")] });
    s.notify("info", `the answer is ${answers?.[0]?.values[0]}`);
  };
  await using host = await createHost({
    plugins: [{ name: "early", session: early }],
    answer: () => picked("start", "Yes"),
  });

  await host.openSession();

  equal(
    host.notices.map((notice) => notice.message),
    ["the answer is Yes"],
  );
});

test("an answer promise keeps the request open until it settles", async () => {
  let release = (_value: QuestionAnswer[]): void => {};
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    answer: () =>
      new Promise<QuestionAnswer[]>((resolve) => {
        release = resolve;
      }),
  });
  const session = await host.openSession();

  const pending = session.call("ask", {});
  await waitFor(() => host.questions.length === 1);
  release(picked("go", "Yes"));

  equal(JSON.parse((await pending).text), picked("go", "Yes"));
});

test("the close of a session ends its open request with undefined", async () => {
  let answered: unknown = "open";
  const early: PluginSession = async (s) => {
    answered = await s.ask({ questions: [yesNo("start", "Start?")] });
  };
  await using host = await createHost({
    plugins: [{ name: "early", session: early }],
    answer: () => new Promise<QuestionAnswer[]>(() => {}),
  });
  const session = await host.openSession();
  await waitFor(() => host.questions.length === 1);

  await session.close();

  equal(answered, undefined);
  equal(
    host.questions.map((question) => question.source),
    ["early"],
  );
});

// A late failure is no fault either: the runner fails a test on any fault.
for (const [name, settle] of [
  ["fulfills", (resolve: (value: QuestionAnswer[]) => void) => resolve(picked("start", "Yes"))],
  ["rejects", (_resolve: unknown, reject: (error: Error) => void) => reject(new Error("late"))],
] as const) {
  test(`an answer that ${name} after the close of its session reaches no request`, async () => {
    let release = (): void => {};
    const early: PluginSession = async (s) => {
      await s.ask({ questions: [yesNo("start", "Start?")] });
    };
    await using host = await createHost({
      plugins: [{ name: "early", session: early }],
      answer: () =>
        new Promise<QuestionAnswer[]>((resolve, reject) => {
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

test("a cancel or an abort answers undefined, and an aborted signal asks nothing", async () => {
  const asker = asking(async (s) => {
    const canceled = await s.ask({ questions: [yesNo("first", "First?")] });
    const controller = new AbortController();
    const waiting = s.ask({ questions: [yesNo("second", "Second?")] }, { signal: controller.signal });
    controller.abort();
    const aborted = await waiting;
    const late = await s.ask({ questions: [yesNo("third", "Third?")] }, { signal: controller.signal });
    const refused = await s.ask({ questions: [yesNo("fourth", "Fourth?")] }, { signal: 5 as never }).then(
      () => "answered",
      (error: unknown) => (error instanceof Error ? error.name : String(error)),
    );
    return [...[canceled, aborted, late].map((answer) => answer === undefined), refused];
  });
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    answer: (question) =>
      question.request.questions[0]?.id === "first" ? undefined : new Promise<QuestionAnswer[]>(() => {}),
  });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  equal(result.text, '[true,true,true,"TypeError"]');
  // A `signal` option of another type throws a `TypeError` before the request.
  equal(
    host.questions.map((question) => question.request.questions[0]?.id),
    ["first", "second"],
  );
});

test("ask refuses a request that breaks a rule, and asks nothing", async () => {
  const option = (label: string) => ({ label });
  const requests: Question[][] = [
    [],
    [yesNo("go", "Go on?"), yesNo("go", "Again?")],
    [{ id: "pick", header: "Pick", question: "Pick?", options: [option("a"), option("a")] }],
    [{ id: "name", header: "Name", question: "Name?", options: [] }],
    [{ id: "key", header: "Key", question: "Key?", options: [option("a")], secret: true }],
  ];
  const asker = asking(async (s) => {
    const failures: string[] = [];
    for (const questions of requests) {
      try {
        await s.ask({ questions });
      } catch (error) {
        failures.push(error instanceof Error ? `${error.name}: ${error.message}` : String(error));
      }
    }
    return failures;
  });
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }] });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  equal(JSON.parse(result.text), [
    "TypeError: ask: the request has no question",
    'TypeError: ask: the id "go" is twice',
    'TypeError: ask: the question "pick" has a label twice',
    'TypeError: ask: the question "name" has no option and no other',
    'TypeError: ask: the question "key" has options and secret',
  ]);
  equal(host.questions, []);
});
