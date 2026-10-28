// The session of a plugin: its setup, its tools, its failure, and its close.

import { mkdir } from "yuke:fs";
import type { PluginSession, SessionContext } from "yuke:plugins";
import { createHost, equal, folder, rejects, reply, test } from "yuke:test";
import type { Tool } from "yuke:tools";

/** A tool `name` with no parameters that answers `answer`. */
function tool(name: string, answer = "x"): Tool {
  return {
    name,
    description: "d",
    concurrency: "serial",
    parameters: { type: "object", properties: {} },
    execute: () => answer,
  } as Tool;
}

/** The message of the rejection of `call`. */
async function refusal(call: Promise<unknown>): Promise<string> {
  const error = await rejects(call);
  return error instanceof Error ? error.message : String(error);
}

const SETUP_FAILED = "the session setup failed, and its tools and hooks are gone: ";

test("each session has its own tools, also with one name", async () => {
  let count = 0;
  const counter: PluginSession = (s) => {
    count += 1;
    s.tools.define(tool(`t${count}`));
    s.tools.define(tool("who", `session ${count}`));
  };
  await using host = await createHost({ plugins: [{ name: "counter", session: counter }] });
  const first = await host.openSession();
  const second = await host.openSession();

  equal(
    [(await first.call("t1", {})).text, (await first.call("who", {})).text, (await second.call("who", {})).text],
    ["x", "session 1", "session 2"],
  );
  equal(await refusal(first.call("t2", {})), "the session has no tool t2");
});

test("every session setup starts before any of them settles", async () => {
  let release = (): void => {};
  const waiting: PluginSession = async (s) => {
    await new Promise<void>((resolve) => {
      release = resolve;
    });
    s.tools.define(tool("first"));
  };
  const releasing: PluginSession = (s) => {
    release();
    s.tools.define(tool("second"));
  };
  const replies = [reply.text("Done.")];
  await using host = await createHost({
    plugins: [
      { name: "waiting", session: waiting },
      { name: "releasing", session: releasing },
    ],
    replies,
  });
  const session = await host.openSession();

  await session.send("Hi.");

  // The tools come in the order of their definitions, so the second plugin defines first.
  equal(
    host.requests[0]?.tools.filter((name) => name === "first" || name === "second"),
    ["second", "first"],
  );
});

test("a name that an earlier plugin holds fails only the later plugin", async () => {
  await using host = await createHost({
    plugins: [
      { name: "first", session: (s) => void s.tools.define(tool("shared")) },
      {
        name: "second",
        session: (s) => {
          s.tools.define(tool("own"));
          s.tools.define(tool("shared"));
        },
      },
    ],
  });
  const session = await host.openSession();

  equal((await session.call("shared", {})).text, "x");
  equal(await refusal(session.call("own", {})), "the session has no tool own");
  // The first line holds the error. The next lines hold the frames of the plugin.
  equal(
    host.notices.map((notice) => [notice.source, notice.message.split("\n")[0]]),
    [["second", `${SETUP_FAILED}TypeError: the session already has a tool with the name 'shared'`]],
  );
});

test("a tool of yuke holds its name, so a plugin tool of that name fails its session", async () => {
  await using host = await createHost({
    plugins: [{ name: "reader", session: (s) => void s.tools.define(tool("read")) }],
  });
  const session = await host.openSession();

  equal((await session.call("read", { path: "." })).text.startsWith("the path is a directory"), true);
  equal(
    host.notices.map((notice) => notice.message.split("\n")[0]),
    [`${SETUP_FAILED}TypeError: the session already has a tool with the name 'read'`],
  );
});

test("the folder of a session stays while a call reads the folder of its start", async () => {
  const where: PluginSession = (s) => {
    s.tools.define({
      ...tool("where"),
      execute: (_args, context) => `${s.folder} ${context.folder}`,
    } as Tool);
  };
  await using host = await createHost({ plugins: [{ name: "where", session: where }] });
  const session = await host.openSession();
  await mkdir(`${folder()}/moved`);

  await session.setSettings({ ...session.settings, cwd: `${folder()}/moved` });

  equal((await session.call("where", {})).text, `${folder()} ${folder()}/moved`);
});

test("define fails during the cleanup and after the close", async () => {
  let kept: SessionContext | undefined;
  const refusals: string[] = [];
  const define = (): void => {
    try {
      kept?.tools.define(tool("late"));
      refusals.push("defined");
    } catch (error) {
      refusals.push(error instanceof Error ? error.message : String(error));
    }
  };
  const keeper: PluginSession = (s) => {
    kept = s;
    return define;
  };
  await using host = await createHost({ plugins: [{ name: "keeper", session: keeper }] });
  const session = await host.openSession();

  await session.close();
  define();

  const refused = "plugin keeper defines a tool after the end of its session";
  equal(refusals, [refused, refused]);
});

