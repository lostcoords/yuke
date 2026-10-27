// The `tool.after` hook: its chain, its answers, its media, and its failures.

import { writeTextFile } from "yuke:fs";
import type { PluginSession } from "yuke:plugins";
import { createFakeModel, createHost, equal, folder, reply, type TestMedia, type ToolOutcome, test } from "yuke:test";

const call = { id: "c1", name: "read", arguments: { path: "notes.md" } };
const png = new Uint8Array([1, 2, 3]);
const jpeg = new Uint8Array([1, 2, 3, 4, 5]);

/** The result of `call`: a text, a png of 3 bytes, and a jpeg of 5 bytes. */
const original = {
  text: "secret: hunter2",
  isError: false,
  media: [
    { mimeType: "image/png", bytes: png },
    { mimeType: "image/jpeg", bytes: jpeg },
  ],
};

/** The plain values of `media`, for a comparison. */
function plain(media: readonly TestMedia[]): unknown[] {
  return media.map((item) => [item.mimeType, [...item.bytes]]);
}

/** The outcome of `run` with plain media. */
function outcome(result: ToolOutcome): unknown {
  return { text: result.text, isError: result.isError, media: plain(result.media) };
}

/** The `tool.after` outcome for `original` with the plugins `plugins`. */
async function after(plugins: readonly { name: string; session: PluginSession }[]): Promise<unknown> {
  await using host = await createHost({ plugins });
  const session = await host.openSession();
  return outcome(await session.run("tool.after", { call, result: original }));
}

/** The error outcome with `text`, as the host gives it for a failed handler. */
function failed(text: string): unknown {
  return { text, isError: true, media: [] };
}

test("the result stays when no handler answers", async () => {
  const quiet: PluginSession = (s) => {
    s.hook("tool.after", () => undefined);
  };

  equal(await after([{ name: "quiet", session: quiet }]), {
    text: original.text,
    isError: false,
    media: [
      ["image/png", [...png]],
      ["image/jpeg", [...jpeg]],
    ],
  });
});

// An answer replaces only its own fields, so the media of the result stay.
test("each handler gets the call and the result after the answers before it", async () => {
  const redact: PluginSession = (s) => {
    s.hook("tool.after", (event) => {
      const path = (event.call.arguments as { path: string }).path;
      return { text: `${event.call.id} ${event.call.name} ${path}: ${event.result.text.replace("hunter2", "***")}` };
    });
  };
  const flag: PluginSession = (s) => {
    s.hook("tool.after", (event) => ({ text: `${event.result.text} (${event.result.isError})`, isError: true }));
  };

  equal(
    await after([
      { name: "redact", session: redact },
      { name: "flag", session: flag },
    ]),
    {
      text: "c1 read notes.md: secret: *** (false)",
      isError: true,
      media: [
        ["image/png", [...png]],
        ["image/jpeg", [...jpeg]],
      ],
    },
  );
});

// The id of a result item names that item. The item, a copy of the item, and its id alone each keep the item.
test("an answer keeps, reorders, removes, and adds media", async () => {
  const pics: PluginSession = (s) => {
    s.hook("tool.after", (event) => {
      const [first, second] = event.result.media;
      if (first === undefined || second === undefined || !("id" in first) || !("id" in second)) return undefined;
      return {
        text: event.result.media
          .map((item) => ("id" in item ? `${item.id} ${item.mimeType} ${item.size}` : ""))
          .join(", "),
        media: [
          second,
          { ...first },
          { id: second.id },
          { mimeType: "image/gif", bytes: new Uint8Array([1, 2]) },
          { mimeType: "text/plain", path: "pics.txt" },
        ],
      };
    });
  };
  await writeTextFile(`${folder()}/pics.txt`, "a picture");

  equal(await after([{ name: "pics", session: pics }]), {
    text: "0 image/png 3, 1 image/jpeg 5",
    isError: false,
    media: [
      ["image/jpeg", [...jpeg]],
      ["image/png", [...png]],
      ["image/jpeg", [...jpeg]],
      ["image/gif", [1, 2]],
      ["text/plain", [...new TextEncoder().encode("a picture")]],
    ],
  });
});

// Two items can hold the same bytes, so each item has its own id.
test("an answer keeps the second of two items with the same bytes", async () => {
  const pick: PluginSession = (s) => {
    s.hook("tool.after", (event) => {
      const second = event.result.media[1];
      return second !== undefined && "id" in second ? { media: [{ id: second.id }] } : undefined;
    });
  };
  await using host = await createHost({ plugins: [{ name: "pick", session: pick }] });
  const session = await host.openSession();

  const result = await session.run("tool.after", {
    call,
    result: {
      ...original,
      media: [
        { mimeType: "image/png", bytes: png },
        { mimeType: "image/webp", bytes: png },
      ],
    },
  });

  equal(plain(result.media), [["image/webp", [...png]]]);
});

// The handlers of a run are fixed at its start, also for the plugins after the one that changes them.
test("a change of the handlers during a run changes only the next run", async () => {
  let swap = (): void => {};
  const first: PluginSession = (s) => {
    s.hook("tool.after", () => {
      swap();
      return undefined;
    });
  };
  const second: PluginSession = (s) => {
    let remove = s.hook("tool.after", (event) => ({ text: `${event.result.text} old` }));
    swap = () => {
      remove();
      remove = s.hook("tool.after", (event) => ({ text: `${event.result.text} new` }));
    };
  };
  await using host = await createHost({
    plugins: [
      { name: "first", session: first },
      { name: "second", session: second },
    ],
  });
  const session = await host.openSession();

  const runs = [
    await session.run("tool.after", { call, result: original }),
    await session.run("tool.after", { call, result: original }),
  ];

  equal(
    runs.map((result) => result.text),
    ["secret: hunter2 old", "secret: hunter2 new"],
  );
});

