// The tools of a plugin: their definitions, the check of their arguments, their results, and their signal.

import { mkdir, readDir, writeFile, writeTextFile } from "yuke:fs";
import type { PluginSession } from "yuke:plugins";
import { createHost, equal, folder, rejects, reply, test } from "yuke:test";
import type { Tool } from "yuke:tools";

const empty = { type: "object", properties: {} } as const;

/** A plugin whose session defines `tools`. */
const defining =
  (...tools: Tool[]): PluginSession =>
  (s) => {
    for (const tool of tools) s.tools.define(tool);
  };

/** A tool `name` with no parameters that runs `execute`. */
function tool(name: string, execute: Tool["execute"]): Tool {
  return { name, description: "d", concurrency: "serial", parameters: empty, execute } as Tool;
}

/** A host with one plugin that defines `tools`, and an open session of that host. */
async function opened(...tools: Tool[]) {
  const host = await createHost({ plugins: [{ name: "tools", session: defining(...tools) }] });
  return { host, session: await host.openSession() };
}

test("a change of a tool after its definition changes neither its schema nor its execute", async () => {
  const fixed = {
    name: "fixed",
    description: "d",
    concurrency: "serial",
    parameters: { type: "object", properties: { n: { type: "integer" } }, required: ["n"] },
    execute: (args: { n: number }) => `n=${args.n}`,
  } as unknown as Tool & { parameters: { required: string[] }; execute: unknown };
  const changer: PluginSession = (s) => {
    s.tools.define(fixed);
    fixed.parameters.required = [];
    fixed.execute = () => "changed";
  };
  await using host = await createHost({ plugins: [{ name: "changer", session: changer }] });
  const session = await host.openSession();

  const runs = await session.call("fixed", { n: 2 });
  const missing = await session.call("fixed", {});

  equal([runs.text, runs.isError, missing.isError, missing.text.startsWith("Set n to ")], ["n=2", false, true, true]);
});

test("a deferred tool waits for the tool search of the replies, and the other tools load at once", async () => {
  const replies = [reply.text("Done.")];
  await using host = await createHost({
    plugins: [
      {
        name: "tools",
        session: defining(
          { ...tool("rare", () => "x"), deferLoading: true },
          tool("common", () => "x"),
        ),
      },
    ],
    replies,
  });
  const session = await host.openSession({ model: { provider: "anthropic", model: "claude-fable-5" } });

  await session.send("Hi.");

  const body = host.requests[0]?.body as { tools: { name?: string; defer_loading?: boolean }[] } | undefined;
  const tools = body?.tools ?? [];
  equal(
    tools
      .filter((entry) => entry.name === "rare" || entry.name === "common")
      .map((entry) => [entry.name, entry.defer_loading]),
    [
      ["rare", true],
      ["common", undefined],
    ],
  );
});

