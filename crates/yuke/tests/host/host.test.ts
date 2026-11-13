// The test host itself: its plugins, its records, its calls, and its lifetime.

import { mkdir } from "yuke:fs";
import type { PluginApply, PluginSession } from "yuke:plugins";
import { assert, assertEquals, assertRejects, createHost, folder, reply, test, waitForSettled } from "yuke:test";

const echo: PluginSession = (s) => {
  s.tools.add({
    name: "echo",
    description: "Echo the text.",
    concurrency: "serial",
    parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
    execute: (args, context) => {
      context.output("one");
      context.output("two");
      return args.text;
    },
  });
};

test("call runs a tool and gives its live texts in order", async () => {
  await using host = await createHost({ plugins: [{ name: "echo", session: echo }] });
  const session = await host.openSession();

  const result = await session.call("echo", { text: "hi" });

  assertEquals(result, { text: "hi", isError: false, media: [], display: [], output: ["one", "two"] });
});

test("the notices and the events of a plugin are in the records after the operation", async () => {
  const loud: PluginSession = (s) => {
    s.addHook("tool.before", () => {
      s.notify("warn", "careful");
      s.sendClientEvent("seen", { n: 1 });
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "loud", session: loud }] });
  const session = await host.openSession();

  await session.runHook("tool.before", { call: { callId: "c", name: "x", arguments: {} } });

  assertEquals(
    host.notices.map((notice) => [notice.source, notice.level, notice.text]),
    [["loud", "warn", "careful"]],
  );
  assertEquals(
    host.events.map((event) => [event.extension, event.event, event.data]),
    [["loud", "seen", { n: 1 }]],
  );
});

test("a plugin that does not load rejects the host with its reason", async () => {
  const failing: PluginApply = () => {
    throw new Error("no start");
  };

  const error = await assertRejects(() => createHost({ plugins: [{ name: "failing", apply: failing }] }));

  assertEquals(error instanceof Error && error.message.includes("plugin failing did not load"), true);
});

test("a plugin folder must be absolute", async () => {
  const error = await assertRejects(() => createHost({ plugins: [{ folder: "plugins/echo" }] }));

  assertEquals(
    error instanceof Error ? error.message : error,
    "plugin folder plugins/echo: the folder is not absolute",
  );
});

test("a given plugin name follows the rule of a manifest name", async () => {
  const error = await assertRejects(() => createHost({ plugins: [{ name: "../outside" }] }));

  assertEquals(
    error instanceof Error && error.message.startsWith("plugin ../outside: name: '../outside' must be"),
    true,
  );
});

test("each call gets its own call id", async () => {
  const ids: PluginSession = (s) => {
    s.tools.add({
      name: "id",
      description: "Give the call id.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: (_args, context) => context.callId,
    });
  };
  await using host = await createHost({ plugins: [{ name: "ids", session: ids }] });
  const session = await host.openSession();

  const first = await session.call("id", {});
  const second = await session.call("id", {});

  assert(first.text !== second.text, `both calls got ${first.text}`);
});

test("an abort of the signal cancels a call and a hook point, and each rejects with the reason", async () => {
  const seen: string[] = [];
  const waits = (signal: AbortSignal, name: "tool" | "hook"): Promise<string> =>
    new Promise((resolve) => {
      signal.addEventListener("abort", () => {
        seen.push(name);
        resolve("");
      });
    });
  const waiter: PluginSession = (s) => {
    s.tools.add({
      name: "wait",
      description: "Wait for the cancel.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: (_args, context) => waits(context.signal, "tool"),
    });
    s.addHook("tool.before", async (event) => {
      await waits(event.signal, "hook");
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "waiter", session: waiter }] });
  const session = await host.openSession();
  const callStop = new AbortController();
  const called = assertRejects(() => session.call("wait", {}, { signal: callStop.signal }));
  await waitForSettled();
  callStop.abort(new Error("stop"));
  const callError = await called;
  const hookStop = new AbortController();
  const ran = assertRejects(() =>
    session.runHook("tool.before", { call: { callId: "c", name: "wait", arguments: {} } }, { signal: hookStop.signal }),
  );
  await waitForSettled();
  hookStop.abort(new Error("stop"));

  assertEquals(
    [callError, await ran].map((error) => (error instanceof Error ? error.message : error)),
    ["stop", "stop"],
  );
  assertEquals(seen, ["tool", "hook"]);
});

test("setSettings changes the folder and the model of an open session", async () => {
  const where: PluginSession = (s) => {
    s.tools.add({
      name: "where",
      description: "Give the folder.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: (_args, context) => context.cwd,
    });
  };
  const replies = [reply.text("Done.")];
  await using host = await createHost({ plugins: [{ name: "where", session: where }], replies });
  const session = await host.openSession();
  await mkdir(`${folder()}/other`);

  await session.setSettings({
    ...session.settings,
    cwd: `${folder()}/other`,
    model: { provider: "openai", model: "gpt-4.1" },
  });
  await session.sendMessage("Hi.");

  assertEquals((await session.call("where", {})).text, `${folder()}/other`);
  assertEquals(
    host.requests.map((request) => (request.body as { model: string }).model),
    ["gpt-4.1"],
  );
});

test("a setSettings that fails during a turn changes nothing", async () => {
  const replies = [reply.stall(), reply.text("Done.")];
  await using host = await createHost({ plugins: [], replies });
  const session = await host.openSession();
  const stop = new AbortController();
  const sending = assertRejects(() => session.sendMessage("Wait.", { signal: stop.signal }));
  await waitForSettled();
  assertEquals(host.requests.length, 1);

  await assertRejects(() =>
    session.setSettings({ ...session.settings, model: { provider: "openai", model: "gpt-4.1" } }),
  );
  stop.abort(new Error("stop"));
  await sending;
  await session.setSettings({ ...session.settings, cwd: folder() });
  await session.sendMessage("Hi.");

  assertEquals(
    host.requests.map((request) => (request.body as { model: string }).model),
    ["MiniMax-M3", "MiniMax-M3"],
  );
});
