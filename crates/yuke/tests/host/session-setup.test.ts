// The session of a plugin: its setup, its tools, its failure, and its close.

import { mkdir, writeTextFile } from "yuke:fs";
import type { PluginSession, SessionContext } from "yuke:plugins";
import { createHost, equal, folder, rejects, reply, test, throws, waitForSettled } from "yuke:test";
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
    s.tools.add(tool(`t${count}`));
    s.tools.add(tool("who", `session ${count}`));
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
    s.tools.add(tool("shared", "waiting"));
  };
  const releasing: PluginSession = (s) => {
    release();
    s.tools.add(tool("shared", "releasing"));
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

  await session.sendMessage("Hi.");

  equal(
    [host.requests[0]?.tools.filter((name) => name === "shared"), (await session.call("shared", {})).text],
    [["shared"], "waiting"],
  );
  equal(
    host.notices.map((notice) => [notice.source, notice.text]),
    [["waiting", 'Tool "shared" from "releasing" was replaced by "waiting".']],
  );
});

test("a later plugin replaces a tool and names both owners in an info notice", async () => {
  await using host = await createHost({
    plugins: [
      { name: "first", session: (s) => void s.tools.add(tool("screenshot", "first image")) },
      {
        name: "second",
        session: (s) => {
          s.tools.add(tool("own", "kept"));
          s.tools.add(tool("screenshot", "second image"));
        },
      },
    ],
    replies: [reply.text("Done.")],
  });
  const session = await host.openSession();

  await session.sendMessage("Hi.");

  equal(
    [
      (await session.call("screenshot", {})).text,
      (await session.call("own", {})).text,
      host.requests[0]?.tools.filter((name) => name === "screenshot"),
    ],
    ["second image", "kept", ["screenshot"]],
  );
  equal(host.notices, [
    {
      sessionId: session.id,
      source: "second",
      level: "info",
      text: 'Tool "screenshot" from "first" was replaced by "second".',
    },
  ]);
});

test("a plugin replaces built-ins and its own definitions without a notice", async () => {
  await using host = await createHost({
    plugins: [
      {
        name: "reader",
        session: (s) => {
          s.tools.add(tool("read", "first"));
          s.tools.add(tool("read", "second"));
        },
      },
    ],
    replies: [reply.text("Done.")],
  });
  const session = await host.openSession();

  await session.sendMessage("Hi.");

  equal(
    [(await session.call("read", {})).text, host.requests[0]?.tools.filter((name) => name === "read"), host.notices],
    ["second", ["read"], []],
  );
});

test("name removal omits built-ins and plugin tools from the model request", async () => {
  await using host = await createHost({
    plugins: [
      {
        name: "screenshots",
        session: (s) => {
          s.tools.add(tool("screenshot", "image"));
          s.tools.add(tool("kept", "still here"));
        },
      },
      {
        name: "selection",
        session: (s) => {
          for (const name of ["write", "edit", "screenshot", "unknown"]) s.tools.remove(name);
        },
      },
    ],
    replies: [reply.text("Done.")],
  });
  const session = await host.openSession();

  await session.sendMessage("Hi.");

  equal(
    [host.requests[0]?.tools, (await session.call("kept", {})).text, host.notices],
    [["read", "exec", "stop", "kept"], "still here", []],
  );
  equal(
    [await refusal(session.call("write", {})), await refusal(session.call("screenshot", {}))],
    ["the session has no tool write", "the session has no tool screenshot"],
  );
});

