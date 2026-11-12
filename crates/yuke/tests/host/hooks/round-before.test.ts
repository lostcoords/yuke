// The `round.before` hook: its event, the chain of its answers, its plan, and its failures.

import type { PluginSession, SessionHooks } from "yuke:plugins";
import type { Block, RequestSettings } from "yuke:protocol";
import { createHost, equal, type RoundPlan, rejects, reply, test } from "yuke:test";

/** A context of 4 blocks: the input, a call and its result, and a text. */
const context: Block[] = [
  { kind: "userText", text: "one" },
  { kind: "toolCall", callId: "c1", name: "read", arguments: "{}" },
  { kind: "toolResult", callId: "c1", content: "done", isError: false },
  { kind: "assistantText", text: "two" },
];

const settings: RequestSettings = {
  reasoning: {},
  temperature: 0.5,
  toolChoice: "auto",
};

/** The plan of the `round.before` hooks of `plugins` for a round of `context`. */
async function plan(plugins: readonly { name: string; session: PluginSession }[]): Promise<RoundPlan> {
  await using host = await createHost({ plugins });
  const session = await host.openSession();
  return await session.runHook("round.before", {
    blocks: context,
    contextWindow: 200_000,
    inputTokens: 1200,
    settings,
  });
}

/** A plugin whose `round.before` handler gives `answer`. */
const answering =
  (answer: SessionHooks["round.before"]): PluginSession =>
  (s) => {
    s.addHook("round.before", answer);
  };

test("a handler gets the context window, the tokens, and the blocks, and no answer keeps the round", async () => {
  let seen = "";
  const watch: PluginSession = (s) => {
    s.addHook("round.before", (event) => {
      const first = event.blocks();
      (first[0] as { text: string }).text = "changed";
      seen = JSON.stringify({
        contextWindow: event.contextWindow,
        inputTokens: event.inputTokens,
        blockCount: event.blockCount,
        blocks: event.blocks(),
      });
      return undefined;
    });
  };

  equal(await plan([{ name: "watch", session: watch }]), {});
  // Each call of `context` gives a new copy, so the change of the first copy is not in the second.
  equal(
    seen,
    '{"contextWindow":200000,"inputTokens":1200,"blockCount":4,"blocks":[{"kind":"userText","text":"one"},{"kind":"toolCall","callId":"c1","name":"read","arguments":"{}"},{"kind":"toolResult","callId":"c1","content":"done","isError":false},{"kind":"assistantText","text":"two"}]}',
  );
});

test("a later handler gets the replaced context, and the plan combines the replacements", async () => {
  let seen = "";
  const first = answering(() => ({ replace: { head: [{ kind: "userText", text: "summary" }], keep: 1 } }));
  const second: PluginSession = (s) => {
    s.addHook("round.before", (event) => {
      seen = JSON.stringify({
        contextTokens: event.contextTokens,
        blockCount: event.blockCount,
        tokens: event.blockTokens(),
        blocks: event.blocks(),
      });
      return { replace: { head: [{ kind: "userText", text: "newer" }], keep: 2 } };
    });
  };

  const planned = await plan([
    { name: "first", session: first },
    { name: "second", session: second },
  ]);

  // The count of the newest answer describes the context before the replacement, so each block counts.
  equal(
    seen,
    '{"contextTokens":3,"blockCount":2,"tokens":[2,1],"blocks":[{"kind":"userText","text":"summary"},{"kind":"assistantText","text":"two"}]}',
  );
  // The second keeps the head of the first and the text, so the plan keeps 1 block of the context before the round.
  equal(planned.replace, {
    head: [
      { kind: "userText", text: "newer" },
      { kind: "userText", text: "summary" },
    ],
    keep: 1,
  });
});

for (const [name, first, second, expected] of [
  [
    "a keep past the length keeps the whole context after the first head",
    { head: [{ kind: "userText", text: "summary" }], keep: 1 },
    { head: [{ kind: "userText", text: "newer" }], keep: 9 },
    {
      head: [
        { kind: "userText", text: "newer" },
        { kind: "userText", text: "summary" },
      ],
      keep: 1,
    },
  ],
  [
    "an empty head after a replacement drops the head before it",
    { head: [{ kind: "userText", text: "summary" }], keep: 1 },
    { head: [], keep: 1 },
    { head: [], keep: 1 },
  ],
  [
    "a later smaller keep cuts into the blocks that the first one kept",
    { head: [], keep: 3 },
    { head: [{ kind: "userText", text: "newer" }], keep: 1 },
    { head: [{ kind: "userText", text: "newer" }], keep: 1 },
  ],
] as const) {
  test(name, async () => {
    const planned = await plan([
      { name: "first", session: answering(() => ({ replace: first })) },
      { name: "second", session: answering(() => ({ replace: second })) },
    ]);

    equal(planned.replace, expected);
  });
}

test("a later model wins, and the settings of each answer merge field by field", async () => {
  const first = answering(() => ({
    model: { provider: "openai", model: "gpt-4.1" },
    settings: { temperature: 0.1, topP: 0.9 },
  }));
  const second = answering(() => ({
    model: { provider: "openai", model: "gpt-4.1-mini" },
    settings: { temperature: 0.2, reasoning: { effort: "high" } },
  }));

  const planned = await plan([
    { name: "first", session: first },
    { name: "second", session: second },
  ]);

  equal(
    [planned.model, planned.settings?.temperature, planned.settings?.topP, planned.settings?.reasoning.effort],
    ["gpt-4.1-mini", 0.2, 0.9, "high"],
  );
  equal(planned.replace, undefined);
});

for (const [name, answer, expected] of [
  [
    "a model that the catalog lacks",
    () => ({ model: { provider: "openai", model: "missing" } }),
    "openai/missing: the catalog holds no model with that name",
  ],
  [
    "a throw",
    () => {
      throw new Error("no plan");
    },
    "Error: no plan",
  ],
  [
    "a misspelt setting",
    () => ({ settings: { temprature: 1 } }) as never,
    "the settings have the unknown field 'temprature'",
  ],
] as const) {
  test(`${name} fails the round and names the plugin`, async () => {
    const error = await rejects(plan([{ name: "planner", session: answering(answer) }]));

    const message = error instanceof Error ? error.message : String(error);
    const prefix = `round.before of plugin planner failed: ${expected}`;
    equal(message.slice(0, prefix.length), prefix);
  });
}

test("a round of run has the model of the session, and its window unless the event names one", async () => {
  const windows: (number | undefined)[] = [];
  const side: PluginSession = (s) => {
    s.addHook("round.before", async (event) => {
      windows.push(event.contextWindow);
      await event.sideRequest({ prompt: "Summarize." });
      return undefined;
    });
  };
  const replies = ["One.", "Two.", "Turn.", "Three."].map((text) => reply.text(text));
  await using host = await createHost({ plugins: [{ name: "side", session: side }], replies });
  const session = await host.openSession({ model: { provider: "openai", model: "gpt-4.1" } });

  await session.runHook("round.before", { blocks: [{ kind: "userText", text: "one" }] });
  await session.runHook("round.before", { blocks: [{ kind: "userText", text: "one" }], contextWindow: 1000 });
  await session.sendMessage("A turn.");

  const [run, named, turn] = windows;
  equal([run === turn, named, typeof turn], [true, 1000, "number"]);
  equal(
    host.requests.map((request) => (request.body as { model: string }).model),
    ["gpt-4.1", "gpt-4.1", "gpt-4.1", "gpt-4.1"],
  );
});
