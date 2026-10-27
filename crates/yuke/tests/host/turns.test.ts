// The plugins in the turns of the app: the prompt, the hooks, the tools, the skills, and the sessions of a plugin.

import { mkdir, writeTextFile } from "yuke:fs";
import type { PluginApply, PluginSession, Sessions } from "yuke:plugins";
import { createFakeModel, createHost, equal, folder, rejects, reply, type TestSession, test } from "yuke:test";
import { waitFor } from "./wait.ts";

/** The text of the last answer in the transcript of `session`. */
function finalText(session: TestSession): string | undefined {
  const texts = session.transcript.entries.flatMap((entry) => (entry.kind === "text" ? [entry.text] : []));
  return texts.at(-1);
}

test("a create, a reopen, and a fork each run the session of a plugin once, and a second open runs it no more", async () => {
  let count = 0;
  let sessions: Sessions | undefined;
  const counter: PluginSession = (s) => {
    count += 1;
    s.notify("info", `open ${count}`);
  };
  const holder: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  await using host = await createHost({
    plugins: [
      { name: "counter", session: counter },
      { name: "holder", apply: holder },
    ],
  });
  if (sessions === undefined) throw new Error("the plugin got no sessions service");
  const watch = { tail: 1, event: () => undefined };

  const session = await host.openSession();
  await sessions.open(session.id, watch);
  await session.close();
  await sessions.open(session.id, watch);
  const fork = await sessions.fork(session.id);
  await sessions.open(fork, watch);
  await sessions.open(fork, watch);

  equal(
    host.notices.map((notice) => notice.message),
    ["open 1", "open 2", "open 3"],
  );
});

test("a cancel and a close end a turn that waits for the plugins of its session", async () => {
  const slow: PluginSession = (s) =>
    new Promise((resolve) => s.signal.addEventListener("abort", () => resolve(undefined)));
  await using host = await createHost({ plugins: [{ name: "slow", session: slow }] });
  const session = await host.openSession();
  const stop = new AbortController();
  const sent = rejects(session.send("hi", { signal: stop.signal }));
  // The turn runs before the cancel, so the cancel reaches a turn that waits for the plugins.
  await waitFor(() => session.transcript.state === "running");
  stop.abort(new Error("stop"));

  await sent;
  const cancelled = session.transcript.entries.at(-1);
  const again = session.send("again");
  await waitFor(() => session.transcript.state === "running");
  await session.close();
  // The close ends the waiting turn, so the second send settles too.
  await Promise.allSettled([again]);

  equal(cancelled?.kind === "end" && cancelled.end, { outcome: "cancelled" });
});

test("the prompt hook edits the request of each turn from the saved sections", async () => {
  let count = 0;
  const counted: PluginSession = (s) => {
    s.hook("prompt.build", (event) => {
      count += 1;
      return { sections: { ...event.sections, turn: `number ${count}` } };
    });
  };
  const model = createFakeModel([reply.text("one"), reply.text("two")]);
  await using host = await createHost({ plugins: [{ name: "counted", session: counted }], model });
  const session = await host.openSession();

  await session.send("first");
  await session.send("second");

  const [first, second] = model.requests.map((request) => request.system);
  equal(
    [
      first?.includes("<turn>\nnumber 1\n</turn>"),
      second?.includes("<turn>\nnumber 2\n</turn>"),
      second?.includes("number 1"),
    ],
    [true, true, false],
  );
});

test("a failed prompt hook sends a notice, starts no request, and leaves the input pending", async () => {
  const broken: PluginSession = (s) => {
    s.hook("prompt.build", () => {
      throw new Error("no prompt");
    });
  };
  const model = createFakeModel([]);
  await using host = await createHost({ plugins: [{ name: "broken", session: broken }], model });
  const session = await host.openSession();

  await session.send("hi");

  const [notice] = host.notices;
  equal(notice?.message.includes("prompt.build of plugin broken failed: Error: no prompt"), true);
  // The notice keeps the stack of the throw, which names the module of the plugin.
  equal(notice?.message.includes("turns.test.ts"), true);
  equal([model.requests.length, session.transcript.pending.size], [0, 1]);
});

