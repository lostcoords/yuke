// The questions of the plugins in a session of the test host.

import type { PluginSession } from "yuke:plugins";
import type { Question, QuestionAnswer } from "yuke:protocol";
import { assertEquals, createHost, reply, test, waitForSettled } from "yuke:test";

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
    s.tools.add({
      name: "ask",
      description: "Ask the user.",
      concurrency: "serial",
      inputSchema: { type: "object", properties: {} },
      execute: async (_args, context) => JSON.stringify(await body(s, context.signal)) ?? "undefined",
    });
  };

/** A plugin whose tool `ask` asks one yes or no question, and gives the answers. */
const asker = asking((s, signal) => s.ask({ questions: [yesNo("go", "Go on?")] }, { signal }));

test("the answer function answers each request, and the host records it", async () => {
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    onQuestion: () => picked("go", "Yes"),
  });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  assertEquals(JSON.parse(result.text), picked("go", "Yes"));
  assertEquals(
    host.questions.map((question) => [question.source, question.request.kind, question.sessionId === session.id]),
    [["asker", "questions", true]],
  );
});

test("without an answer function, each request gets undefined as with no client", async () => {
  await using host = await createHost({ plugins: [{ name: "asker", session: asker }] });
  const session = await host.openSession();

  assertEquals((await session.call("ask", {})).text, "undefined");
  assertEquals(host.questions.length, 1);
});

test("a request during a turn gets its answer before the turn goes on", async () => {
  const replies = [reply.toolCalls([{ name: "ask", args: {} }]), reply.text("Done.")];
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    replies,
    onQuestion: () => picked("go", "No"),
  });
  const session = await host.openSession();

  await session.sendMessage("Ask me.");

  assertEquals(
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
    onQuestion: () => answers,
  });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  assertEquals(JSON.parse(result.text), answers);
  assertEquals(host.questions[0]?.request, {
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
    onQuestion: () => picked("start", "Yes"),
  });

  await host.openSession();

  assertEquals(
    host.notices.map((notice) => notice.text),
    ["the answer is Yes"],
  );
});

test("an answer promise keeps the request open until it settles", async () => {
  let release = (_value: QuestionAnswer[]): void => {};
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    onQuestion: () =>
      new Promise<QuestionAnswer[]>((resolve) => {
        release = resolve;
      }),
  });
  const session = await host.openSession();

  const pending = session.call("ask", {});
  await waitForSettled();
  assertEquals(host.questions.length, 1);
  release(picked("go", "Yes"));

  assertEquals(JSON.parse((await pending).text), picked("go", "Yes"));
});

test("the close of a session ends its open request with undefined", async () => {
  let answered: unknown = "open";
  const early: PluginSession = async (s) => {
    answered = await s.ask({ questions: [yesNo("start", "Start?")] });
  };
  await using host = await createHost({
    plugins: [{ name: "early", session: early }],
    onQuestion: () => new Promise<QuestionAnswer[]>(() => {}),
  });
  const session = await host.openSession();
  assertEquals(host.questions.length, 1);

  await session.close();

  assertEquals(answered, undefined);
  assertEquals(
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
      onQuestion: () =>
        new Promise<QuestionAnswer[]>((resolve, reject) => {
          release = () => settle(resolve, reject);
        }),
    });
    const session = await host.openSession();
    assertEquals(host.questions.length, 1);
    await session.close();

    release();
    await waitForSettled();

    assertEquals(host.questions.length, 1);
  });
}

test("a cancel or an abort answers undefined, and an aborted signal asks nothing", async () => {
  const asker = asking(async (s) => {
    const cancelled = await s.ask({ questions: [yesNo("first", "First?")] });
    const controller = new AbortController();
    const waiting = s.ask({ questions: [yesNo("second", "Second?")] }, { signal: controller.signal });
    controller.abort();
    const aborted = await waiting;
    const late = await s.ask({ questions: [yesNo("third", "Third?")] }, { signal: controller.signal });
    return [cancelled, aborted, late].map((answer) => answer === undefined);
  });
  await using host = await createHost({
    plugins: [{ name: "asker", session: asker }],
    onQuestion: (question) =>
      question.request.questions[0]?.id === "first" ? undefined : new Promise<QuestionAnswer[]>(() => {}),
  });
  const session = await host.openSession();

  const result = await session.call("ask", {});

  assertEquals(result.text, "[true,true,true]");
  assertEquals(
    host.questions.map((question) => question.request.questions[0]?.id),
    ["first", "second"],
  );
});
