// The turns of a session of the test host: the fake model, the transcript, and the hooks and the tools of a plugin.

import type { PluginSession } from "yuke:plugins";
import { assert, createFakeModel, createHost, equal, folder, rejects, reply, test } from "yuke:test";
import type { Entry } from "yuke:transcript";
import { waitFor } from "./wait.ts";

/** A plugin whose session defines the tool `greet`, which answers `hello` and its argument. */
const greeter: PluginSession = (s) => {
  s.tools.define({
    name: "greet",
    description: "Greet someone.",
    concurrency: "serial",
    parameters: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
    execute: (args) => `hello ${args.who}`,
  });
};

/** The tool entry at `index`. */
function tool(entries: readonly Entry[], index: number): Extract<Entry, { kind: "tool" }> {
  const entry = entries[index];
  assert(entry?.kind === "tool", `the entry ${index} is no tool`);
  return entry;
}

test("a turn sends the message to the fake model and shows its answer", async () => {
  const model = createFakeModel([reply.text("Hello.")]);
  await using host = await createHost({ plugins: [], model });
  const session = await host.openSession();

  await session.send("Hi.");

  equal(
    session.transcript.entries.map((entry) => entry.kind),
    ["input", "text", "end"],
  );
  equal(model.requests.length, 1);
  equal(model.requests[0]?.messages.at(-1)?.text, "Hi.");
});

test("a tool of a plugin runs in a turn, and the model gets its result", async () => {
  const model = createFakeModel([reply.toolCall("greet", { who: "Ada" }), reply.text("Done.")]);
  await using host = await createHost({ plugins: [{ name: "greeter", session: greeter }], model });
  const session = await host.openSession();

  await session.send("Greet Ada.");

  const call = tool(session.transcript.entries, 1);
  equal([call.name, call.status, call.result?.content, call.result?.isError], ["greet", "done", "hello Ada", false]);
  equal(model.requests[0]?.tools.includes("greet"), true);
  equal(model.requests.length, 2);
});

test("a tool.before handler blocks a call in a turn", async () => {
  const model = createFakeModel([reply.toolCall("greet", { who: "Ada" }), reply.text("Blocked.")]);
  const guard: PluginSession = (s) => {
    s.hook("tool.before", (event) => (event.call.name === "greet" ? { block: "no greetings" } : undefined));
  };
  await using host = await createHost({
    plugins: [
      { name: "greeter", session: greeter },
      { name: "guard", session: guard },
    ],
    model,
  });
  const session = await host.openSession();

  await session.send("Greet Ada.");

  const call = tool(session.transcript.entries, 1);
  equal([call.result?.isError, call.result?.content.includes("no greetings")], [true, true]);
});

test("an overloaded answer gets a retry without a wait", async () => {
  const model = createFakeModel([reply.overloaded(), reply.text("Hello.")]);
  await using host = await createHost({ plugins: [], model });
  const session = await host.openSession();
  const start = Date.now();

  await session.send("Hi.");

  equal(model.requests.length, 2);
  assert(Date.now() - start < 1000, "the retry waited");
});

test("a cut answer does not run its calls, and the model gets an error result", async () => {
  const model = createFakeModel([reply.cut([{ name: "greet", args: { who: "Ada" } }]), reply.text("Sorry.")]);
  await using host = await createHost({ plugins: [{ name: "greeter", session: greeter }], model });
  const session = await host.openSession();

  await session.send("Greet Ada.");

  const call = tool(session.transcript.entries, 1);
  equal([call.name, call.result?.isError, call.result?.content.includes("output token limit")], ["greet", true, true]);
  equal(model.requests.length, 2);
});

test("an answer that fails after its first text ends the turn without a retry", async () => {
  const model = createFakeModel([reply.failed("Hal")]);
  await using host = await createHost({ plugins: [], model });
  const session = await host.openSession();

  await session.send("Hi.");

  const end = session.transcript.entries.at(-1);
  assert(end?.kind === "end" && "failed" in end.end, "the turn did not fail");
  equal(model.requests.length, 1);
});

test("an abort of the signal cancels a turn that waits for the model, and send rejects", async () => {
  const model = createFakeModel([reply.stall("Hal")]);
  await using host = await createHost({ plugins: [], model });
  const session = await host.openSession();
  const stop = new AbortController();
  const sent = rejects(session.send("Hi.", { signal: stop.signal }));
  await waitFor(() => model.requests.length === 1);
  stop.abort(new Error("stop"));

  const error = await sent;

  equal(error instanceof Error ? error.message : error, "stop");
  equal(session.transcript.entries.at(-1), { kind: "end", key: "3:end", end: { outcome: "cancelled" } });
});

test("send with an aborted signal rejects and sends nothing", async () => {
  await using host = await createHost({ plugins: [] });
  const session = await host.openSession();

  const error = await rejects(session.send("Hi.", { signal: AbortSignal.abort(new Error("early")) }));

  equal(error instanceof Error ? error.message : error, "early");
  equal(session.transcript.entries, []);
});

test("a session without settings uses the test model in the folder of the test", async () => {
  const model = createFakeModel([reply.text("Hello.")]);
  await using host = await createHost({ plugins: [], model });
  const session = await host.openSession();

  await session.send("Hi.");

  const request = model.requests[0];
  assert(request !== undefined, "no request");
  equal(request.messages, [{ role: "user", text: "Hi." }]);
  equal(request.tools, ["read", "write", "edit", "exec", "stop"]);
  assert(request.system.includes(folder()), "the system text names no workspace");
  const body = request.body as Record<string, unknown>;
  equal([body.model, body.temperature, body.top_p], ["MiniMax-M3", undefined, undefined]);
});

// Each catalog model gets the fake answers in the stream format of its protocol.
for (const model of [
  { provider: "minimax", model: "MiniMax-M3" },
  { provider: "cerebras", model: "gpt-oss-120b" },
  { provider: "openai", model: "gpt-4.1" },
]) {
  test(`a turn with a tool call runs on ${model.provider}/${model.model}`, async () => {
    const fake = createFakeModel([reply.toolCall("greet", { who: "Ada" }), reply.text("Done.")]);
    await using host = await createHost({ plugins: [{ name: "greeter", session: greeter }], model: fake });
    const session = await host.openSession({ model });

    await session.send("Greet Ada.");

    equal(
      session.transcript.entries.map((entry) => entry.kind),
      ["input", "tool", "text", "end"],
    );
    equal(tool(session.transcript.entries, 1).result?.content, "hello Ada");
    const [first, second] = fake.requests;
    assert(first !== undefined && second !== undefined, "the model got no two requests");
    equal(first.messages, [{ role: "user", text: "Greet Ada." }]);
    equal([first.tools.includes("greet"), first.system.includes(folder())], [true, true]);
    equal(second.messages.at(-1)?.text, "hello Ada");
    equal((second.body as { model?: string }).model, model.model);
  });
}
