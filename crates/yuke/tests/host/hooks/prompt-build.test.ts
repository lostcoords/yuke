// The `prompt.build` hook: its order, its answers, and its failures.

import type { PluginSession, SessionHooks } from "yuke:plugins";
import { assertEquals, assertRejects, createHost, reply, test, waitForSettled } from "yuke:test";

/** The sections of a new session before any hook. */
const saved = { base: "You are yuke.", environment: "workspace: /work" };

/** The sections that the `prompt.build` hooks of `plugins` build from `saved`, as pairs in order. */
async function build(plugins: readonly { name: string; session: PluginSession }[]): Promise<[string, string][]> {
  await using host = await createHost({ plugins });
  const session = await host.openSession();
  return Object.entries((await session.runHook("prompt.build", { sections: saved })).sections);
}

/** A plugin whose `prompt.build` handler runs `body`. */
const answering =
  (body: SessionHooks["prompt.build"]): PluginSession =>
  (s) => {
    s.addHook("prompt.build", body);
  };

test("a session without a hook keeps its sections", async () => {
  assertEquals(await build([{ name: "plain", session: () => undefined }]), Object.entries(saved));
});

// An answer replaces the sections, and `undefined` keeps them.
test("the handlers run in plugin order, then in addition order, and each gets the answer before it", async () => {
  const first: PluginSession = (s) => {
    s.addHook("prompt.build", (event) => ({ sections: { ...event.sections, rules: "one" } }));
    s.addHook("prompt.build", async (event) => {
      await null;
      return { sections: { ...event.sections, base: "Be brief.", rules: `${event.sections.rules} two` } };
    });
    s.addHook("prompt.build", () => undefined);
  };
  const second: PluginSession = (s) => {
    s.addHook("prompt.build", (event) => {
      const { environment: _environment, ...rest } = event.sections;
      return { sections: { ...rest, seen: event.sections.rules ?? "" } };
    });
  };

  assertEquals(
    await build([
      { name: "first", session: first },
      { name: "second", session: second },
    ]),
    [
      ["base", "Be brief."],
      ["rules", "one two"],
      ["seen", "one two"],
    ],
  );
});

test("the order of the sections reaches the system prompt of a request", async () => {
  // The prompt joins the sections in order, so a section put first comes before the base of yuke.
  const order = answering((event) => ({ sections: { first: "FIRST SECTION", ...event.sections } }));
  const replies = [reply.text("Done.")];
  await using host = await createHost({ plugins: [{ name: "order", session: order }], replies });
  const session = await host.openSession();

  await session.sendMessage("Hi.");

  const system = host.requests[0]?.system ?? "";
  assertEquals(system.startsWith("<first>\nFIRST SECTION\n</first>\n\nYou are yuke"), true);
});

// The answers of a build stay in that build, so each build starts from the sections of the caller.
test("each build starts from the sections of the caller", async () => {
  let count = 0;
  const counter = answering((event) => {
    count += 1;
    return { sections: { ...event.sections, base: `${event.sections.base} ${count}` } };
  });
  await using host = await createHost({ plugins: [{ name: "count", session: counter }] });
  const session = await host.openSession();

  await session.runHook("prompt.build", { sections: saved });
  const second = await session.runHook("prompt.build", { sections: saved });

  assertEquals(second.sections.base, "You are yuke. 2");
});

test("the first build waits for the setup of the session", async () => {
  const setup = Promise.withResolvers<void>();
  const late: PluginSession = async (s) => {
    await setup.promise;
    s.addHook("prompt.build", (event) => ({ sections: { ...event.sections, late: "here" } }));
  };

  await using host = await createHost({ plugins: [{ name: "late", session: late }] });
  const session = await host.openSession();
  let built = false;
  const pending = session.runHook("prompt.build", { sections: saved }).then((result) => {
    built = true;
    return result;
  });
  await waitForSettled();
  assertEquals(built, false);
  setup.resolve();

  assertEquals(Object.entries((await pending).sections).at(-1), ["late", "here"]);
});

test("a handler that throws fails the build, and the error names the plugin", async () => {
  const broken = answering(() => {
    throw new RangeError("no prompt today");
  });

  const error = await assertRejects(() => build([{ name: "broken", session: broken }]));

  assertEquals(
    [error instanceof Error && error.name, error instanceof Error && error.message],
    ["Error", "prompt.build of plugin broken failed: RangeError: no prompt today"],
  );
});

// The host stops its wait at a cancel, so a handler that rejects later sends no fault. A fault would fail this test.
test("a build that fails after a cancel sends no fault", async () => {
  const handler = Promise.withResolvers<undefined>();
  const late = answering(() => handler.promise);
  await using host = await createHost({ plugins: [{ name: "late", session: late }] });
  const session = await host.openSession();
  const stop = new AbortController();
  const built = session.runHook("prompt.build", { sections: saved }, { signal: stop.signal });
  await waitForSettled();
  stop.abort(new Error("stop"));

  await assertRejects(() => built);
  handler.reject(new Error("stopped"));
  await waitForSettled();
});

// A handler can be in a list twice, so a remover removes one entry, and a second call of it removes nothing.
test("a remover removes one entry once, and the handler of a failed session does not run", async () => {
  const removed: PluginSession = (s) => {
    const count = (event: { sections: Readonly<Record<string, string>> }) => ({
      sections: { ...event.sections, count: `${Number(event.sections.count ?? 0) + 1}` },
    });
    s.addHook("prompt.build", count);
    const remove = s.addHook("prompt.build", count);
    remove();
    remove();
  };
  const failed: PluginSession = async (s) => {
    s.addHook("prompt.build", (event) => ({ sections: { ...event.sections, failed: "x" } }));
    await null;
    throw new Error("broken");
  };

  assertEquals(
    await build([
      { name: "removed", session: removed },
      { name: "failed", session: failed },
    ]),
    [...Object.entries(saved), ["count", "1"]],
  );
});

test("a closed session refuses a new hook", async () => {
  let kept: Parameters<PluginSession>[0] | undefined;
  const refused: PluginSession = (s) => {
    kept = s;
  };
  await using host = await createHost({ plugins: [{ name: "refused", session: refused }] });
  const session = await host.openSession();

  await session.close();
  let refusal = "";
  try {
    kept?.addHook("prompt.build", () => undefined);
  } catch (error) {
    refusal = error instanceof Error ? error.message : String(error);
  }

  assertEquals(refusal, "plugin refused adds a hook after the end of its session");
});
