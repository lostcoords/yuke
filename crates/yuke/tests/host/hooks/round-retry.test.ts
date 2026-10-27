// The `round.retry` hook: its event, its count of retries, its plan, and the kinds of a failure.

import type { PluginSession, RoundFailureKind } from "yuke:plugins";
import { createFakeModel, createHost, equal, rejects, reply, test } from "yuke:test";

// The count belongs to one round, so the round after a call counts from zero again.
test("an answer sends the round again, and each round counts its retries from zero", async () => {
  const greeter: PluginSession = (s) => {
    s.tools.define({
      name: "greet",
      description: "Greet someone.",
      concurrency: "serial",
      parameters: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
      execute: (args) => `hello ${args.who}`,
    });
  };
  const seen: string[] = [];
  const compact: PluginSession = (s) => {
    s.hook("round.retry", (event) => {
      seen.push(`${event.failure.kind} ${event.retries} ${event.failure.message.includes("prompt is too long")}`);
      return { replace: { head: [{ user_text: "summary" }], keep: 0 } };
    });
  };
  const model = createFakeModel([
    reply.overflow(),
    reply.overflow(),
    reply.toolCall("greet", { who: "Ada" }),
    reply.overflow(),
    reply.text("Done."),
  ]);
  await using host = await createHost({
    plugins: [
      { name: "greeter", session: greeter },
      { name: "compact", session: compact },
    ],
    model,
  });
  const session = await host.openSession();

  await session.send("Greet Ada.");

  equal(seen, ["context_overflow 0 true", "context_overflow 1 true", "context_overflow 0 true"]);
  equal(
    model.requests.map((request) => request.messages[0]?.text),
    ["Greet Ada.", "summary", "summary", "summary", "summary"],
  );
  equal(session.transcript.entries.at(-1)?.kind, "end");
});

test("without an answer the round does not run again, and the turn fails", async () => {
  const quiet: PluginSession = (s) => {
    s.hook("round.retry", () => undefined);
  };
  const model = createFakeModel([reply.overflow()]);
  await using host = await createHost({ plugins: [{ name: "quiet", session: quiet }], model });
  const session = await host.openSession();

  await session.send("Hi.");

  const end = session.transcript.entries.at(-1);
  equal([end?.kind, end?.kind === "end" && "failed" in end.end, model.requests.length], ["end", true, 1]);
});

test("round.retry gives undefined without an answer, and the plan with one", async () => {
  const retry: PluginSession = (s) => {
    s.hook("round.retry", (event) =>
      event.failure.kind === "context_overflow" && event.retries === 1 ? {} : undefined,
    );
  };
  await using host = await createHost({ plugins: [{ name: "retry", session: retry }] });
  const session = await host.openSession();
  const round = { context: [{ user_text: "one" }] };

  equal(await session.run("round.retry", { ...round, failure: { kind: "server_error" } }), undefined);
  equal(await session.run("round.retry", { ...round, failure: { kind: "context_overflow" }, retries: 1 }), {});
});

test("round.retry gets each failure kind as a turn gives it", async () => {
  const kinds: readonly RoundFailureKind[] = [
    "context_overflow",
    "rate_limited",
    "rate_limit_unknown",
    "quota_exhausted",
    "server_error",
    "timeout",
    "conflict",
    "auth_failed",
    "permission_denied",
    "bad_status",
    "provider_failed",
    "transport",
    "protocol",
    "response_too_large",
    "incomplete_stream",
    "encode",
    "credential",
  ];
  const seen: RoundFailureKind[] = [];
  const retry: PluginSession = (s) => {
    s.hook("round.retry", (event) => {
      seen.push(event.failure.kind);
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "retry", session: retry }] });
  const session = await host.openSession();

  for (const kind of kinds) await session.run("round.retry", { context: [], failure: { kind } });

  equal(seen, kinds);
});

test("a bad answer fails the hook and names the point and the plugin", async () => {
  const broken: PluginSession = (s) => {
    s.hook("round.retry", () => ({ model: { provider: "nope" } }) as never);
  };
  await using host = await createHost({ plugins: [{ name: "broken", session: broken }] });
  const session = await host.openSession();

  const failure = await rejects(
    session.run("round.retry", { context: [{ user_text: "one" }], failure: { kind: "context_overflow" } }),
  );

  const message = failure instanceof Error ? failure.message : String(failure);
  equal(message.startsWith("round.retry of plugin broken failed"), true);
});

test("a handler gets the window, the tokens, and the blocks of the failed round, and its plan replaces the context", async () => {
  const seen: string[] = [];
  const compact: PluginSession = (s) => {
    s.hook("round.retry", (event) => {
      const fields = [event.retries, event.window, event.inputTokens, event.contextTokens, event.blocks];
      seen.push(`${event.failure.kind} ${fields.join(" ")} ${event.blockTokens()}`);
      return { replace: { head: [{ user_text: "summary" }], keep: 0 } };
    });
  };
  await using host = await createHost({ plugins: [{ name: "compact", session: compact }] });
  const session = await host.openSession();

  const plan = await session.run("round.retry", {
    context: [{ user_text: "one" }],
    window: 1000,
    inputTokens: 900,
    failure: { kind: "context_overflow" },
  });

  equal(seen, ["context_overflow 0 1000 900 901 1 1"]);
  equal(plan, { replace: { head: [{ user_text: "summary" }], keep: 0 } });
});

test("the failure names its kind and its text", async () => {
  const seen: string[] = [];
  const watch: PluginSession = (s) => {
    s.hook("round.retry", (event) => {
      seen.push(`${event.failure.kind}: ${event.failure.message}`);
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "watch", session: watch }] });
  const session = await host.openSession();

  for (const kind of ["rate_limited", "transport", "incomplete_stream", "credential"] as const) {
    await session.run("round.retry", { context: [], failure: { kind } });
  }

  equal(seen, [
    "rate_limited: the provider rate limit stopped the request",
    "transport: the provider connection ended",
    "incomplete_stream: the provider stream ended early",
    "credential: the test failed the credential",
  ]);
});