for (const [name, definition, expected] of [
  [
    "no concurrency",
    { name: "bad", description: "d", execute: () => "x", parameters: empty },
    "the concurrency 'undefined' is not 'serial' or 'parallel'",
  ],
  [
    "an unchecked keyword",
    {
      ...tool("bad", () => "x"),
      parameters: { type: "object", properties: { mode: { type: "string", pattern: "a" } } },
    },
    "parameters.properties.mode: yuke does not check the keyword 'pattern'",
  ],
  [
    "a minimum that is no number",
    {
      ...tool("bad", () => "x"),
      parameters: { type: "object", properties: { n: { type: "integer", minimum: null } } },
    },
    "parameters.properties.n.minimum is not a finite number",
  ],
  [
    "an empty enum",
    { ...tool("bad", () => "x"), parameters: { type: "object", properties: { o: { type: "string", enum: [] } } } },
    "parameters.properties.o.enum is not a non-empty array",
  ],
  [
    "an enum of integers with a fraction",
    {
      ...tool("bad", () => "x"),
      parameters: { type: "object", properties: { n: { type: "integer", enum: [1, 1.5] } } },
    },
    "parameters.properties.n.enum has a value that is not an integer",
  ],
  [
    "an enum with a value twice",
    {
      ...tool("bad", () => "x"),
      parameters: { type: "object", properties: { o: { type: "string", enum: ["a", "a"] } } },
    },
    "parameters.properties.o.enum has a value twice",
  ],
  [
    "an enum of booleans",
    { ...tool("bad", () => "x"), parameters: { type: "object", properties: { f: { type: "boolean", enum: [true] } } } },
    "parameters.properties.f: yuke does not check the keyword 'enum'",
  ],
  ["the name of the tool search", tool("tool_search", () => "x"), 'the engine reserves the tool name "tool_search"'],
  [
    "a name with a dot",
    tool("notes.search", () => "x"),
    'the tool name "notes.search" does not match ^[a-zA-Z0-9_-]{1,64}$',
  ],
  [
    "parameters of another type",
    { ...tool("bad", () => "x"), parameters: { type: "string" } },
    "parameters.type is not object",
  ],
  ["an execute that is no function", { ...tool("bad", () => "x"), execute: "x" }, "execute is not a function"],
  [
    "a subject that names no string argument",
    { ...tool("bad", () => "x"), hints: { subject: { argument: "path", kind: "file" } } },
    "hints.subject.argument names no string argument",
  ],
  [
    "a subject of an unknown kind",
    {
      ...tool("bad", () => "x"),
      parameters: { type: "object", properties: { path: { type: "string" } } },
      hints: { subject: { argument: "path", kind: "folder" } },
    },
    "hints.subject.kind is not 'text', 'file', or 'uri'",
  ],
  [
    "an unknown preview",
    { ...tool("bad", () => "x"), hints: { preview: "all" } },
    "hints.preview is not 'head', 'tail', or 'none'",
  ],
  ["an unknown hint", { ...tool("bad", () => "x"), hints: { icon: "x" } }, "hints has the unknown field 'icon'"],
  // The check reads the copy that the model gets, so a `toJSON` cannot hide a keyword from it.
  [
    "a keyword behind toJSON",
    {
      ...tool("bad", () => "x"),
      parameters: { ...empty, toJSON: () => ({ type: "object", properties: { m: { type: "string", pattern: "a" } } }) },
    },
    "parameters.properties.m: yuke does not check the keyword 'pattern'",
  ],
] as const) {
  test(`a definition with ${name} fails the session with a notice that names the problem`, async () => {
    const { host, session } = await opened(definition as unknown as Tool);
    await using _host = host;

    const missing = await rejects(session.call(definition.name, {}));

    const [notice] = host.notices;
    const prefix = "the session setup failed, and its tools and hooks are gone: TypeError: ";
    equal(
      [host.notices.length, notice?.message.startsWith(prefix), notice?.message.includes(expected)],
      [1, true, true],
    );
    equal(missing instanceof Error && missing.message, `the session has no tool ${definition.name}`);
  });
}

test("arguments that do not fit the schema fail before the tool runs", async () => {
  await using host = await createHost({ plugins: [] });
  const session = await host.openSession();

  const errors = [];
  for (const [name, args] of [
    ["write", []],
    ["write", { path: "a.txt", content: "x", mode: 1 }],
    ["write", { path: 1, content: "x" }],
    ["write", { path: "a.txt" }],
    ["write", { path: "a.txt", content: "x", toString: 1 }],
    ["read", { path: "a.txt", offset: 0 }],
  ] as const) {
    const result = await session.call(name, args);
    errors.push([result.isError, result.text]);
  }

  equal(errors, [
    [true, "Pass the arguments as a JSON object."],
    [true, "Remove mode. The fields are: path, content."],
    [true, "Set path to a string."],
    [true, "Set content to a string."],
    [true, "Remove toString. The fields are: path, content."],
    [true, "Set offset to an integer from 1 to 4294967295."],
  ]);
  equal((await readDir(folder())).length, 0);
});

