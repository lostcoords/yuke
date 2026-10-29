// The `round.after` hook: its event, its answers, its count, and its failures.

import type { PluginSession } from "yuke:plugins";
import { createHost, equal, rejects, reply, test } from "yuke:test";
import { waitFor } from "../wait.ts";

// After a round of calls, the turn goes on, so the reason is `null`, and the text is the text before the calls.
test("a handler gets the text, the reason, and the count of each round of a turn", async () => {
  const greeter: PluginSession = (s) => {
    s.tools.define({
      name: "greet",
      description: "Greet someone.",
      concurrency: "serial",
      parameters: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
      execute: (args) => `hello ${args.who}`,
    });
  };
  const seen: unknown[] = [];
  const watch: PluginSession = (s) => {
    s.hook("round.after", (event) => {
      seen.push([event.text, event.finishReason, event.continues]);
      return undefined;
    });
  };
  const replies = [reply.toolCall("greet", { who: "Ada" }, { text: "checking" }), reply.text("Done.")];
  await using host = await createHost({
    plugins: [
      { name: "greeter", session: greeter },
      { name: "watch", session: watch },
    ],
    replies,
  });
  const session = await host.openSession();

  await session.send("Greet Ada.");

  equal(seen, [
    ["checking", null, 0],
    ["Done.", "stop", 0],
  ]);
  equal(
    session.transcript.entries.map((entry) => entry.kind),
    ["input", "text", "tool", "text", "end"],
  );
});

// The count belongs to one turn, so a plugin can guard its loop with it.
test("the first answer decides, and a continue is a counted notification of its plugin", async () => {
  let second = 0;
  const guard: PluginSession = (s) => {
    s.hook("round.after", (event) => (event.continues === 0 ? { continue: "Run the tests." } : undefined));
  };
  const stopper: PluginSession = (s) => {
    s.hook("round.after", () => {
      second += 1;
      return { stop: true };
    });
  };
  const replies = ["One.", "Two.", "Three.", "Four."].map((text) => reply.text(text));
  await using host = await createHost({
    plugins: [
      { name: "tests-guard", session: guard },
      { name: "second", session: stopper },
    ],
    replies,
  });
  const session = await host.openSession();

  await session.send("Work.");
  await session.send("More.");

  const notice = '<system_notification plugin="tests-guard">Run the tests.</system_notification>';
  equal(
    host.requests.map((request) => request.messages.at(-1)?.text),
    ["Work.", notice, "More.", notice],
  );
  const inputs = session.transcript.entries.flatMap((entry) =>
    entry.kind === "input" ? [[entry.source, entry.inputKind, entry.content]] : [],
  );
  const continued = [{ kind: "plugin", name: "tests-guard" }, "notification", [{ user_text: "Run the tests." }]];
  equal(inputs, [
    [{ kind: "user" }, "message", [{ user_text: "Work." }]],
    continued,
    [{ kind: "user" }, "message", [{ user_text: "More." }]],
    continued,
  ]);
  equal(second, 2);
});

test("round.after stops the turn, and a continue answer adds its input to the session", async () => {
  const after: PluginSession = (s) => {
    // Only the round "more" continues, so the turn that its input starts stops after one round.
    s.hook("round.after", (event) => (event.text === "more" ? { continue: "go on" } : { stop: true }));
  };
  await using host = await createHost({ plugins: [{ name: "after", session: after }], replies: [reply.text("Done.")] });
  const session = await host.openSession();

  equal(await session.run("round.after", { text: "stop", finishReason: "stop" }), "stop");
  equal(await session.run("round.after", { text: "more", continues: 2 }), "proceed");
  // The input of the continue answer starts a turn in the idle session, and the turn takes it.
  await waitFor(() => session.transcript.entries.some((entry) => entry.kind === "end"));
  equal(
    session.transcript.entries.flatMap((entry) => (entry.kind === "input" ? [[entry.inputKind, entry.content]] : [])),
    [["notification", [{ user_text: "go on" }]]],
  );
});

for (const [name, body, error] of [
  [
    "a throw",
    () => {
      throw new Error("no verdict");
    },
    "Error: no verdict",
  ],
  ["an empty answer", () => ({}), "TypeError: the answer needs exactly one of stop and continue"],
  [
    "two decisions",
    () => ({ stop: true, continue: "x" }),
    "TypeError: the answer needs exactly one of stop and continue",
  ],
  ["a stop that is not true", () => ({ stop: false }), "TypeError: the stop of the answer is not true"],
  ["a continue that is no text", () => ({ continue: 1 }), "TypeError: the continue of the answer is not a string"],
  ["an empty continue", () => ({ continue: "" }), "TypeError: the continue of the answer is empty"],
  ["an unknown field", () => ({ stop: true, why: "x" }), "TypeError: the answer has the unknown field 'why'"],
  ["a text", () => "stop", "TypeError: the answer is not an object"],
] as const) {
  test(`${name} fails the turn and names the plugin`, async () => {
    const judge: PluginSession = (s) => {
      s.hook("round.after", body as () => undefined);
    };
    await using host = await createHost({ plugins: [{ name: "judge", session: judge }] });
    const session = await host.openSession();

    const failure = await rejects(session.run("round.after", { text: "first part", finishReason: "stop" }));

    equal(failure instanceof Error ? failure.message : failure, `round.after of plugin judge failed: ${error}`);
  });
}
