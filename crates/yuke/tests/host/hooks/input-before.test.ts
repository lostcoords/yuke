// The `input.before` hook: its event, its chain, and each answer.

import { writeFile } from "yuke:fs";
import type { InputBeforeAnswer, PluginSession } from "yuke:plugins";
import { createHost, equal, folder, test } from "yuke:test";

const typed = (text: string) => ({ source: { kind: "user" }, kind: "message", blocks: [{ user_text: text }] }) as const;

/** A plugin whose `input.before` handler gives `answer`. */
const answering =
  (answer: unknown): PluginSession =>
  (s) => {
    s.hook("input.before", () => answer as undefined);
  };

test("an input without an answer stays as it is", async () => {
  await using host = await createHost({ plugins: [{ name: "quiet", session: answering(undefined) }] });
  const session = await host.openSession();

  equal(await session.run("input.before", typed("hi")), "keep");
});

test("a replace feeds the next handler, and the decision holds the last blocks", async () => {
  const seen: unknown[] = [];
  const first: PluginSession = (s) => {
    s.hook("input.before", (event) => {
      seen.push(JSON.stringify({ source: event.source, kind: event.kind, blocks: event.blocks }));
      return { replace: { blocks: [{ user_text: "expanded" }] } };
    });
  };
  const second: PluginSession = (s) => {
    s.hook("input.before", (event) => {
      seen.push(JSON.stringify(event.blocks));
      return undefined;
    });
  };
  await using host = await createHost({
    plugins: [
      { name: "first", session: first },
      { name: "second", session: second },
    ],
  });
  const session = await host.openSession();

  const decision = await session.run("input.before", typed("/skill:pdf"));

  equal(decision, { replace: { blocks: [{ user_text: "expanded" }] } });
  equal(seen, [
    '{"source":{"kind":"user"},"kind":"message","blocks":[{"user_text":"/skill:pdf"}]}',
    '[{"user_text":"expanded"}]',
  ]);
});

test("a block removes the input with a notice, and the later handlers do not run", async () => {
  let later = false;
  const guard = answering({ block: "it names a secret" });
  const after: PluginSession = (s) => {
    s.hook("input.before", () => {
      later = true;
      return undefined;
    });
  };
  await using host = await createHost({
    plugins: [
      { name: "guard", session: guard },
      { name: "later", session: after },
    ],
  });
  const session = await host.openSession();

  const decision = await session.run("input.before", typed("my key is 123"));

  equal(decision, "remove");
  equal(
    host.notices.map((notice) => [notice.source, notice.level, notice.message]),
    [["guard", "warn", "the plugin blocked the input: it names a secret"]],
  );
  equal(later, false);
});

test("handled removes the input with no notice", async () => {
  await using host = await createHost({ plugins: [{ name: "commands", session: answering({ handled: true }) }] });
  const session = await host.openSession();

  equal(await session.run("input.before", typed("/compact")), "remove");
  equal(host.notices, []);
});

for (const [name, answer, level, expected] of [
  ["a throw", undefined, "error", "Error: boom"],
  [
    "an answer with two decisions",
    { block: undefined, handled: true },
    "error",
    "TypeError: the answer needs exactly one of block, replace, and handled",
  ],
  ["an empty answer", {}, "error", "TypeError: the answer needs exactly one of block, replace, and handled"],
  [
    "an empty replace",
    { replace: { blocks: [] } },
    "error",
    "TypeError: the blocks of the replace are not a list with a block",
  ],
] as const) {
  test(`${name} removes the input, and an error notice names the plugin`, async () => {
    const check: PluginSession =
      answer === undefined
        ? (s) => {
            s.hook("input.before", () => {
              throw new Error("boom");
            });
          }
        : answering(answer);
    await using host = await createHost({ plugins: [{ name: "check", session: check }] });
    const session = await host.openSession();

    const decision = await session.run("input.before", typed("hi"));

    equal(
      [decision, host.notices.map((notice) => [notice.source, notice.level, notice.message])],
      ["remove", [["host:plugins", level, `input.before of plugin check failed: ${expected}`]]],
    );
  });
}

test("a replace keeps a media block, and a later handler sees the bytes of a new media item", async () => {
  let size = 0;
  const media: PluginSession = (s) => {
    s.hook("input.before", (event) => {
      const added = { mimeType: "image/png", bytes: new Uint8Array([1, 2, 3]) };
      return { replace: { blocks: [...event.blocks, added] } } as InputBeforeAnswer;
    });
    s.hook("input.before", (event) => {
      const added = event.blocks[1];
      size = added !== undefined && "bytes" in added && added.bytes !== undefined ? added.bytes.length : -1;
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "media", session: media }] });
  const session = await host.openSession();

  const decision = await session.run("input.before", {
    source: { kind: "user" },
    kind: "message",
    blocks: [{ mimeType: "image/jpeg", bytes: new Uint8Array([9, 9, 9, 9]) }],
  });

  const blocks = typeof decision === "object" ? decision.replace.blocks : [];
  equal(
    blocks.map((block) => ("bytes" in block ? [block.mimeType, [...block.bytes]] : block)),
    [
      ["image/jpeg", [9, 9, 9, 9]],
      ["image/png", [1, 2, 3]],
    ],
  );
  equal(size, 3);
});

test("the event gives the blocks in order, and a media block can name a file", async () => {
  const kinds: string[] = [];
  const look: PluginSession = (s) => {
    s.hook("input.before", (event) => {
      kinds.push(...event.blocks.map((block) => Object.keys(block)[0] ?? ""));
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "look", session: look }] });
  const session = await host.openSession();
  await writeFile(`${folder()}/c.png`, new Uint8Array([2, 3]));

  const decision = await session.run("input.before", {
    source: { kind: "user" },
    kind: "message",
    blocks: [
      { mimeType: "image/png", bytes: new Uint8Array([1]) },
      { user_text: "look" },
      { mimeType: "image/png", path: "c.png" },
    ],
  });

  equal([decision, kinds], ["keep", ["media", "user_text", "media"]]);
});

test("a notification shows its plugin source and its kind", async () => {
  const seen: string[] = [];
  const watch: PluginSession = (s) => {
    s.hook("input.before", (event) => {
      seen.push(`${event.source.kind} ${"name" in event.source ? event.source.name : ""} ${event.kind}`);
      return undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "watch", session: watch }] });
  const session = await host.openSession();

  await session.run("input.before", {
    source: { kind: "plugin", name: "host:jobs" },
    kind: "notification",
    blocks: [{ user_text: "the job ended" }],
  });

  equal(seen, ["plugin host:jobs notification"]);
});