test("a later definition restores a removed name and its disposer reveals the removal", async () => {
  let removeDefinition = (): void => {};
  let defineAgain = (): void => {};
  await using host = await createHost({
    plugins: [
      {
        name: "reader",
        session: (s) => {
          s.tools.remove("read");
          removeDefinition = s.tools.add(tool("read", "replacement"));
          defineAgain = () => void s.tools.add(tool("read", "restored"));
        },
      },
    ],
    replies: [reply.text("Before."), reply.text("Removed."), reply.text("Restored.")],
  });
  const session = await host.openSession();

  await session.sendMessage("First.");
  equal((await session.call("read", {})).text, "replacement");
  removeDefinition();
  await session.sendMessage("Second.");
  equal(await refusal(session.call("read", {})), "the session has no tool read");
  defineAgain();
  await session.sendMessage("Third.");

  equal(
    [
      host.requests.map((request) => request.tools.filter((name) => name === "read")),
      (await session.call("read", {})).text,
    ],
    [[["read"], [], ["read"]], "restored"],
  );
});

test("disposers restore earlier definitions and never remove a newer registration", async () => {
  await writeTextFile(`${folder()}/note.txt`, "default");
  let removeFirst = (): void => {};
  let removeSecond = (): void => {};
  let defineSecond = (): void => {};
  await using host = await createHost({
    plugins: [
      {
        name: "first",
        session: (s) => {
          removeFirst = s.tools.add(tool("read", "first"));
        },
      },
      {
        name: "second",
        session: (s) => {
          defineSecond = () => {
            removeSecond = s.tools.add(tool("read", "second"));
          };
          defineSecond();
        },
      },
    ],
  });
  const session = await host.openSession();

  equal((await session.call("read", {})).text, "second");
  removeSecond();
  equal((await session.call("read", {})).text, "first");
  defineSecond();
  removeFirst();
  removeFirst();
  equal((await session.call("read", {})).text, "second");
  removeSecond();

  equal((await session.call("read", { path: "note.txt" })).text, "1: default");
});

test("failed setup withdraws its overrides and name removals", async () => {
  await using host = await createHost({
    plugins: [
      { name: "first", session: (s) => void s.tools.add(tool("read", "first")) },
      {
        name: "broken",
        session: async (s) => {
          s.tools.remove("read");
          s.tools.remove("write");
          s.tools.add(tool("read", "broken"));
          await null;
          throw new Error("broken");
        },
      },
    ],
  });
  const session = await host.openSession();

  equal(
    [(await session.call("read", {})).text, (await session.call("write", { path: "note.txt", content: "note" })).text],
    ["first", "The tool wrote 4 bytes."],
  );
  equal(
    host.notices.map((notice) => [notice.source, notice.level, notice.text.split("\n")[0]]),
    [["broken", "error", `${SETUP_FAILED}Error: broken`]],
  );
});

test("overrides and name removals stay within their session", async () => {
  await writeTextFile(`${folder()}/note.txt`, "default");
  let count = 0;
  await using host = await createHost({
    plugins: [
      {
        name: "reader",
        session: (s) => {
          count += 1;
          if (count === 1) {
            s.tools.add(tool("read", "first session"));
            s.tools.remove("write");
          }
        },
      },
    ],
  });
  const first = await host.openSession();
  const second = await host.openSession();

  equal(
    [(await first.call("read", {})).text, (await second.call("read", { path: "note.txt" })).text],
    ["first session", "1: default"],
  );
  equal(await refusal(first.call("write", {})), "the session has no tool write");
  await first.close();
  equal((await second.call("write", { path: "other.txt", content: "second" })).text, "The tool wrote 6 bytes.");
});

test("an invalid replacement or removal leaves the current tool unchanged", async () => {
  const errors: unknown[] = [];
  await using host = await createHost({
    plugins: [
      {
        name: "reader",
        session: (s) => {
          s.tools.add(tool("read", "kept"));
          errors.push(throws(() => s.tools.add({ ...tool("read", "broken"), concurrency: "wrong" } as never)));
          errors.push(throws(() => s.tools.remove("bad name")));
          errors.push(throws(() => s.tools.remove("tool_call")));
        },
      },
    ],
  });
  const session = await host.openSession();

  equal(
    [
      (await session.call("read", {})).text,
      errors.map((error) => (error instanceof Error ? error.message : String(error))),
    ],
    [
      "kept",
      [
        "the concurrency 'wrong' is not 'serial' or 'parallel'",
        'the tool name "bad name" does not match ^[a-zA-Z0-9_-]{1,64}$',
        'the engine reserves the tool name "tool_call"',
      ],
    ],
  );
  equal(host.notices, []);
});

