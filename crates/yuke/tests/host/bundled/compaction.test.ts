// The bundled plugin `compaction`: when it compacts, what it keeps, and how it fails.

import { session as compaction } from "yuke:internal/bundled/compaction";
import type { Block } from "yuke:protocol";
import {
  assertEquals,
  createHost,
  type ModelRequest,
  type Reply,
  type RoundPlan,
  reply,
  type TestRound,
  test,
} from "yuke:test";

/** The window of the round. The plugin compacts above 100,000 − 16,384 tokens and keeps about 10,000 tokens. */
const WINDOW = 100_000;

/** A user text of about `tokens` estimated tokens. */
const long = (letter: string, tokens: number): Block => ({ kind: "userText", text: letter.repeat(tokens * 4) });

/** Two inputs of about 12,000 tokens each, with an answer between them. */
const twoInputs = (): Block[] => [long("a", 12_000), { kind: "assistantText", text: "ok" }, long("b", 12_000)];

/** The text of a failed summary request: the server error of the fake model. */
const FAILED = "the provider returned a server error: overloaded_error: Overloaded";

const OLD_SUMMARY: Block = { kind: "userText", text: "<context_summary>\nold\n</context_summary>" };

/** A host with the plugin `compaction` whose side requests go to a fake model with `replies`. */
async function compacting(replies: readonly Reply[]) {
  const host = await createHost({
    plugins: [{ name: "compaction", session: compaction }],
    replies,
    answer: () => undefined,
  });
  return { host, session: await host.openSession() };
}

/** The plan of the `round.before` hooks for `round`, with the replies `replies`. */
async function before(round: TestRound, replies: readonly Reply[]) {
  const { host, session } = await compacting(replies);
  await using _host = host;
  const plan = await session.runHook("round.before", round);
  return { plan, requests: host.requests, notices: host.notices.map((notice) => [notice.level, notice.text]) };
}

/** The head and the keep of the replacement of `plan`. */
function replaced(plan: RoundPlan): [readonly Block[], number] {
  if (plan.replace === undefined) throw new Error("the plan replaces nothing");
  return [plan.replace.head, plan.replace.keep];
}

/** The texts of the messages of the only request of `requests`. */
function sent(requests: readonly ModelRequest[]): string[] {
  assertEquals(requests.length, 1);
  return requests[0]?.messages.map((message) => message.text) ?? [];
}

test("a context near the window becomes a summary and its newest part", async () => {
  const context = twoInputs();
  // The count is 75,000 and about 12,000 for the answer and the input: above the threshold, below the window.
  const { plan, requests, notices } = await before({ blocks: context, inputTokens: 75_000, contextWindow: WINDOW }, [
    reply.text("## Goal\nThe work."),
  ]);

  const [head, keep] = replaced(plan);
  assertEquals(keep, 1);
  const summary = head.length === 1 && head[0]?.kind === "userText" ? head[0].text : "";
  assertEquals(summary.startsWith("<context_summary>\n## Goal\nThe work.\n</context_summary>\n"), true);
  assertEquals(notices, [["info", "The context nears the window of the model. A summary replaces its old part."]]);
  // The summary request sends the whole context, so it reads the prompt cache of the round.
  const [first, answer, last, ...rest] = sent(requests);
  // The prompt is a text part after the newest input, so it starts on the next line.
  const input = last?.slice(0, 48_000);
  assertEquals([first, answer, input, rest], ["a".repeat(48_000), "ok", "b".repeat(48_000), []]);
});

for (const [name, inputTokens, window] of [
  ["below the threshold", 50_000, WINDOW],
  ["without a window", 900_000, null],
] as const) {
  test(`a context ${name} stays`, async () => {
    const { plan, requests } = await before({ blocks: twoInputs(), inputTokens, contextWindow: window }, []);

    assertEquals([plan.replace, requests.length], [undefined, 0]);
  });
}

test("the cut never starts at a tool result, and the newest input stays exact", async () => {
  const context: Block[] = [
    { kind: "userText", text: "start" },
    { kind: "toolCall", callId: "c1", name: "read", arguments: "{}" },
    { kind: "toolResult", callId: "c1", content: "r".repeat(48_000), isError: false },
  ];

  const { plan } = await before({ blocks: context, inputTokens: 90_000, contextWindow: WINDOW }, [
    reply.text("summary"),
  ]);

  const [head, keep] = replaced(plan);
  assertEquals([keep, head.slice(1)], [2, [{ kind: "userText", text: "start" }]]);
});