test("a tool that the session defines after its setup reaches the next calls", async () => {
  let defineLater = (): void => {};
  const later: PluginSession = (s) => {
    s.tools.define(tool("first"));
    defineLater = () => void s.tools.define(tool("later", "late"));
  };
  await using host = await createHost({ plugins: [{ name: "later", session: later }] });
  const session = await host.openSession();
  const before = await refusal(session.call("later", {}));

  defineLater();

  equal([before, (await session.call("later", {})).text], ["the session has no tool later", "late"]);
});

// A second call of a remover removes nothing, so the tool of the same name defined after it stays.
test("a remover frees the name of its tool, and a second call of it removes nothing", async () => {
  let swap = (): void => {};
  const tools: PluginSession = (s) => {
    const remove = s.tools.define(tool("gone"));
    s.tools.define(tool("kept"));
    swap = () => {
      remove();
      s.tools.define(tool("gone", "again"));
      remove();
    };
  };
  await using host = await createHost({ plugins: [{ name: "tools", session: tools }] });
  const session = await host.openSession();

  swap();

  equal([(await session.call("gone", {})).text, (await session.call("kept", {})).text], ["again", "x"]);
});

test("a failed session drops only its tools, aborts its signal, and sends one notice", async () => {
  let bad: SessionContext | undefined;
  const failing: PluginSession = async (s) => {
    bad = s;
    s.tools.define(tool("dropped"));
    await null;
    throw new Error("broken");
  };
  await using host = await createHost({
    plugins: [
      { name: "bad", session: failing },
      { name: "good", session: (s) => void s.tools.define(tool("kept")) },
    ],
  });
  const session = await host.openSession();

  equal((await session.call("kept", {})).text, "x");
  equal(await refusal(session.call("dropped", {})), "the session has no tool dropped");
  const [notice, ...others] = host.notices;
  equal([notice?.sessionId, notice?.level, notice?.source, others], [session.id, "error", "bad", []]);
  // The message ends with the frame of the plugin, so the author finds the line.
  const [message, frame] = notice?.message.split("\n") ?? [];
  equal(message, `${SETUP_FAILED}Error: broken`);
  equal(frame?.trim().startsWith("at failing (") && frame.includes("session-setup.test.ts:"), true);
  let after = "";
  try {
    bad?.tools.define(tool("again"));
  } catch (error) {
    after = `${bad?.signal.aborted} ${error instanceof Error ? error.message : String(error)}`;
  }
  equal(after, "true plugin bad defines a tool after the end of its session");
});

for (const [name, setup, expected] of [
  [
    "a session that throws at once",
    (s: SessionContext) => {
      s.tools.define(tool("gone"));
      throw Object.create(null);
    },
    "a value without a text form",
  ],
  [
    "a session that returns a value that is no cleanup",
    (s: SessionContext) => {
      s.tools.define(tool("gone"));
      return 5;
    },
    "TypeError: session must return nothing or a cleanup function",
  ],
  [
    "a session error whose stack throws",
    () => {
      const error = new Error("broken");
      Object.defineProperty(error, "stack", {
        get() {
          throw new Error("read");
        },
      });
      throw error;
    },
    "Error: broken",
  ],
] as const) {
  test(`${name} drops its tools and sends its notice`, async () => {
    await using host = await createHost({ plugins: [{ name: "failing", session: setup as PluginSession }] });
    const session = await host.openSession();

    equal(await refusal(session.call("gone", {})), "the session has no tool gone");
    equal(
      host.notices.map((notice) => notice.message),
      [`${SETUP_FAILED}${expected}`],
    );
  });
}

test("a notice of a session names its session", async () => {
  await using host = await createHost({ plugins: [{ name: "loud", session: (s) => void s.notify("info", "opened") }] });
  const session = await host.openSession();

  equal(host.notices, [{ sessionId: session.id, level: "info", source: "loud", message: "opened" }]);
});

test("a close refuses definitions from the abort on, and awaits every cleanup", async () => {
  let cleaned = 0;
  let refused = "";
  const broken: PluginSession = () => () => {
    throw Object.create(null);
  };
  const kept: PluginSession = (s) => {
    s.signal.addEventListener("abort", () => {
      try {
        s.tools.define(tool("late"));
      } catch (error) {
        refused = error instanceof Error ? error.message : String(error);
      }
    });
    s.tools.define(tool("kept"));
    return async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
      cleaned += 1;
    };
  };
  await using host = await createHost({
    plugins: [
      { name: "broken", session: broken },
      { name: "kept", session: kept },
    ],
  });
  const session = await host.openSession();

  await session.close();

  equal([cleaned, refused], [1, "plugin kept defines a tool after the end of its session"]);
  equal(
    host.notices.map((notice) => notice.message),
    ["the cleanup of the session failed: a value without a text form"],
  );
});

test("a close during the setup ends it, and runs the late cleanup once", async () => {
  let cleaned = 0;
  const slow: PluginSession = async (s) => {
    await new Promise((resolve) => s.signal.addEventListener("abort", resolve));
    return () => {
      cleaned += 1;
    };
  };
  await using host = await createHost({ plugins: [{ name: "slow", session: slow }] });
  const session = await host.openSession();

  await session.close();

  equal(cleaned, 1);
});
