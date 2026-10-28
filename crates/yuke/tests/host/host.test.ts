// The test host itself: its plugins, its records, its calls, and its lifetime.

import { mkdir } from "yuke:fs";
import type { PluginApply, PluginSession } from "yuke:plugins";
import { assert, createHost, equal, folder, rejects, reply, test } from "yuke:test";

const echo: PluginSession = (s) => {
  s.tools.define({
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

  equal(result, { text: "hi", isError: false, media: [], output: ["one", "two"] });
});

test("the notices and the events of a plugin are in the records after the operation", async () => {
  const loud: PluginSession = (s) => {
    s.hook("tool.before", () => {
      s.notify("warn", "careful");
      s.emit("seen", { n: 1 });
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "loud", session: loud }] });
  const session = await host.openSession();

  await session.run("tool.before", { call: { callId: "c", name: "x", arguments: {} } });

  equal(
    host.notices.map((notice) => [notice.source, notice.level, notice.message]),
    [["loud", "warn", "careful"]],
  );
  equal(
    host.events.map((event) => [event.extension, event.event, event.data]),
    [["loud", "seen", { n: 1 }]],
  );
});

test("a plugin that does not load rejects the host with its reason", async () => {
  const failing: PluginApply = () => {
    throw new Error("no start");
  };

  const error = await rejects(createHost({ plugins: [{ name: "failing", apply: failing }] }));

  equal(error instanceof Error && error.message.includes("plugin failing did not load"), true);
});

test("a second host in one test throws, also after the close of the first", async () => {
  const host = await createHost({ plugins: [] });
  await host.close();

  const error = await rejects(createHost({ plugins: [] }));

  equal(error instanceof Error ? error.message : error, "a test creates one host");
});

test("the close runs the cleanups once, and a second close gives the same promise", async () => {
  const cleaned: string[] = [];
  const tidy: PluginApply = () => () => {
    cleaned.push("apply");
  };
  const host = await createHost({ plugins: [{ name: "tidy", apply: tidy }] });

  const first = host.close();
  const second = host.close();
  await first;

  equal([first === second, cleaned], [true, ["apply"]]);
});

test("a reply that the model used passes the close", async () => {
  const replies = [reply.text("Hello.")];
  const host = await createHost({ plugins: [], replies });
  const session = await host.openSession();
  await session.send("Hi.");

  await host.close();

  equal(host.requests.length, 1);
});

test("a plugin folder must be absolute", async () => {
  const error = await rejects(createHost({ plugins: [{ folder: "plugins/echo" }] }));

  equal(error instanceof Error ? error.message : error, "plugin folder plugins/echo: the folder is not absolute");
});

test("a given plugin name follows the rule of a manifest name", async () => {
  const error = await rejects(createHost({ plugins: [{ name: "../outside" }] }));

  equal(error instanceof Error && error.message.startsWith("plugin ../outside: name: '../outside' must be"), true);
});

test("await using closes the host at the end of its block", async () => {
  const cleaned: string[] = [];
  {
    await using _host = await createHost({ plugins: [{ name: "tidy", apply: () => () => void cleaned.push("tidy") }] });
  }

  equal(cleaned, ["tidy"]);
});

test("each call gets its own call id", async () => {
  const ids: PluginSession = (s) => {
    s.tools.define({
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
  const waits = (signal: AbortSignal, name: string): Promise<string> =>
    new Promise((resolve) => {
      signal.addEventListener("abort", () => {
        seen.push(name);
        resolve("");
      });
    });
  const waiter: PluginSession = (s) => {
    s.tools.define({
      name: "wait",
      description: "Wait for the cancel.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: (_args, context) => waits(context.signal, "tool"),
    });
    s.hook("tool.before", async (event) => {
      await waits(event.signal, "hook");
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "waiter", session: waiter }] });
  const session = await host.openSession();
  const abortSoon = (): AbortSignal => {
    const stop = new AbortController();
    setTimeout(() => stop.abort(new Error("stop")), 20);
    return stop.signal;
  };

  const called = await rejects(session.call("wait", {}, { signal: abortSoon() }));
  const ran = await rejects(
    session.run("tool.before", { call: { callId: "c", name: "wait", arguments: {} } }, { signal: abortSoon() }),
  );

  equal(
    [called, ran].map((error) => (error instanceof Error ? error.message : error)),
    ["stop", "stop"],
  );
  equal(seen, ["tool", "hook"]);
});

test("setSettings changes the folder and the model of an open session", async () => {
  const where: PluginSession = (s) => {
    s.tools.define({
      name: "where",
      description: "Give the folder.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: (_args, context) => context.folder,
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
  await session.send("Hi.");

  equal((await session.call("where", {})).text, `${folder()}/other`);
  equal(
    host.requests.map((request) => (request.body as { model: string }).model),
    ["gpt-4.1"],
  );
});

test("close stops the background jobs of the session", async () => {
  await using host = await createHost({ plugins: [] });
  const session = await host.openSession();
  const started = await session.call("exec", { command: "sleep 30", background: true });
  assert(!started.isError, started.text);

  await session.close();

  equal(host.notices, []);
});

test("a setSettings that fails during a turn changes nothing", async () => {
  const replies = [reply.stall(), reply.text("Done.")];
  await using host = await createHost({ plugins: [], replies });
  const session = await host.openSession();
  const stop = new AbortController();
  const sending = rejects(session.send("Wait.", { signal: stop.signal }));
  while (host.requests.length === 0) await new Promise((resolve) => setTimeout(resolve, 5));

  await rejects(session.setSettings({ ...session.settings, model: { provider: "openai", model: "gpt-4.1" } }));
  stop.abort(new Error("stop"));
  await sending;
  await session.setSettings({ ...session.settings, cwd: folder() });
  await session.send("Hi.");

  equal(
    host.requests.map((request) => (request.body as { model: string }).model),
    ["MiniMax-M3", "MiniMax-M3"],
  );
});
