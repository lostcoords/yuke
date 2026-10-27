// One hook point of a session of the test host through `run`: the decision of the host after each handler.

import type { PluginSession, RoundFailureKind } from "yuke:plugins";
import { createFakeModel, createHost, equal, rejects, reply, test } from "yuke:test";

const call = { id: "c1", name: "read", arguments: { path: "a.txt" } };

test("tool.before gives the first block in plugin order, and the later handlers do not run", async () => {
  const seen: string[] = [];
  const handler =
    (name: string, block: boolean): PluginSession =>
    (s) => {
      s.hook("tool.before", (event) => {
        seen.push(name);
        return block ? { block: `${name}: no ${event.call.name}` } : undefined;
      });
    };
  await using host = await createHost({
    plugins: [
      { name: "first", session: handler("first", false) },
      { name: "second", session: handler("second", true) },
      { name: "third", session: handler("third", true) },
    ],
  });
  const session = await host.openSession();

  equal(await session.run("tool.before", { call }), { block: "second: no read" });
  equal(seen, ["first", "second"]);
});

test("tool.before without a handler that answers runs the call", async () => {
  await using host = await createHost({ plugins: [] });
  const session = await host.openSession();

  equal(await session.run("tool.before", { call }), "run");
});

test("tool.after gives the result after each handler", async () => {
  const upper: PluginSession = (s) => {
    s.hook("tool.after", (event) => ({ text: event.result.text.toUpperCase() }));
  };
  await using host = await createHost({ plugins: [{ name: "upper", session: upper }] });
  const session = await host.openSession();

  equal(await session.run("tool.after", { call, result: { text: "small", isError: false } }), {
    text: "SMALL",
    isError: false,
    media: [],
  });
});

test("round.before gives the plan of the round, and the handler sees the plain data as functions", async () => {
  const planner: PluginSession = (s) => {
    s.hook("round.before", (event) => ({
      replace: { head: [{ user_text: `${event.context().length} blocks in ${event.window}` }], keep: 1 },
      settings: { temperature: 0.5 },
    }));
  };
  await using host = await createHost({ plugins: [{ name: "planner", session: planner }] });
  const session = await host.openSession();

  const plan = await session.run("round.before", {
    context: [{ user_text: "one" }, { assistant_text: "two" }],
    window: 1000,
  });

  equal(plan.replace, { head: [{ user_text: "2 blocks in 1000" }], keep: 1 });
  equal(plan.settings?.temperature, 0.5);
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

test("round.after stops the turn, and a continue answer adds its input to the session", async () => {
  const after: PluginSession = (s) => {
    s.hook("round.after", (event) => (event.text === "stop" ? { stop: true } : { continue: "go on" }));
  };
  await using host = await createHost({ plugins: [{ name: "after", session: after }] });
  const session = await host.openSession();

  equal(await session.run("round.after", { text: "stop", finishReason: "stop" }), "stop");
  equal(await session.run("round.after", { text: "more", continues: 2 }), "proceed");
  equal(
    [...session.transcript.pending.values()].map((input) => input.kind),
    ["notification"],
  );
});

test("input.before replaces or removes the input", async () => {
  const filter: PluginSession = (s) => {
    s.hook("input.before", (event) => {
      const first = event.blocks[0];
      if (first !== undefined && "user_text" in first && first.user_text === "drop") return { block: "dropped" };
      return { replace: { blocks: [{ user_text: "replaced" }] } };
    });
  };
  await using host = await createHost({ plugins: [{ name: "filter", session: filter }] });
  const session = await host.openSession();
  const source = { kind: "user" } as const;

  equal(await session.run("input.before", { source, kind: "message", blocks: [{ user_text: "drop" }] }), "remove");
  equal(await session.run("input.before", { source, kind: "message", blocks: [{ user_text: "keep" }] }), {
    replace: { blocks: [{ user_text: "replaced" }] },
  });
});

test("prompt.build gives the sections after each handler, in the order of the prompt", async () => {
  const seen: string[][] = [];
  const prompt: PluginSession = (s) => {
    s.hook("prompt.build", (event) => {
      seen.push(Object.keys(event.sections));
      return { sections: { ...event.sections, rules: "Be short." } };
    });
  };
  await using host = await createHost({ plugins: [{ name: "prompt", session: prompt }] });
  const session = await host.openSession();

  const built = await session.run("prompt.build", { sections: { zeta: "You help.", alpha: "You read." } });

  equal(seen, [["zeta", "alpha"]]);
  equal(Object.entries(built.sections), [
    ["zeta", "You help."],
    ["alpha", "You read."],
    ["rules", "Be short."],
  ]);
});

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
  const model = createFakeModel(replies);
  await using host = await createHost({ plugins: [{ name: "side", session: side }], model });
  const session = await host.openSession({ model: { provider: "openai", model: "gpt-4.1" } });

  await session.run("round.before", { context: [{ user_text: "one" }] });
  await session.run("round.before", { context: [{ user_text: "one" }], window: 1000 });
  await session.send("A turn.");

  const [run, named, turn] = windows;
  equal([run === turn, named, typeof turn], [true, 1000, "number"]);
  equal(
    model.requests.map((request) => (request.body as { model: string }).model),
    ["gpt-4.1", "gpt-4.1", "gpt-4.1", "gpt-4.1"],
  );
});

test("a failed handler gives the failure that a turn meets", async () => {
  const broken: PluginSession = (s) => {
    s.hook("round.before", () => {
      throw new Error("broken plan");
    });
  };
  await using host = await createHost({ plugins: [{ name: "broken", session: broken }] });
  const session = await host.openSession();

  const error = await rejects(session.run("round.before", { context: [] }));

  equal(error instanceof Error && error.message.includes("broken plan"), true);
});