// The model gets the reason of a block as the error result of that call, and the turn goes on.
test("a plugin blocks one of two tool calls in an answer, and the other tool call runs", async () => {
  await writeTextFile(`${folder()}/notes.txt`, "the notes");
  await writeTextFile(`${folder()}/secret.txt`, "the secret");
  const guard: PluginSession = (s) => {
    s.hook("tool.before", (event) => {
      const path = (event.call.arguments as { path?: string }).path;
      return event.call.name === "read" && path === "secret.txt" ? { block: "secret.txt is private" } : undefined;
    });
  };
  const reads = ["notes.txt", "secret.txt"].map((path) => ({ name: "read", args: { path } }));
  const model = createFakeModel([reply.toolCalls(reads), reply.text("done")]);
  await using host = await createHost({ plugins: [{ name: "guard", session: guard }], model });
  const session = await host.openSession();

  await session.send("read both");

  const results = model.requests[1]?.messages.map((message) => message.text).join("\n") ?? "";
  equal(
    [results.includes("the notes"), results.includes("secret.txt is private"), results.includes("the secret")],
    [true, true, false],
  );
  const end = session.transcript.entries.at(-1);
  equal(end?.kind === "end" && end.end, { outcome: { completed: { finishReason: "stop" } } });
});

// The model and the transcript both get the patched result. Only the hook sees the original text.
test("a plugin patches a tool result before the model reads it, and the session saves the patched result", async () => {
  await writeTextFile(`${folder()}/notes.txt`, "password: hunter2");
  let sessions: Sessions | undefined;
  const redact: PluginSession = (s) => {
    s.hook("tool.after", (event) => ({ text: event.result.text.replaceAll("hunter2", "***") }));
  };
  const holder: PluginApply = (ctx) => {
    sessions = ctx.get("sessions");
    return undefined;
  };
  const model = createFakeModel([reply.toolCall("read", { path: "notes.txt" }), reply.text("done")]);
  await using host = await createHost({
    plugins: [
      { name: "redact", session: redact },
      { name: "holder", apply: holder },
    ],
    model,
  });
  const session = await host.openSession();

  await session.send("read the notes");
  await session.close();
  // A view of a closed session starts with the saved events, so the snapshot shows what the store holds.
  let saved = "";
  await sessions?.open(session.id, {
    tail: 20,
    event: (event) => {
      if ("snapshot" in event) saved = JSON.stringify(event.snapshot);
    },
  });

  const seen = [JSON.stringify(model.requests[1]?.messages), JSON.stringify(session.transcript.entries), saved];
  equal(
    seen.map((text) => [text.includes("password: ***"), text.includes("hunter2")]),
    [
      [true, false],
      [true, false],
      [true, false],
    ],
  );
});

// The hook runs in the session, so the host reads the answer while the hook waits.
test("an input.before handler asks the user, and a refusal removes the input", async () => {
  const guard: PluginSession = (s) => {
    s.hook("input.before", async (event) => {
      const sent = await s.confirm("Send this input?", "", { signal: event.signal });
      return sent ? undefined : { block: "the user refused" };
    });
  };
  const model = createFakeModel([]);
  await using host = await createHost({ plugins: [{ name: "guard", session: guard }], model, answer: () => false });
  const session = await host.openSession();

  await session.send("rm -rf");

  equal([model.requests.length, session.transcript.pending.size], [0, 0]);
  equal(
    host.questions.map((question) => question.request.title),
    ["Send this input?"],
  );
});

test("a plugin creates a session, sends input, and sees the turn of that session", async () => {
  const driver: PluginApply = (ctx) => {
    const sessions = ctx.get("sessions");
    setTimeout(async () => {
      const id = await sessions.create({
        model: { provider: "minimax", model: "MiniMax-M3" },
        settings: {
          maxOutputTokens: null,
          reasoning: { thinking: null, effort: null },
          temperature: null,
          topP: null,
          toolChoice: "auto",
          outputSchema: null,
        },
        cwd: folder(),
      });
      const states: string[] = [];
      const texts: string[] = [];
      let used = "";
      let idle = (): void => {};
      const ended = new Promise<void>((resolve) => {
        idle = resolve;
      });
      const handle = await sessions.open(id, {
        tail: 10,
        event: (event) => {
          if ("snapshot" in event) {
            used = event.snapshot.settings.model.model;
            return;
          }
          const update = event.update;
          if (update.sessionUpdate === "commit") {
            for (const block of update.commit.blocks) if ("assistant_text" in block) texts.push(block.assistant_text);
          }
          if (!("state" in update)) return;
          states.push(update.state);
          if (update.state === "idle") idle();
        },
      });
      await handle.input([{ user_text: "hi" }]);
      await handle.idle();
      await ended;
      ctx.emit("turn", { states, texts, used, jobs: handle.jobs().length });
    }, 0);
    return undefined;
  };
  const model = createFakeModel([reply.text("hello")]);
  await using host = await createHost({ plugins: [{ name: "driver", apply: driver }], model });

  await waitFor(() => host.events.length === 1);

  equal(host.events[0]?.data, { states: ["running", "idle"], texts: ["hello"], used: "MiniMax-M3", jobs: 0 });
  equal(model.requests[0]?.messages, [{ role: "user", text: "hi" }]);
});