test("the folder of a session stays while a call reads the folder of its start", async () => {
  const where: PluginSession = (s) => {
    s.tools.add({
      ...tool("where"),
      execute: (_args, context) => `${s.cwd} ${context.cwd}`,
    } as Tool);
  };
  await using host = await createHost({ plugins: [{ name: "where", session: where }] });
  const session = await host.openSession();
  await mkdir(`${folder()}/moved`);

  await session.setSettings({ ...session.settings, cwd: `${folder()}/moved` });

  equal((await session.call("where", {})).text, `${folder()} ${folder()}/moved`);
});

test("a tool that the session defines after its setup reaches the next calls", async () => {
  let defineLater = (): void => {};
  const later: PluginSession = (s) => {
    s.tools.add(tool("first"));
    defineLater = () => void s.tools.add(tool("later", "late"));
  };
  await using host = await createHost({ plugins: [{ name: "later", session: later }] });
  const session = await host.openSession();
  const before = await refusal(session.call("later", {}));

  defineLater();

  equal([before, (await session.call("later", {})).text], ["the session has no tool later", "late"]);
});

test("a failed session drops only its tools, aborts its signal, and sends one notice", async () => {
  let bad: SessionContext | undefined;
  const failing: PluginSession = async (s) => {
    bad = s;
    s.tools.add(tool("dropped"));
    await null;
    throw new Error("broken");
  };
  await using host = await createHost({
    plugins: [
      { name: "bad", session: failing },
      { name: "good", session: (s) => void s.tools.add(tool("kept")) },
    ],
  });
  const session = await host.openSession();

  equal((await session.call("kept", {})).text, "x");
  equal(await refusal(session.call("dropped", {})), "the session has no tool dropped");
  const [notice, ...others] = host.notices;
  equal([notice?.sessionId, notice?.level, notice?.source, others], [session.id, "error", "bad", []]);
  // The message ends with a stack frame, so the author finds the line.
  const [message, frame] = notice?.text.split("\n") ?? [];
  equal(message, `${SETUP_FAILED}Error: broken`);
  equal(frame?.trim().startsWith("at "), true);
  let after = "";
  try {
    bad?.tools.add(tool("again"));
  } catch (error) {
    after = `${bad?.signal.aborted} ${error instanceof Error ? error.message : String(error)}`;
  }
  equal(after, "true plugin bad defines a tool after the end of its session");
});

test("a notice of a session names its session", async () => {
  await using host = await createHost({ plugins: [{ name: "loud", session: (s) => void s.notify("info", "opened") }] });
  const session = await host.openSession();

  equal(host.notices, [{ sessionId: session.id, level: "info", source: "loud", text: "opened" }]);
});

test("a close refuses definitions from the abort on, and awaits every cleanup", async () => {
  let cleaned = 0;
  let refused = "";
  const cleanup = Promise.withResolvers<void>();
  const broken: PluginSession = () => () => {
    throw new Error("broken cleanup");
  };
  const kept: PluginSession = (s) => {
    s.signal.addEventListener("abort", () => {
      try {
        s.tools.add(tool("late"));
      } catch (error) {
        refused = error instanceof Error ? error.message : String(error);
      }
    });
    s.tools.add(tool("kept"));
    return async () => {
      await cleanup.promise;
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

  let closed = false;
  const closing = session.close().then(() => {
    closed = true;
  });
  await waitForSettled();
  equal([closed, cleaned], [false, 0]);
  cleanup.resolve();
  await closing;

  equal([cleaned, refused], [1, "plugin kept defines a tool after the end of its session"]);
  equal(
    host.notices.map((notice) => notice.text.split("\n")[0]),
    ["the cleanup of the session failed: Error: broken cleanup"],
  );
  equal(/\n\s+at /.test(host.notices[0]?.text ?? ""), true);
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
