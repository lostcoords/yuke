// The turns of a session of the test host: the fake replies, the transcript, and the hooks and the tools of a plugin.

import type { PluginSession } from "yuke:plugins";
import { assert, assertEquals, assertRejects, createHost, folder, reply, test, waitForSettled } from "yuke:test";
import type { Entry } from "yuke:transcript";

/** A plugin whose session defines the tool `greet`, which answers `hello` and its argument. */
const greeter: PluginSession = (s) => {
  s.tools.add({
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
  const replies = [reply.text("Hello.")];
  await using host = await createHost({ plugins: [], replies });
  const session = await host.openSession();

  await session.sendMessage("Hi.");

  assertEquals(
    session.transcript.entries.map((entry) => entry.kind),
    ["input", "text", "end"],
  );
  assertEquals(host.requests.length, 1);
  assertEquals(host.requests[0]?.messages.at(-1)?.text, "Hi.");
});

test("an overloaded answer gets a retry without a wait", async () => {
  const replies = [reply.overloaded(), reply.text("Hello.")];
  await using host = await createHost({ plugins: [], replies });
  const session = await host.openSession();
  const start = Date.now();

  await session.sendMessage("Hi.");

  assertEquals(host.requests.length, 2);
  assert(Date.now() - start < 1000, "the retry waited");
});

test("a cut answer does not run its calls, and the model gets an error result", async () => {
  const replies = [reply.cut([{ name: "greet", args: { who: "Ada" } }]), reply.text("Sorry.")];
  await using host = await createHost({ plugins: [{ name: "greeter", session: greeter }], replies });
  const session = await host.openSession();

  await session.sendMessage("Greet Ada.");

  const call = tool(session.transcript.entries, 1);
  assertEquals(
    [call.name, call.result?.isError, call.result?.content.includes("output token limit")],
    ["greet", true, true],
  );
  assertEquals(host.requests.length, 2);
});

test("an answer that fails after its first text ends the turn without a retry", async () => {
  const replies = [reply.failed("Hal")];
  await using host = await createHost({ plugins: [], replies });
  const session = await host.openSession();

  await session.sendMessage("Hi.");

  const end = session.transcript.entries.at(-1);
  assert(end?.kind === "end" && end.end.kind === "failed", "the turn did not fail");
  assertEquals(host.requests.length, 1);
});

test("an abort of the signal cancels a turn that waits for the replies, and send rejects", async () => {
  const replies = [reply.stall("Hal")];
  await using host = await createHost({ plugins: [], replies });
  const session = await host.openSession();
  const stop = new AbortController();
  const sent = assertRejects(() => session.sendMessage("Hi.", { signal: stop.signal }));
  await waitForSettled();
  assertEquals(host.requests.length, 1);
  stop.abort(new Error("stop"));

  const error = await sent;

  assertEquals(error instanceof Error ? error.message : error, "stop");
  const last = session.transcript.entries.at(-1);
  assertEquals([last?.kind === "end" && last.end], [{ kind: "cancelled" }]);
});

test("send with an aborted signal rejects and sends nothing", async () => {
  await using host = await createHost({ plugins: [] });
  const session = await host.openSession();

  const error = await assertRejects(() =>
    session.sendMessage("Hi.", { signal: AbortSignal.abort(new Error("early")) }),
  );

  assertEquals(error instanceof Error ? error.message : error, "early");
  assertEquals(session.transcript.entries, []);
});

test("a session without settings uses the test model in the folder of the test", async () => {
  const replies = [reply.text("Hello.")];
  await using host = await createHost({ plugins: [], replies });
  const session = await host.openSession();

  await session.sendMessage("Hi.");

  const request = host.requests[0];
  assert(request !== undefined, "no request");
  assertEquals(request.messages, [{ role: "user", text: "Hi." }]);
  assert(request.system.includes(folder()), "the system text names no workspace");
  const body = request.body as Record<string, unknown>;
  assertEquals(body.model, "MiniMax-M3");
});

// Each catalog model gets the fake answers in the stream format of its protocol.
for (const model of [
  { provider: "minimax", model: "MiniMax-M3" },
  { provider: "cerebras", model: "gpt-oss-120b" },
  { provider: "openai", model: "gpt-4.1" },
]) {
  test(`a turn with a tool call runs on ${model.provider}/${model.model}`, async () => {
    const replies = [reply.toolCall("greet", { who: "Ada" }), reply.text("Done.")];
    await using host = await createHost({ plugins: [{ name: "greeter", session: greeter }], replies });
    const session = await host.openSession({ model });

    await session.sendMessage("Greet Ada.");

    assertEquals(
      session.transcript.entries.map((entry) => entry.kind),
      ["input", "tool", "text", "end"],
    );
    const call = tool(session.transcript.entries, 1);
    assertEquals(
      [call.name, call.status, call.result?.content, call.result?.isError],
      ["greet", "done", "hello Ada", false],
    );
    assertEquals(host.requests.length, 2);
    const [first, second] = host.requests;
    assert(first !== undefined && second !== undefined, "the model got no two requests");
    assertEquals(first.messages, [{ role: "user", text: "Greet Ada." }]);
    assertEquals([first.tools.includes("greet"), first.system.includes(folder())], [true, true]);
    assertEquals(second.messages.at(-1)?.text, "hello Ada");
    assertEquals((second.body as { model?: string }).model, model.model);
  });
}
