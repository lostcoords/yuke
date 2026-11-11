// `sideRequest` of a round event: the request of the round, with the context that the handler sees.

import type { PluginSession } from "yuke:plugins";
import type { Block, Settings } from "yuke:protocol";
import { createHost, equal, type ModelRequest, type Reply, rejects, reply, test, waitForSettled } from "yuke:test";

/** The context of the round: an input, an answer, and a second input. */
const context: Block[] = [{ user_text: "one" }, { assistant_text: { text: "two" } }, { user_text: "three" }];

const settings: Settings = {
  maxOutputTokens: null,
  reasoning: { thinking: null, effort: null },
  temperature: 0.5,
  topP: null,
  toolChoice: "auto",
  outputSchema: null,
};

const echo = { name: "echo", description: "Echo the text.", inputSchema: '{"type":"object"}', deferLoading: false };

/**
 * Run the `round.before` hooks of `plugins` for a round of `context`. The fake model answers the side requests with
 * `replies`. Return the requests that it got.
 */
async function round(
  plugins: readonly { name: string; session: PluginSession }[],
  replies: readonly Reply[],
): Promise<readonly ModelRequest[]> {
  await using host = await createHost({ plugins, replies });
  const session = await host.openSession();
  await session.runHook("round.before", {
    blocks: context,
    contextWindow: 1000,
    system: "Be brief.",
    tools: [echo],
    settings,
  });
  return host.requests;
}

/** The only request of `requests`. */
function only(requests: readonly ModelRequest[]): ModelRequest {
  equal(requests.length, 1);
  return requests[0] as ModelRequest;
}

test("a side request repeats the round with the context that the handler sees, then the prompt", async () => {
  let answer: unknown;
  const first: PluginSession = (s) => {
    s.addHook("round.before", () => ({ replace: { head: [{ user_text: "summary" }], keep: 1 } }));
  };
  const second: PluginSession = (s) => {
    s.addHook("round.before", async (event) => {
      const answered = await event.sideRequest({ prompt: "Summarize.", maxOutputTokens: 100 });
      answer = [answered.text, answered.finishReason, answered.usage.input, Object.isFrozen(answered)];
      return undefined;
    });
  };
  const replies = [reply.text("A summary.", { inputTokens: 900 })];

  const requests = await round(
    [
      { name: "first", session: first },
      { name: "second", session: second },
    ],
    replies,
  );

  equal(answer, ["A summary.", "stop", 900, true]);
  const request = only(requests);
  const body = request.body as { temperature: number; max_tokens: number };
  equal([request.system, request.tools, body.temperature, body.max_tokens], ["Be brief.", ["echo"], 0.5, 100]);
  equal(request.messages, [{ role: "user", text: "summary\nthree\nSummarize." }]);
});

test("the blockCount option sends only the oldest blocks of the context", async () => {
  const compact: PluginSession = (s) => {
    s.addHook("round.before", async (event) => {
      await event.sideRequest({ prompt: "Summarize.", blockCount: 2 });
      return undefined;
    });
  };
  const replies = [reply.text("A summary.")];

  const requests = await round([{ name: "compact", session: compact }], replies);

  equal(
    only(requests).messages.map((message) => [message.role, message.text]),
    [
      ["user", "one"],
      ["assistant", "two"],
      ["user", "Summarize."],
    ],
  );
});

test("an abort stops the request and rejects with the reason of the signal", async () => {
  let rejected = "";
  const controller = new AbortController();
  const compact: PluginSession = (s) => {
    s.addHook("round.before", async (event) => {
      const request = event.sideRequest({ prompt: "Summarize.", signal: controller.signal });
      try {
        await request;
      } catch (error) {
        rejected = error instanceof Error ? error.message : String(error);
      }
      return undefined;
    });
  };
  await using host = await createHost({
    plugins: [{ name: "compact", session: compact }],
    replies: [reply.stall("Half")],
  });
  const session = await host.openSession();
  const pending = session.runHook("round.before", {
    blocks: context,
    contextWindow: 1000,
    system: "Be brief.",
    tools: [echo],
    settings,
  });
  await waitForSettled();
  equal(host.requests.length, 1);
  controller.abort(new Error("too slow"));
  await pending;

  equal([rejected, host.requests.length], ["too slow", 1]);
});

test("a failed request rejects with its text", async () => {
  const compact: PluginSession = (s) => {
    s.addHook("round.before", async (event) => {
      await event.sideRequest({ prompt: "Summarize." });
      return undefined;
    });
  };
  const replies = [reply.failed("Half")];

  const error = await rejects(round([{ name: "compact", session: compact }], replies));

  const message = error instanceof Error ? error.message : String(error);
  equal(message.startsWith("round.before of plugin compact failed: Error: "), true);
  equal(message.includes("overloaded"), true);
});