test("a value outside the enum fails with the list, and a value in it runs the tool", async () => {
  const sort = {
    name: "sort",
    description: "d",
    concurrency: "serial",
    parameters: {
      type: "object",
      properties: { order: { type: "string", enum: ["asc", "desc"] }, size: { type: "number", enum: [0.5, 2] } },
    },
    execute: (args: unknown) => JSON.stringify(args),
  } as unknown as Tool;
  const { host, session } = await opened(sort);
  await using _host = host;

  const results = [
    await session.call("sort", { order: "up" }),
    await session.call("sort", { size: 1 }),
    await session.call("sort", { order: "desc", size: 0.5 }),
  ];

  equal(
    results.map((result) => [result.isError, result.text]),
    [
      [true, 'Set order to one of "asc", "desc".'],
      [true, "Set size to one of 0.5, 2."],
      [false, '{"order":"desc","size":0.5}'],
    ],
  );
});

test("an argument named __proto__ is an own field", async () => {
  const proto = {
    name: "proto",
    description: "d",
    concurrency: "serial",
    parameters: { type: "object", properties: { ["__proto__"]: { type: "string" } }, required: ["__proto__"] },
    // biome-ignore lint/suspicious/noProto: an own field named __proto__ is the case under test.
    execute: (args: Record<string, unknown>) => String(Object.hasOwn(args, "__proto__") && args.__proto__),
  } as unknown as Tool;
  const { host, session } = await opened(proto);
  await using _host = host;

  equal((await session.call("proto", JSON.parse('{"__proto__": "x"}'))).text, "x");
});

test("a throw of a tool is an error with its message", async () => {
  const { host, session } = await opened(
    tool("fail", () => {
      throw new Error("the disk is full");
    }),
  );
  await using _host = host;

  const result = await session.call("fail", {});

  equal([result.isError, result.text], [true, "the disk is full"]);
});

test("a cancel aborts the signal, and the tool still answers", async () => {
  let reason = "";
  const { host, session } = await opened(
    tool(
      "wait",
      (_args, context) =>
        new Promise((resolve) =>
          context.signal.addEventListener("abort", () => {
            const why = context.signal.reason;
            reason = `${why instanceof DOMException} ${String(why)}`;
            resolve("stopped");
          }),
        ),
    ),
  );
  await using _host = host;
  const stop = new AbortController();
  setTimeout(() => stop.abort(new Error("stop")), 20);

  await session.call("wait", {}, { signal: stop.signal }).catch(() => undefined);

  equal(reason, "true AbortError: The tool call was cancelled");
});

test("the signal aborts when the call ends, and the context names the folder", async () => {
  let kept: AbortSignal | undefined;
  const { host, session } = await opened(
    tool("keep", (_args, context) => {
      kept = context.signal;
      return context.folder;
    }),
  );
  await using _host = host;

  const result = await session.call("keep", {});

  equal([result.text, kept?.aborted], [folder(), true]);
});

test("a call gets the id of its session, its call id, and its folder", async () => {
  const seen: string[][] = [];
  const { host, session } = await opened(
    tool("facts", (_args, context) => {
      seen.push([context.sessionId, context.callId, context.folder]);
      return "x";
    }),
  );
  await using _host = host;
  await mkdir(`${folder()}/other`);
  const other = await host.openSession({ cwd: `${folder()}/other` });

  await session.call("facts", {});
  await other.call("facts", {});

  equal(
    seen.map(([id, , where]) => [id, where]),
    [
      [session.id, folder()],
      [other.id, `${folder()}/other`],
    ],
  );
  equal(
    seen.every(([, callId]) => (callId ?? "").length > 0),
    true,
  );
});

/** The plain values of the media of a result, for a comparison. */
function plain(media: readonly { mimeType: string; bytes: Uint8Array }[]): unknown[] {
  return media.map((item) => [item.mimeType, [...item.bytes]]);
}

