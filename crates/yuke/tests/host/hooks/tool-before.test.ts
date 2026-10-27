// The `tool.before` hook: its order, its event, its answers, and its failures.

import type { PluginSession } from "yuke:plugins";
import { createHost, equal, test } from "yuke:test";

const call = { id: "c1", name: "read", arguments: { path: ["src", "main.rs"] } };

/** A plugin whose `tool.before` handler runs `body` and gives its answer. */
const answering =
  (body: () => unknown): PluginSession =>
  (s) => {
    s.hook("tool.before", body as () => undefined);
  };

// The first block ends the chain, so a later handler never sees the call.
test("the first block in plugin order, then in addition order, stops the call", async () => {
  const seen: string[] = [];
  const first: PluginSession = (s) => {
    s.hook("tool.before", () => {
      seen.push("first one");
      return undefined;
    });
    s.hook("tool.before", () => {
      seen.push("first two");
      return { block: "first says no" };
    });
  };
  const second: PluginSession = (s) => {
    s.hook("tool.before", () => {
      seen.push("second");
      return { block: "second says no" };
    });
  };
  await using host = await createHost({
    plugins: [
      { name: "first", session: first },
      { name: "second", session: second },
    ],
  });
  const session = await host.openSession();

  equal(await session.run("tool.before", { call }), { block: "first says no" });
  equal(seen, ["first one", "first two"]);
});

test("the decision is run when no handler blocks the call", async () => {
  await using host = await createHost({ plugins: [{ name: "quiet", session: answering(() => undefined) }] });
  const session = await host.openSession();

  equal(await session.run("tool.before", { call }), "run");
});

test("a handler gets the id, the name, and the parsed arguments of the call", async () => {
  const reader: PluginSession = (s) => {
    s.hook("tool.before", (event) => {
      const path = (event.call.arguments as { path: string[] }).path;
      return { block: `${event.call.id} ${event.call.name} ${path.join("/")}` };
    });
  };
  await using host = await createHost({ plugins: [{ name: "reader", session: reader }] });
  const session = await host.openSession();

  equal(await session.run("tool.before", { call }), { block: "c1 read src/main.rs" });
});

// The call runs as the model gave it, so a change of the event or the call fails at once and stops the call.
type Change = (event: { call: { name: string; arguments: unknown } }) => void;
const changes: [string, Change][] = [
  [
    "a nested argument",
    (event) => {
      (event.call.arguments as { options: { force: boolean } }).options.force = true;
    },
  ],
  [
    "the name",
    (event) => {
      event.call.name = "write";
    },
  ],
  [
    "the call",
    (event) => {
      (event as { call: unknown }).call = {};
    },
  ],
];
for (const [name, change] of changes) {
  test(`a change of ${name} throws and stops the call`, async () => {
    const editor: PluginSession = (s) => {
      s.hook("tool.before", (event) => {
        change(event);
        return undefined;
      });
    };
    await using host = await createHost({ plugins: [{ name: "editor", session: editor }] });
    const session = await host.openSession();

    const decision = await session.run("tool.before", {
      call: { id: "c1", name: "write", arguments: { options: { force: false } } },
    });

    const reason = typeof decision === "object" ? decision.block : "";
    equal(reason.startsWith("tool.before of plugin editor failed: TypeError: "), true);
  });
}

for (const [name, body, error] of [
  [
    "a throw",
    () => {
      throw new Error("no check today");
    },
    "Error: no check today",
  ],
  ["a block that is no text", () => ({ block: 1 }), "TypeError: the block of the answer is not a string"],
  ["an unknown field", () => ({ block: "no", why: "x" }), "TypeError: the answer has the unknown field 'why'"],
  ["an empty answer", () => ({}), "TypeError: the block of the answer is not a string"],
  ["a text", () => "no", "TypeError: the answer is not an object"],
  ["null", () => null, "TypeError: the answer is not an object"],
] as const) {
  test(`${name} stops the call and names the plugin`, async () => {
    await using host = await createHost({ plugins: [{ name: "check", session: answering(body) }] });
    const session = await host.openSession();

    equal(await session.run("tool.before", { call }), { block: `tool.before of plugin check failed: ${error}` });
  });
}

test("a removed handler and the handler of a failed session block nothing", async () => {
  const removed: PluginSession = (s) => {
    s.hook("tool.before", () => ({ block: "removed" }))();
  };
  const failed: PluginSession = async (s) => {
    s.hook("tool.before", () => ({ block: "failed" }));
    await null;
    throw new Error("broken");
  };
  await using host = await createHost({
    plugins: [
      { name: "removed", session: removed },
      { name: "failed", session: failed },
    ],
  });
  const session = await host.openSession();

  equal(await session.run("tool.before", { call }), "run");
});
