// The `round.after` hook: its event, its answers, its count, and its failures.

import type { PluginSession } from "yuke:plugins";
import { assertEquals, assertRejects, createHost, reply, test } from "yuke:test";

// After a round of calls, the turn goes on, so the event has no reason, and the text is the text before the calls.
test("a handler gets the text, the reason, and the count of each round of a turn", async () => {
  const greeter: PluginSession = (s) => {
    s.tools.add({
      name: "greet",
      description: "Greet someone.",
      concurrency: "serial",
      parameters: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
      execute: (args) => `hello ${args.who}`,
    });
  };
  const seen: unknown[] = [];
  const watch: PluginSession = (s) => {
    s.addHook("round.after", (event) => {
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

  await session.sendMessage("Greet Ada.");

  assertEquals(seen, [
    ["checking", undefined, 0],
    ["Done.", "stop", 0],
  ]);
  assertEquals(
    session.transcript.entries.map((entry) => entry.kind),
    ["input", "text", "tool", "text", "end"],
  );
});

// The count belongs to one turn, so a plugin can guard its loop with it.
test("the first answer decides, and a continue is a counted notification of its plugin", async () => {
  let second = 0;
  const guard: PluginSession = (s) => {
    s.addHook("round.after", (event) => (event.continues === 0 ? { continue: "Run the tests." } : undefined));
  };
  const stopper: PluginSession = (s) => {
    s.addHook("round.after", () => {
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

  await session.sendMessage("Work.");
  await session.sendMessage("More.");

  const notice = '<system_notification plugin="tests-guard">Run the tests.</system_notification>';
  assertEquals(
    host.requests.map((request) => request.messages.at(-1)?.text),
    ["Work.", notice, "More.", notice],
  );
  const inputs = session.transcript.entries.flatMap((entry) =>
    entry.kind === "input" ? [[entry.source, entry.inputKind, entry.content]] : [],
  );
  const continued = [
    { kind: "plugin", name: "tests-guard" },
    "notification",
    [{ kind: "userText", text: "Run the tests." }],
  ];
  assertEquals(inputs, [
    [{ kind: "user" }, "message", [{ kind: "userText", text: "Work." }]],
    continued,
    [{ kind: "user" }, "message", [{ kind: "userText", text: "More." }]],
    continued,
  ]);
  assertEquals(second, 2);
});

test("round.after stops the turn, and a continue answer adds its input to the session", async () => {
  const after: PluginSession = (s) => {
    // Only the round "more" continues, so the turn that its input starts stops after one round.
    s.addHook("round.after", (event) => (event.text === "more" ? { continue: "go on" } : { stop: true }));
  };
  await using host = await createHost({ plugins: [{ name: "after", session: after }], replies: [reply.text("Done.")] });
  const session = await host.openSession();

  assertEquals(await session.runHook("round.after", { text: "stop", finishReason: "stop" }), "stop");
  assertEquals(await session.runHook("round.after", { text: "more", continues: 2 }), "proceed");
  // The input of the continue answer starts a turn in the idle session, and the turn takes it.
  assertEquals(
    session.transcript.entries.some((entry) => entry.kind === "end"),
    true,
  );
  assertEquals(
    session.transcript.entries.flatMap((entry) => (entry.kind === "input" ? [[entry.inputKind, entry.content]] : [])),
    [["notification", [{ kind: "userText", text: "go on" }]]],
  );
});

test("a throw fails the turn and names the plugin", async () => {
  const judge: PluginSession = (s) => {
    s.addHook("round.after", () => {
      throw new Error("no verdict");
    });
  };
  await using host = await createHost({ plugins: [{ name: "judge", session: judge }] });
  const session = await host.openSession();

  const failure = await assertRejects(() =>
    session.runHook("round.after", { text: "first part", finishReason: "stop" }),
  );

  assertEquals(
    failure instanceof Error ? failure.message : failure,
    "round.after of plugin judge failed: Error: no verdict",
  );
});
