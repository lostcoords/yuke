// The `round.before` hook: its event, the chain of its answers, its plan, and its failures.

import type { PluginSession, SessionHooks } from "yuke:plugins";
import type { Block, Settings } from "yuke:protocol";
import { createHost, equal, type RoundPlan, rejects, reply, test } from "yuke:test";

/** A context of 4 blocks: the input, a call and its result, and a text. */
const context: Block[] = [
  { user_text: "one" },
  { tool_call: { callId: "c1", name: "read", arguments: "{}" } },
  { tool_result: { callId: "c1", content: "done", isError: false } },
  { assistant_text: "two" },
];

const settings: Settings = {
  maxOutputTokens: null,
  reasoning: { thinking: null, effort: null },
  temperature: 0.5,
  topP: null,
  toolChoice: "auto",
  outputSchema: null,
};

/** The plan of the `round.before` hooks of `plugins` for a round of `context`. */
async function plan(plugins: readonly { name: string; session: PluginSession }[]): Promise<RoundPlan> {
  await using host = await createHost({ plugins });
  const session = await host.openSession();
  return await session.run("round.before", { context, window: 200_000, inputTokens: 1200, settings });
}

/** A plugin whose `round.before` handler gives `answer`. */
const answering =
  (answer: SessionHooks["round.before"]): PluginSession =>
  (s) => {
    s.hook("round.before", answer);
  };

test("a handler gets the window, the tokens, and the context, and no answer keeps the round", async () => {
  let seen = "";
  const watch: PluginSession = (s) => {
    s.hook("round.before", (event) => {
      const first = event.context();
      (first[0] as { user_text: string }).user_text = "changed";
      seen = JSON.stringify({
        window: event.window,
        inputTokens: event.inputTokens,
        contextTokens: event.contextTokens,
        blocks: event.blocks,
        tokens: event.blockTokens(),
        context: event.context(),
      });
      return undefined;
    });
  };

  equal(await plan([{ name: "watch", session: watch }]), {});
  // Each call of `context` gives a new copy, so the change of the first copy is not in the second. The count holds
  // every block before the newest answer, so only the text `two` adds to it.
  equal(
    seen,
    '{"window":200000,"inputTokens":1200,"contextTokens":1201,"blocks":4,"tokens":[1,2,1,1],"context":[{"user_text":"one"},{"tool_call":{"callId":"c1","name":"read","arguments":"{}"}},{"tool_result":{"callId":"c1","content":"done","isError":false}},{"assistant_text":"two"}]}',
  );
});

test("a later handler gets the replaced context, and the plan combines the replacements", async () => {
  let seen = "";
  const first = answering(() => ({ replace: { head: [{ user_text: "summary" }], keep: 1 } }));
  const second: PluginSession = (s) => {
    s.hook("round.before", (event) => {
      seen = JSON.stringify({
        contextTokens: event.contextTokens,
        blocks: event.blocks,
        tokens: event.blockTokens(),
        context: event.context(),
      });
      return { replace: { head: [{ user_text: "newer" }], keep: 2 } };
    });
  };

  const planned = await plan([
    { name: "first", session: first },
    { name: "second", session: second },
  ]);

  // The count of the newest answer describes the context before the replacement, so each block counts.
  equal(
    seen,
    '{"contextTokens":3,"blocks":2,"tokens":[2,1],"context":[{"user_text":"summary"},{"assistant_text":"two"}]}',
  );
  // The second keeps the head of the first and the text, so the plan keeps 1 block of the context before the round.
  equal(planned.replace, { head: [{ user_text: "newer" }, { user_text: "summary" }], keep: 1 });
});

for (const [name, first, second, expected] of [
  [
    "a keep past the length keeps the whole context after the first head",
    { head: [{ user_text: "summary" }], keep: 1 },
    { head: [{ user_text: "newer" }], keep: 9 },
    { head: [{ user_text: "newer" }, { user_text: "summary" }], keep: 1 },
  ],
  [
    "an empty head after a replacement drops the head before it",
    { head: [{ user_text: "summary" }], keep: 1 },
    { head: [], keep: 1 },
    { head: [], keep: 1 },
  ],
  [
    "a later smaller keep cuts into the blocks that the first one kept",
    { head: [], keep: 3 },
    { head: [{ user_text: "newer" }], keep: 1 },
    { head: [{ user_text: "newer" }], keep: 1 },
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
    settings: { temperature: 0.2, reasoning: { thinking: null, effort: "high" } },
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
] as const) {
  test(`${name} fails the round and names the plugin`, async () => {
    const error = await rejects(plan([{ name: "planner", session: answering(answer) }]));

    const message = error instanceof Error ? error.message : String(error);
    const prefix = `round.before of plugin planner failed: ${expected}`;
    equal(message.slice(0, prefix.length), prefix);
  });
}

test("a round of run has the model of the session, and its window unless the event names one", async () => {
  const windows: (number | null)[] = [];
  const side: PluginSession = (s) => {
    s.hook("round.before", async (event) => {
      windows.push(event.window);
      await event.sideRequest({ prompt: "Summarize." });
      return undefined;
    });
  };
  const replies = ["One.", "Two.", "Turn.", "Three."].map((text) => reply.text(text));
  await using host = await createHost({ plugins: [{ name: "side", session: side }], replies });
  const session = await host.openSession({ model: { provider: "openai", model: "gpt-4.1" } });

  await session.run("round.before", { context: [{ user_text: "one" }] });
  await session.run("round.before", { context: [{ user_text: "one" }], window: 1000 });
  await session.send("A turn.");

  const [run, named, turn] = windows;
  equal([run === turn, named, typeof turn], [true, 1000, "number"]);
  equal(
    host.requests.map((request) => (request.body as { model: string }).model),
    ["gpt-4.1", "gpt-4.1", "gpt-4.1", "gpt-4.1"],
  );
});
