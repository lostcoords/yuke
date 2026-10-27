// `sideRequest` of a round event: the request of the round, with the context that the handler sees.

import type { PluginSession } from "yuke:plugins";
import type { Block, Settings } from "yuke:protocol";
import { createFakeModel, createHost, equal, type FakeModel, type ModelRequest, rejects, reply, test } from "yuke:test";

/** The context of the round: an input, an answer, and a second input. */
const context: Block[] = [{ user_text: "one" }, { assistant_text: "two" }, { user_text: "three" }];

const settings: Settings = {
  maxOutputTokens: null,
  reasoning: { thinking: null, effort: null },
  temperature: 0.5,
  topP: null,
  toolChoice: "auto",
  outputSchema: null,
};

const echo = { name: "echo", description: "Echo the text.", inputSchema: '{"type":"object"}', deferLoading: false };

/** Run the `round.before` hooks of `plugins` for a round of `context`. `model` answers the side requests. */
async function round(plugins: readonly { name: string; session: PluginSession }[], model: FakeModel): Promise<void> {
  await using host = await createHost({ plugins, model });
  const session = await host.openSession();
  await session.run("round.before", { context, window: 1000, system: "Be brief.", tools: [echo], settings });
}

/** The only request of `model`. */
function only(model: FakeModel): ModelRequest {
  equal(model.requests.length, 1);
  return model.requests[0] as ModelRequest;
}

test("a side request repeats the round with the context that the handler sees, then the prompt", async () => {
  let answer: unknown;
  const first: PluginSession = (s) => {
    s.hook("round.before", () => ({ replace: { head: [{ user_text: "summary" }], keep: 1 } }));
  };
  const second: PluginSession = (s) => {
    s.hook("round.before", async (event) => {
      const answered = await event.sideRequest({ prompt: "Summarize.", maxOutputTokens: 100 });
      answer = [JSON.stringify(answered), Object.isFrozen(answered)];
      return undefined;
    });
  };
  const model = createFakeModel([reply.text("A summary.", { inputTokens: 900 })]);

  await round(
    [
      { name: "first", session: first },
      { name: "second", session: second },
    ],
    model,
  );

  equal(answer, [
    '{"text":"A summary.","finishReason":"stop","usage":{"input":900,"output":1,"reasoning":null,"cacheRead":null,"cacheWrite":null}}',
    true,
  ]);
  const request = only(model);
  const body = request.body as { temperature: number; max_tokens: number };
  equal([request.system, request.tools, body.temperature, body.max_tokens], ["Be brief.", ["echo"], 0.5, 100]);
  equal(request.messages, [{ role: "user", text: "summary\nthree\nSummarize." }]);
});

test("the blocks option sends only the oldest blocks of the context", async () => {
  const compact: PluginSession = (s) => {
    s.hook("round.before", async (event) => {
      await event.sideRequest({ prompt: "Summarize.", blocks: 2 });
      return undefined;
    });
  };
  const model = createFakeModel([reply.text("A summary.")]);

  await round([{ name: "compact", session: compact }], model);

  equal(
    only(model).messages.map((message) => [message.role, message.text]),
    [
      ["user", "one"],
      ["assistant", "two"],
      ["user", "Summarize."],
    ],
  );
});

test("bad options throw a type error and send nothing", async () => {
  const errors: string[] = [];
  const compact: PluginSession = (s) => {
    s.hook("round.before", async (event) => {
      for (const options of [
        {},
        { prompt: "x", blocks: 4 },
        { prompt: "x", blocks: 1.5 },
        { prompt: "x", maxOutputTokens: 0 },
        { prompt: "x", model: "other" },
      ]) {
        try {
          await event.sideRequest(options as never);
        } catch (error) {
          errors.push(error instanceof Error ? `${error.name}: ${error.message}` : String(error));
        }
      }
      return undefined;
    });
  };
  const model = createFakeModel([]);

  await round([{ name: "compact", session: compact }], model);

  equal(
    errors.map((error) => error.startsWith("TypeError: ")),
    [true, true, true, true, true],
  );
  equal(errors[1]?.endsWith("the option blocks is not a whole number from 0 to 3"), true);
  equal(model.requests.length, 0);
});

test("an abort stops the request and rejects with the reason of the signal", async () => {
  let rejected = "";
  const compact: PluginSession = (s) => {
    s.hook("round.before", async (event) => {
      const controller = new AbortController();
      const request = event.sideRequest({ prompt: "Summarize.", abortSignal: controller.signal });
      setTimeout(() => controller.abort(new Error("too slow")), 10);
      try {
        await request;
      } catch (error) {
        rejected = error instanceof Error ? error.message : String(error);
      }
      return undefined;
    });
  };
  const model = createFakeModel([reply.stall("Half")]);

  await round([{ name: "compact", session: compact }], model);

  equal([rejected, model.requests.length], ["too slow", 1]);
});

test("a failed request rejects with its text", async () => {
  const compact: PluginSession = (s) => {
    s.hook("round.before", async (event) => {
      await event.sideRequest({ prompt: "Summarize." });
      return undefined;
    });
  };
  const model = createFakeModel([reply.failed("Half")]);

  const error = await rejects(round([{ name: "compact", session: compact }], model));

  const message = error instanceof Error ? error.message : String(error);
  equal(message.startsWith("round.before of plugin compact failed: Error: "), true);
  equal(message.includes("overloaded"), true);
});
