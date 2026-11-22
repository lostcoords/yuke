// The test host itself: its plugins, its records, its calls, and its lifetime.

import { mkdir, readTextFile, writeTextFile } from "yuke:fs";
import type { PluginApply, PluginSession } from "yuke:plugins";
import {
  assert,
  assertEquals,
  assertRejects,
  createFrame,
  createHost,
  folder,
  reply,
  test,
  waitForSettled,
} from "yuke:test";
import type { Notice, Tui } from "yuke:tui";

const echo: PluginSession = (s) => {
  s.tools.add({
    name: "echo",
    description: "Echo the text.",
    concurrency: "serial",
    inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
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

  assertEquals(error instanceof Error && error.message.includes("Plugin failing did not load"), true);
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
      inputSchema: { type: "object", properties: {} },
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
      inputSchema: { type: "object", properties: {} },
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
      inputSchema: { type: "object", properties: {} },
      execute: (_args, context) => context.folder,
    });
  };
  const replies = [reply.text("Done.")];
  await using host = await createHost({ plugins: [{ name: "where", session: where }], replies });
  const session = await host.openSession();
  await mkdir(`${folder()}/other`);

  await session.setSettings({
    ...session.settings,
    folder: `${folder()}/other`,
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
  await session.setSettings({ ...session.settings, folder: folder() });
  await session.sendMessage("Hi.");

  assertEquals(
    host.requests.map((request) => (request.body as { model: string }).model),
    ["MiniMax-M3", "MiniMax-M3"],
  );
});

test("with a frame, a plugin draws on it, and the close of the host removes what the plugin drew", async () => {
  using frame = createFrame({ width: 20, height: 2 });
  const host = await createHost({
    frame,
    plugins: [
      {
        name: "painter",
        apply: (ctx) => {
          ctx.get("tui")?.overlay(() => ({ draw: (canvas) => canvas.text(0, 0, "painted") }), { modal: false });
          return undefined;
        },
      },
    ],
  });
  const drawn = frame.rows();
  await host.close();

  assertEquals(
    [drawn, frame.rows()],
    [
      ["painted", ""],
      ["", ""],
    ],
  );
});

test("without a frame, a plugin gets no terminal", async () => {
  let tui: Tui | undefined | null = null;
  await using _host = await createHost({
    plugins: [
      {
        name: "looker",
        apply: (ctx) => {
          tui = ctx.get("tui");
          return undefined;
        },
      },
    ],
  });

  assertEquals(tui, undefined);
});

test("with a frame, the terminal gets each notice of the host", async () => {
  let notices: (() => readonly Notice[]) | undefined;
  using frame = createFrame({ width: 20, height: 2 });
  await using _host = await createHost({
    frame,
    plugins: [
      {
        name: "reader",
        apply: (ctx) => {
          const tui = ctx.get("tui");
          notices = () => tui?.notices.list() ?? [];
          ctx.notify("warn", "Disk full");
          return undefined;
        },
      },
    ],
  });

  assertEquals(
    notices?.().map((notice) => [notice.source, notice.level, notice.text]),
    [["reader", "warn", "Disk full"]],
  );
});

test("a bundled plugin loads by its name with its options", async () => {
  using frame = createFrame({ width: 30, height: 3 });
  await using _host = await createHost({
    frame,
    plugins: [
      { bundled: "bar", options: { hide: ["status:secret"] } },
      {
        name: "status",
        apply: (ctx) => {
          ctx.get("tui")?.status.set("mode", { text: "NORMAL", side: "left", order: 0 });
          ctx.get("tui")?.status.set("secret", { text: "HIDDEN", side: "left", order: 1 });
          return undefined;
        },
      },
    ],
  });

  assertEquals(frame.rows().at(-1), "NORMAL");
});

test("a bundled name that yuke does not have rejects the host with the bundled names", async () => {
  const error = await assertRejects(() => createHost({ plugins: [{ bundled: "nope" }] }));

  assert(error instanceof Error);
  assert(error.message.includes("'nope' is not a bundled plugin: the bundled plugins are"), error.message);
});

test("a plugin with a dataDir reads the files that the test saved there before the load", async () => {
  const dataDir = `${folder()}/saved`;
  await mkdir(dataDir);
  await writeTextFile(`${dataDir}/state.txt`, "kept");
  let read: string | undefined;
  await using _host = await createHost({
    plugins: [
      {
        name: "keeper",
        dataDir,
        apply: async (ctx) => {
          read = await readTextFile(`${ctx.dataDir}/state.txt`);
          return undefined;
        },
      },
    ],
  });

  assertEquals(read, "kept");
});
