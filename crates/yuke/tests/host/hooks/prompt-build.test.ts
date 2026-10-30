// The `prompt.build` hook: its order, its answers, and its failures.

import type { PluginSession, SessionHooks } from "yuke:plugins";
import { createHost, equal, rejects, reply, test } from "yuke:test";
import { waitFor } from "../wait.ts";

/** The sections of a new session before any hook. */
const saved = { base: "You are yuke.", environment: "workspace: /work" };

/** The sections that the `prompt.build` hooks of `plugins` build from `saved`, as pairs in order. */
async function build(plugins: readonly { name: string; session: PluginSession }[]): Promise<[string, string][]> {
  await using host = await createHost({ plugins });
  const session = await host.openSession();
  return Object.entries((await session.run("prompt.build", { sections: saved })).sections);
}

/** The message of the failure of a build with `plugins`. */
async function failure(plugins: readonly { name: string; session: PluginSession }[]): Promise<string> {
  const error = await rejects(build(plugins));
  return error instanceof Error ? error.message : String(error);
}

/** A plugin whose `prompt.build` handler runs `body`. */
const answering =
  (body: SessionHooks["prompt.build"]): PluginSession =>
  (s) => {
    s.hook("prompt.build", body);
  };

test("a session without a hook keeps its sections", async () => {
  equal(await build([{ name: "plain", session: () => undefined }]), Object.entries(saved));
});

// An answer replaces the sections, and `undefined` keeps them.
test("the handlers run in plugin order, then in addition order, and each gets the answer before it", async () => {
  const first: PluginSession = (s) => {
    s.hook("prompt.build", (event) => ({ sections: { ...event.sections, rules: "one" } }));
    s.hook("prompt.build", async (event) => {
      await null;
      return { sections: { ...event.sections, base: "Be brief.", rules: `${event.sections.rules} two` } };
    });
    s.hook("prompt.build", () => undefined);
  };
  const second: PluginSession = (s) => {
    s.hook("prompt.build", (event) => {
      const { environment: _environment, ...rest } = event.sections;
      return { sections: { ...rest, seen: event.sections.rules ?? "" } };
    });
  };

  equal(
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

  await session.send("Hi.");

  const system = host.requests[0]?.system ?? "";
  equal(system.startsWith("<first>\nFIRST SECTION\n</first>\n\nYou are yuke"), true);
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

  await session.run("prompt.build", { sections: saved });
  const second = await session.run("prompt.build", { sections: saved });

  equal(second.sections.base, "You are yuke. 2");
});

test("the first build waits for the setup of the session", async () => {
  const late: PluginSession = async (s) => {
    await new Promise((resolve) => setTimeout(resolve, 20));
    s.hook("prompt.build", (event) => ({ sections: { ...event.sections, late: "here" } }));
  };

  equal((await build([{ name: "late", session: late }])).at(-1), ["late", "here"]);
});

test("a handler that throws fails the build, and the error names the plugin", async () => {
  const broken = answering(() => {
    throw new RangeError("no prompt today");
  });

  const error = await rejects(build([{ name: "broken", session: broken }]));

  equal(
    [error instanceof Error && error.name, error instanceof Error && error.message],
    ["Error", "prompt.build of plugin broken failed: RangeError: no prompt today"],
  );
  // The stack is the stack of the handler, which names the module of the plugin.
  equal(error instanceof Error && error.stack?.includes("prompt-build.test.ts"), true);
});

// A getter is code of the plugin, so its throw names the plugin as a handler throw does.
test("a getter that throws in the answer fails the build, and the error names the plugin", async () => {
  const getter = answering(() => ({
    sections: {
      get bad(): string {
        throw new Error("late");
      },
    },
  }));

  equal(await failure([{ name: "getter", session: getter }]), "prompt.build of plugin getter failed: Error: late");
});

// The host stops its wait at a cancel, so a handler that rejects later sends no fault. A fault would fail this test.
test("a build that fails after a cancel sends no fault", async () => {
  let rejected = false;
  const started = Promise.withResolvers<void>();
  const late: PluginSession = (s) => {
    s.hook(
      "prompt.build",
      (event) =>
        new Promise((_resolve, reject) => {
          event.signal.addEventListener("abort", () =>
            setTimeout(() => {
              rejected = true;
              reject(new Error("stopped"));
            }, 0),
          );
          started.resolve();
        }),
    );
  };
  await using host = await createHost({ plugins: [{ name: "late", session: late }] });
  const session = await host.openSession();
  const stop = new AbortController();
  const built = session.run("prompt.build", { sections: saved }, { signal: stop.signal });
  // The cancel comes after the handler listens for it.
  await started.promise;
  stop.abort(new Error("stop"));

  await rejects(built);
  await waitFor(() => rejected);
});

// A handler can be in a list twice, so a remover removes one entry, and a second call of it removes nothing.
test("a remover removes one entry once, and the handler of a failed session does not run", async () => {
  const removed: PluginSession = (s) => {
    const count = (event: { sections: Readonly<Record<string, string>> }) => ({
      sections: { ...event.sections, count: `${Number(event.sections.count ?? 0) + 1}` },
    });
    s.hook("prompt.build", count);
    const remove = s.hook("prompt.build", count);
    remove();
    remove();
  };
  const failed: PluginSession = async (s) => {
    s.hook("prompt.build", (event) => ({ sections: { ...event.sections, failed: "x" } }));
    await null;
    throw new Error("broken");
  };

  equal(
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
    kept?.hook("prompt.build", () => undefined);
  } catch (error) {
    refusal = error instanceof Error ? error.message : String(error);
  }

  equal(refusal, "plugin refused adds a hook after the end of its session");
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