test("a plugin summarizes the context with the model of the session and replaces the context", async () => {
  const { generateText } = await import("yuke:ai");
  const summary: PluginSession = (s) => {
    s.hook("round.before", async (event) => {
      if (event.blocks < 3) return undefined;
      const instructions = "Summarize the conversation.";
      const answer = await generateText({
        model: s.model,
        instructions,
        prompt: event.context(),
        abortSignal: event.signal,
      });
      return { replace: { head: [{ user_text: `Summary: ${answer.text}` }], keep: 0 } };
    });
  };
  const model = createFakeModel([
    reply.toolCall("read", { path: "missing.txt" }),
    reply.text("They said hi."),
    reply.text("Done."),
  ]);
  await using host = await createHost({ plugins: [{ name: "summary", session: summary }], model });
  const session = await host.openSession();

  await session.send("Hi.");
  equal(finalText(session), "Done.");

  const [, side, last] = model.requests;
  equal([side?.system, side?.tools, side?.messages[0]?.text], ["Summarize the conversation.", [], "Hi."]);
  equal(last?.messages, [{ role: "user", text: "Summary: They said hi." }]);
});

test("a side request repeats the body of the request of the round with one more block", async () => {
  let asked = false;
  const aside: PluginSession = (s) => {
    s.hook("round.before", async (event) => {
      if (asked) return undefined;
      asked = true;
      await event.sideRequest({ prompt: "Summarize." });
      return undefined;
    });
  };
  const model = createFakeModel([reply.text("A summary."), reply.text("Done.")]);
  await using host = await createHost({ plugins: [{ name: "aside", session: aside }], model });
  const session = await host.openSession();

  await session.send("Hi.");
  equal(finalText(session), "Done.");

  const [side, round] = model.requests.map((request) => request.body as { messages: { content: unknown[] }[] });
  const expected = JSON.parse(JSON.stringify(round)) as typeof round;
  expected?.messages[0]?.content.push({ text: "Summarize.", type: "text" });
  equal(JSON.stringify(side), JSON.stringify(expected));
});

test("an input that a plugin replaces reaches the model as the new blocks", async () => {
  const skills: PluginSession = (s) => {
    s.hook("input.before", (event) => {
      const first = event.blocks[0];
      if (first === undefined || !("user_text" in first) || first.user_text !== "/skill:pdf") return undefined;
      return { replace: { blocks: [{ user_text: "Read PDF files with care." }] } };
    });
  };
  const model = createFakeModel([reply.text("Done.")]);
  await using host = await createHost({ plugins: [{ name: "skills", session: skills }], model });
  const session = await host.openSession();

  await session.send("/skill:pdf");
  equal(finalText(session), "Done.");

  equal(model.requests[0]?.messages, [{ role: "user", text: "Read PDF files with care." }]);
});

test("an input that a plugin handles starts no turn", async () => {
  const commands: PluginSession = (s) => {
    s.hook("input.before", () => ({ handled: true }));
  };
  const model = createFakeModel([]);
  await using host = await createHost({ plugins: [{ name: "commands", session: commands }], model });
  const session = await host.openSession();

  await session.send("/compact");

  equal([model.requests.length, session.transcript.pending.size], [0, 0]);
});

test("the skills of a plugin folder come before the skills of the workspace in the system prompt", async () => {
  const root = `${folder()}/helper`;
  await mkdir(`${root}/skills/charts`, { recursive: true });
  await writeTextFile(`${root}/plugin.json`, JSON.stringify({ name: "helper", extensions: { "sh.yuke": {} } }));
  await writeTextFile(`${root}/skills/charts/SKILL.md`, "---\nname: charts\ndescription: Draw charts.\n---\n");
  await mkdir(`${folder()}/.agents/skills/pdf`, { recursive: true });
  await writeTextFile(`${folder()}/.agents/skills/pdf/SKILL.md`, "---\nname: pdf\ndescription: Read PDF files.\n---\n");
  const model = createFakeModel([reply.text("Hello.")]);
  await using host = await createHost({ plugins: [{ folder: root }], model });
  const session = await host.openSession();

  await session.send("Hi.");

  const system = model.requests[0]?.system ?? "";
  const at = (text: string): number => system.indexOf(text);
  equal(
    [
      at("<name>charts</name>") >= 0,
      at("<name>charts</name>") < at("Draw charts."),
      at("Draw charts.") < at("<name>pdf</name>"),
    ],
    [true, true, true],
  );
  equal(at("Read PDF files.") < at("<environment>") && at("Read PDF files.") >= 0, true);
});