test("an error result keeps its text and its media", async () => {
  await writeTextFile(`${folder()}/dot.png`, "png");
  const { host, session } = await opened(
    tool("failed", () => ({
      text: "the render failed",
      media: [{ path: "dot.png", mimeType: "image/png" }],
      isError: true,
    })),
  );
  await using _host = host;

  const result = await session.call("failed", {});

  equal(
    [result.isError, result.text, plain(result.media)],
    [true, "the render failed", [["image/png", [112, 110, 103]]]],
  );
});

test("media bytes reach the store as the view held them at the return", async () => {
  class Own extends Uint8Array<ArrayBuffer> {
    override slice(): Uint8Array<ArrayBuffer> {
      return this;
    }
  }
  const { host, session } = await opened(
    tool("drawn", (_args, context) => {
      const view = new Uint8Array([9, 1, 2, 9]).subarray(1, 3);
      context.signal.addEventListener("abort", () => view.fill(7));
      return { text: "drawn", media: [{ bytes: view, mimeType: "image/png" }] };
    }),
    tool("own", (_args, context) => {
      const bytes = new Own(new ArrayBuffer(2));
      bytes.set([1, 2]);
      context.signal.addEventListener("abort", () => bytes.fill(7));
      return { text: "own", media: [{ bytes, mimeType: "image/png" }] };
    }),
  );
  await using _host = host;

  const drawn = await session.call("drawn", {});
  const own = await session.call("own", {});

  equal([drawn.isError, own.isError], [false, false]);
  equal([plain(drawn.media), plain(own.media)], [[["image/png", [1, 2]]], [["image/png", [1, 2]]]]);
});

const LIMIT = ((5 * 1024 * 1024) / 4) * 3;

test("media over the limit fails the call", async () => {
  await writeFile(`${folder()}/fits.png`, new Uint8Array(LIMIT));
  await writeFile(`${folder()}/large.png`, new Uint8Array(LIMIT + 1));
  const attach = {
    name: "attach",
    description: "d",
    concurrency: "serial",
    parameters: { type: "object", properties: { paths: { type: "array", items: { type: "string" } } } },
    execute: (args: { paths: string[] }) => ({
      text: "attached",
      media: args.paths.map((path) => ({ path, mimeType: "image/png" })),
    }),
  } as unknown as Tool;
  const { host, session } = await opened(
    attach,
    tool("large", () => ({ text: "large", media: [{ bytes: new Uint8Array(LIMIT + 1), mimeType: "image/png" }] })),
  );
  await using _host = host;

  const large = await session.call("attach", { paths: ["fits.png", "large.png"] });
  const bytes = await session.call("large", {});
  const fits = await session.call("attach", { paths: ["fits.png"] });

  equal(
    [large.isError, large.text, bytes.isError, bytes.text],
    [
      true,
      `large.png: the media is larger than the limit of ${LIMIT} bytes`,
      true,
      `the media is larger than the limit of ${LIMIT} bytes`,
    ],
  );
  equal([fits.isError, fits.media[0]?.size], [false, LIMIT]);
});