test("a second compaction merges the old summary", async () => {
  const { plan, requests } = await before(
    { blocks: [OLD_SUMMARY, ...twoInputs()], inputTokens: 90_000, contextWindow: WINDOW },
    [reply.text("summary")],
  );

  assertEquals(replaced(plan)[1], 1);
  assertEquals(
    sent(requests).some((text) => text.includes("<context_summary>\nold\n</context_summary>")),
    true,
  );
});

test("a cut that covers only the old summary compacts nothing", async () => {
  const { plan, requests } = await before(
    { blocks: [OLD_SUMMARY, long("b", 12_000)], inputTokens: 90_000, contextWindow: WINDOW },
    [],
  );

  assertEquals([plan.replace, requests.length], [undefined, 0]);
});

// After a replacement the host gives no count, so the estimate of each block decides.
test("without a count the estimate of each block decides", async () => {
  const large = Array.from({ length: 8 }, (_item, index) => long(String(index), 12_000));
  const { host, session } = await compacting([reply.text("summary")]);
  await using _host = host;

  const below = await session.runHook("round.before", { blocks: twoInputs(), contextWindow: WINDOW });
  const above = await session.runHook("round.before", { blocks: large, contextWindow: WINDOW });

  assertEquals([below.replace, above.replace !== undefined, host.requests.length], [undefined, true, 1]);
});

test("the old summary never counts as the newest input", async () => {
  // The first request after a compaction failed, and a new input followed: only user blocks after the summary.
  const context = [OLD_SUMMARY, long("a", 12_000), long("b", 12_000)];

  const { plan } = await before({ blocks: context, inputTokens: 90_000, contextWindow: WINDOW }, [
    reply.text("summary"),
  ]);

  const [head, keep] = replaced(plan);
  assertEquals([keep, head.slice(1)], [1, [long("a", 12_000)]]);
});

for (const [name, answer, reason] of [
  ["a failed summary", reply.failed(""), FAILED],
  [
    "a summary that stops for a call",
    reply.toolCalls([{ name: "read", args: { path: "a" } }]),
    "the summary stopped with toolCalls",
  ],
  ["an empty summary", reply.text(" \n"), "the summary is empty"],
] as const) {
  test(`${name} sends a warning, and the round keeps its context`, async () => {
    const { plan, notices } = await before({ blocks: twoInputs(), inputTokens: 90_000, contextWindow: WINDOW }, [
      answer,
    ]);

    assertEquals([plan.replace, notices.at(-1)], [undefined, ["warn", `the compaction failed: ${reason}`]]);
  });
}

test("an overflow sends only the part before the cut, and the plugin stops after two retries", async () => {
  const { host, session } = await compacting([reply.text("summary"), reply.text("summary")]);
  await using _host = host;
  const round = { blocks: twoInputs(), inputTokens: 120_000, contextWindow: WINDOW };
  const overflow = { kind: "contextOverflow" } as const;

  const first = await session.runHook("round.retry", { ...round, failure: overflow, retries: 0 });
  await session.runHook("round.retry", { ...round, failure: overflow, retries: 1 });
  const third = await session.runHook("round.retry", { ...round, failure: overflow, retries: 2 });
  const other = await session.runHook("round.retry", { ...round, failure: { kind: "transport" }, retries: 0 });

  assertEquals([first === undefined ? -1 : replaced(first)[1], third, other], [1, undefined, undefined]);
  // The cut keeps the newest input, so the first request holds the blocks before it, then the prompt.
  assertEquals(host.requests.length, 2);
  const [input, answer, prompt, ...rest] = host.requests[0]?.messages ?? [];
  assertEquals(
    [input, answer, rest],
    [{ role: "user", text: "a".repeat(48_000) }, { role: "assistant", text: "ok" }, []],
  );
  assertEquals(prompt?.role === "user" && prompt.text.includes("b".repeat(100)), false);
});