// The engine asks for the calls of a parallel group together, so the runs of two calls overlap.
test("each of two overlapping calls gets its own answer", async () => {
  const slow: PluginSession = (s) => {
    s.tools.define({
      name: "echo",
      description: "Echo the text.",
      concurrency: "parallel",
      parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
      execute: (args) => args.text,
    });
    s.hook("tool.after", async (event) => {
      await new Promise((resolve) => setTimeout(resolve, event.result.text === "first" ? 30 : 0));
      return { text: `${event.call.id}: ${event.result.text}` };
    });
  };
  const calls = ["first", "second"].map((text) => ({ name: "echo", args: { text } }));
  const model = createFakeModel([reply.toolCalls(calls), reply.text("Done.")]);
  await using host = await createHost({ plugins: [{ name: "slow", session: slow }], model });
  const session = await host.openSession();

  await session.send("Echo.");

  const results = session.transcript.entries.flatMap((entry) => (entry.kind === "tool" ? [entry.result] : []));
  equal(
    results.map((result) => result?.content),
    ["first", "second"].map((text, index) => `${results[index]?.callId}: ${text}`),
  );
});

for (const [name, body, error] of [
  [
    "a throw",
    () => {
      throw new Error("no redaction today");
    },
    "Error: no redaction today",
  ],
  ["a text that is no text", () => ({ text: 1 }), "TypeError: the text of the answer is not a string"],
  [
    "an isError that is no boolean",
    () => ({ isError: "yes" }),
    "TypeError: the isError of the answer is not a boolean",
  ],
  ["an unknown field", () => ({ txt: "x" }), "TypeError: the answer has the unknown field 'txt'"],
  ["a text", () => "x", "TypeError: the answer is not an object"],
  ["null", () => null, "TypeError: the answer is not an object"],
  [
    "an id of no item",
    () => ({ media: [{ id: "00" }] }),
    "TypeError: the answer media[0].id names no media item of the result",
  ],
  [
    "a kept item of another media type",
    (event: { result: { media: readonly object[] } }) => ({
      media: [event.result.media[0], { ...event.result.media[0], mimeType: "image/gif" }],
    }),
    "TypeError: the answer media[1].mimeType differs from the kept item",
  ],
  [
    "a kept item of another size",
    (event: { result: { media: readonly object[] } }) => ({ media: [{ ...event.result.media[1], size: 1 }] }),
    "TypeError: the answer media[0].size differs from the kept item",
  ],
  [
    "a kept item with a path",
    (event: { result: { media: readonly object[] } }) => ({ media: [{ ...event.result.media[0], path: "a.png" }] }),
    "TypeError: the answer media[0] has the unknown field 'path'",
  ],
] as const) {
  test(`${name} gives an error result that names the plugin`, async () => {
    const check: PluginSession = (s) => {
      s.hook("tool.after", body as never);
    };

    equal(await after([{ name: "check", session: check }]), failed(`tool.after of plugin check failed: ${error}`));
  });
}

// A handler that changes the event or the result in place would skip the checks of an answer.
for (const [name, change] of [
  [
    "the text",
    (event: { result: { text: string } }) => {
      event.result.text = "x";
    },
  ],
  [
    "the media list",
    (event: { result: { media: unknown[] } }) => {
      event.result.media.pop();
    },
  ],
  [
    "a media item",
    (event: { result: { media: { size: number }[] } }) => {
      (event.result.media[0] as { size: number }).size = 1;
    },
  ],
  [
    "the result",
    (event: { result: unknown }) => {
      event.result = {};
    },
  ],
] as const) {
  test(`a change of ${name} throws and gives an error result`, async () => {
    const editor: PluginSession = (s) => {
      s.hook("tool.after", (event) => {
        (change as (event: unknown) => void)(event);
        return undefined;
      });
    };

    const result = (await after([{ name: "editor", session: editor }])) as {
      text: string;
      isError: boolean;
      media: unknown[];
    };

    equal(
      [result.text.startsWith("tool.after of plugin editor failed: TypeError: "), result.isError, result.media],
      [true, true, []],
    );
  });
}

test("a new media item that cannot be read gives an error result", async () => {
  const pics: PluginSession = (s) => {
    s.hook("tool.after", () => ({ media: [{ mimeType: "image/png", path: "missing.png" }] }));
  };

  const result = (await after([{ name: "pics", session: pics }])) as {
    text: string;
    isError: boolean;
    media: unknown[];
  };

  equal(
    [result.text.startsWith("the tool.after hooks failed: missing.png: "), result.isError, result.media],
    [true, true, []],
  );
});

test("a removed handler and the handler of a failed session do not run", async () => {
  const ran: string[] = [];
  const removed: PluginSession = (s) => {
    s.hook("tool.after", () => {
      ran.push("removed");
      return undefined;
    })();
  };
  const failing: PluginSession = async (s) => {
    s.hook("tool.after", () => {
      ran.push("failed");
      return undefined;
    });
    await null;
    throw new Error("broken");
  };

  const result = (await after([
    { name: "removed", session: removed },
    { name: "failed", session: failing },
  ])) as { text: string };

  equal([result.text, ran], [original.text, []]);
});
