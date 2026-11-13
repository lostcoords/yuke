// The `round.retry` hook: its event, its count of retries, its plan, and the kinds of a failure.

import type { PluginSession } from "yuke:plugins";
import { assertEquals, createHost, reply, test } from "yuke:test";

// The count belongs to one round, so the round after a call counts from zero again.
test("an answer sends the round again, and each round counts its retries from zero", async () => {
  const greeter: PluginSession = (s) => {
    s.tools.add({
      name: "greet",
      description: "Greet someone.",
      concurrency: "serial",
      inputSchema: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
      execute: (args) => `hello ${args.who}`,
    });
  };
  const seen: string[] = [];
  const compact: PluginSession = (s) => {
    s.addHook("round.retry", (event) => {
      seen.push(`${event.failure.kind} ${event.retries} ${event.failure.text.includes("prompt is too long")}`);
      return { replace: { head: [{ kind: "userText", text: "summary" }], keep: 0 } };
    });
  };
  const replies = [
    reply.overflow(),
    reply.overflow(),
    reply.toolCalls([{ name: "greet", args: { who: "Ada" } }]),
    reply.overflow(),
    reply.text("Done."),
  ];
  await using host = await createHost({
    plugins: [
      { name: "greeter", session: greeter },
      { name: "compact", session: compact },
    ],
    replies,
  });
  const session = await host.openSession();

  await session.sendMessage("Greet Ada.");

  assertEquals(seen, ["contextOverflow 0 true", "contextOverflow 1 true", "contextOverflow 0 true"]);
  assertEquals(
    host.requests.map((request) => request.messages[0]?.text),
    ["Greet Ada.", "summary", "summary", "summary", "summary"],
  );
  assertEquals(session.transcript.entries.at(-1)?.kind, "end");
});

test("without an answer the round does not run again, and the turn fails", async () => {
  const quiet: PluginSession = (s) => {
    s.addHook("round.retry", () => undefined);
  };
  const replies = [reply.overflow()];
  await using host = await createHost({ plugins: [{ name: "quiet", session: quiet }], replies });
  const session = await host.openSession();

  await session.sendMessage("Hi.");

  const end = session.transcript.entries.at(-1);
  assertEquals([end?.kind, end?.kind === "end" && end.end.kind === "failed", host.requests.length], ["end", true, 1]);
});

test("a handler gets the context window, the tokens, and the blocks of the failed round, and its plan replaces the context", async () => {
  const seen: string[] = [];
  const compact: PluginSession = (s) => {
    s.addHook("round.retry", (event) => {
      const fields = [event.retries, event.contextWindow, event.inputTokens, event.contextTokens, event.blockCount];
      seen.push(`${event.failure.kind} ${fields.join(" ")} ${event.blockTokens()}`);
      return { replace: { head: [{ kind: "userText", text: "summary" }], keep: 0 } };
    });
  };
  await using host = await createHost({ plugins: [{ name: "compact", session: compact }] });
  const session = await host.openSession();

  const plan = await session.runHook("round.retry", {
    blocks: [{ kind: "userText", text: "one" }],
    contextWindow: 1000,
    inputTokens: 900,
    failure: { kind: "contextOverflow" },
  });

  assertEquals(seen, ["contextOverflow 0 1000 900 901 1 1"]);
  assertEquals(plan, { replace: { head: [{ kind: "userText", text: "summary" }], keep: 0 } });
});

test("the failure names its kind and its text", async () => {
  const seen: [string, boolean][] = [];
  const watch: PluginSession = (s) => {
    s.addHook("round.retry", (event) => {
      seen.push([event.failure.kind, event.failure.text.length > 0]);
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "watch", session: watch }] });
  const session = await host.openSession();

  for (const kind of ["rateLimited", "transport", "incompleteStream", "credential"] as const) {
    await session.runHook("round.retry", { blocks: [], failure: { kind } });
  }

  assertEquals(seen, [
    ["rateLimited", true],
    ["transport", true],
    ["incompleteStream", true],
    ["credential", true],
  ]);
});