test("a result of another shape is an error that names the problem", async () => {
  const shapes: unknown[] = [
    5,
    { output: "x" },
    { text: 1 },
    { text: "x", isError: "yes" },
    { text: "x", media: {} },
    { text: "x", media: [{ mimeType: "image/png" }] },
    { text: "x", media: [{ mimeType: "image/png", path: "a", bytes: new Uint8Array(1) }] },
    { text: "x", media: [{ mimeType: "image/png", bytes: Object.create(Uint8Array.prototype) }] },
    { text: "x", media: [{ mimeType: "image/png", path: 5 }] },
    { text: "x", media: [{ mimeType: 5, path: "a" }] },
    Object.defineProperty({ text: "x" }, "hidden", { value: 1 }),
    { text: "x", [Symbol("tag")]: 1 },
    Object.create({ text: "x" }),
    { text: "x", media: null },
    { text: "x", media: [{ mimeType: "image/png", path: "a", bytes: undefined }] },
    // biome-ignore lint/suspicious/noSparseArray: a hole in the media list is the case under test.
    { text: "x", media: [, { mimeType: "image/png", path: "a" }] },
    { text: "x", display: {} },
    { text: "x", display: [{ kind: "html", text: "a" }] },
    { text: "x", display: [{ kind: "diff", path: "a" }] },
    { text: "x", display: [{ kind: "markdown", text: "a", path: "b" }] },
  ];
  const shape = {
    name: "shape",
    description: "d",
    concurrency: "serial",
    parameters: { type: "object", properties: { index: { type: "integer" } }, required: ["index"] },
    execute: (args: { index: number }) => shapes[args.index],
  } as unknown as Tool;
  const { host, session } = await opened(shape);
  await using _host = host;

  const errors = [];
  for (let index = 0; index < shapes.length; index += 1) {
    const result = await session.call("shape", { index });
    errors.push(result.isError ? result.text : `no error: ${result.text}`);
  }

  equal(errors, [
    "the result is not an object",
    "the result has the unknown field 'output'",
    "the result text is not a string",
    "the result isError is not a boolean",
    "the result media is not an array",
    "the result media[0] needs exactly one of path and bytes",
    "the result media[0] needs exactly one of path and bytes",
    "the result media[0].bytes is not a Uint8Array",
    "the result media[0].path is not a string",
    "the result media[0].mimeType is not a string",
    "the result has the unknown field 'hidden'",
    "the result has a symbol key",
    "the result text is not a string",
    "the result media is not an array",
    "the result media[0] needs exactly one of path and bytes",
    "the result media[0] is not an object",
    "the result display is not an array",
    "the result display[0].kind is not 'markdown' or 'diff'",
    "the result display[0].patch is not a string",
    "the result display[0] has the unknown field 'path'",
  ]);
});

// The answer commit saves the hints and the folder before the call runs, so the saved transcript shows them too.
test("a call in a turn shows the hints of its tool, the folder of the session, and the display of its result", async () => {
  const show = {
    ...tool("show", () => ({ text: "ok", display: [{ kind: "markdown", text: "*a*" }] })),
    parameters: { type: "object", properties: { path: { type: "string" } } },
    hints: { title: "Show", subject: { argument: "path", kind: "file" }, preview: "tail" },
  } as unknown as Tool;
  await using host = await createHost({
    plugins: [{ name: "tools", session: defining(show) }],
    replies: [reply.toolCall("show", { path: "a.md" }), reply.text("done")],
  });
  const session = await host.openSession();

  await session.send("show it");

  const entry = session.transcript.entries.find((item) => item.kind === "tool");
  equal(entry?.kind === "tool" && [entry.hints, entry.folder, entry.result?.content, entry.display], [
    { title: "Show", subject: { argument: "path", kind: "file" }, preview: "tail" },
    folder(),
    "ok",
    [{ kind: "markdown", text: "*a*" }],
  ]);
});

test("a media path starts in the folder of the start of the call", async () => {
  await mkdir(`${folder()}/first`);
  await mkdir(`${folder()}/second`);
  await writeTextFile(`${folder()}/first/dot.png`, "first");
  await writeTextFile(`${folder()}/second/dot.png`, "second");
  let release = (): void => {};
  const { host, session } = await opened(
    tool(
      "later",
      () =>
        new Promise((resolve) => {
          release = () => resolve({ text: "x", media: [{ path: "dot.png", mimeType: "image/png" }] });
        }),
    ),
  );
  await using _host = host;
  await session.setSettings({ ...session.settings, cwd: `${folder()}/first` });

  const pending = session.call("later", {});
  await new Promise((resolve) => setTimeout(resolve, 20));
  await session.setSettings({ ...session.settings, cwd: `${folder()}/second` });
  release();

  equal(plain((await pending).media), [["image/png", [...new TextEncoder().encode("first")]]]);
});
