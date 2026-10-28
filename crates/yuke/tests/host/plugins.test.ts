// The plugin loader: the context of `apply`, the exports, the services, the options, and the failures.

import { mkdir, stat, writeTextFile } from "yuke:fs";
import type { PluginApply, PluginSession } from "yuke:plugins";
import { createHost, equal, folder, rejects, test } from "yuke:test";

/** The lines of a rejected `createHost` that name a failed plugin, in load order. Other lines are stacks. */
async function failures(host: Promise<unknown>): Promise<string[]> {
  const error = await rejects(host);
  const message = error instanceof Error ? error.message : String(error);
  return message.split("\n").filter((line) => line.startsWith("plugin "));
}

/**
 * Write the manifest of the plugin `name` with the `sh.yuke` fields `fields` to a folder of the test. With `source`,
 * the plugin gets the entry `index.ts` with that code.
 */
async function writePlugin(name: string, fields: Record<string, unknown>, source?: string): Promise<string> {
  const root = `${folder()}/${name}`;
  await mkdir(root);
  const entry = source === undefined ? {} : { entry: "index.ts" };
  await writeTextFile("plugin.json", JSON.stringify({ name, extensions: { "sh.yuke": { ...entry, ...fields } } }), {
    baseDir: root,
  });
  if (source !== undefined) await writeTextFile("index.ts", source, { baseDir: root });
  return root;
}

test("a folder plugin loads through its manifest, and its options pass its schema", async () => {
  const root = await writePlugin(
    "greeter",
    {},
    `export const optionsSchema = { type: "object", properties: { word: { type: "string" } } };
     export function apply(ctx) { ctx.notify("info", ctx.options.word); }`,
  );

  await using host = await createHost({ plugins: [{ folder: root, options: { word: "loaded" } }] });

  equal(
    host.notices.map((notice) => notice.message),
    ["loaded"],
  );
});

declare module "yuke:plugins" {
  interface Services {
    "test.words.v1": { readonly word: string };
    "test.counts.v1": { readonly count: number };
  }
}

test("a given plugin uses a service from an earlier folder plugin", async () => {
  const root = await writePlugin(
    "words",
    { provides: ["test.words.v1"] },
    `export function apply(ctx) { ctx.provide("test.words.v1", { word: "shared" }); }`,
  );
  const reader: PluginApply = (ctx) => {
    ctx.notify("info", ctx.get("test.words.v1").word);
    return undefined;
  };

  await using host = await createHost({
    plugins: [{ folder: root }, { name: "reader", apply: reader, uses: ["test.words.v1"] }],
  });

  equal(
    host.notices.map((notice) => [notice.source, notice.message]),
    [["reader", "shared"]],
  );
});

test("a list with a folder plugin and a given plugin of the same name rejects the host", async () => {
  const root = await writePlugin("twin", {}, "export function apply() {}");

  const error = await rejects(createHost({ plugins: [{ folder: root }, { name: "twin" }] }));

  equal(error instanceof Error ? error.message : error, "plugin twin: another plugin of the list has this name");
});

test("a given plugin before its folder provider rejects the host", async () => {
  const root = await writePlugin("words", { provides: ["test.words.v1"] }, "export function apply() {}");

  const error = await rejects(createHost({ plugins: [{ name: "reader", uses: ["test.words.v1"] }, { folder: root }] }));

  equal(
    error instanceof Error ? error.message : error,
    "plugin reader: it uses 'test.words.v1', and plugin words provides it later in the list",
  );
});

test("a folder plugin reads a file beside its module through import.meta", async () => {
  const root = await writePlugin(
    "prompted",
    {},
    `import { readTextFile } from "yuke:fs";
     export const session = (s) => {
       s.tools.define({
         name: "prompt",
         description: "Read the prompt.",
         concurrency: "serial",
         parameters: { type: "object", properties: {} },
         execute: () => readTextFile("prompt.md", { baseDir: import.meta.dirname }),
       });
     };`,
  );
  await writeTextFile("prompt.md", "Be brief.", { baseDir: root });
  await using host = await createHost({ plugins: [{ folder: root }] });
  const session = await host.openSession();

  equal((await session.call("prompt", {})).text, "Be brief.");
});

test("apply runs once with its context, and session runs for each session", async () => {
  let applied = 0;
  let seen: unknown[] = [];
  let dataDir = "";
  const sessions: string[] = [];
  const apply: PluginApply = (ctx) => {
    applied += 1;
    const signal = ctx.signal;
    // A plugin cannot abort the signal of its context: it has no `abort`, and a dispatched event does not abort it.
    const aborts = ["abort" in signal, signal.dispatchEvent(new Event("abort")), signal.aborted];
    seen = [
      ctx.name,
      "root" in ctx,
      ctx.dataDir.endsWith("/data/plugins/one"),
      aborts,
      "tools" in ctx,
      String(ctx.get("tui")),
    ];
    dataDir = ctx.dataDir;
    return undefined;
  };
  globalThis.applyOfOne = apply;
  globalThis.sessionOfOne = (s: Parameters<PluginSession>[0]) => {
    sessions.push(s.folder);
    s.tools.define({
      name: "hello",
      description: "Say hello.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: () => "hello",
    });
  };
  const root = await writePlugin(
    "one",
    {},
    "export const apply = (ctx) => globalThis.applyOfOne(ctx); export const session = (s) => globalThis.sessionOfOne(s);",
  );
  await mkdir(`${folder()}/a`);
  await mkdir(`${folder()}/b`);
  await using host = await createHost({ plugins: [{ folder: root }] });

  const first = await host.openSession({ cwd: `${folder()}/a` });
  const second = await host.openSession({ cwd: `${folder()}/b` });

  equal([(await first.call("hello", {})).text, (await second.call("hello", {})).text], ["hello", "hello"]);
  equal(seen, ["one", false, true, [false, true, false], false, "undefined"]);
  equal([applied, (await stat(dataDir)).isDirectory], [1, true]);
  equal(sessions, [`${folder()}/a`, `${folder()}/b`]);
});

declare global {
  // The folder plugin of the first test reaches its code through these globals.
  var applyOfOne: PluginApply;
  var sessionOfOne: PluginSession;
}

test("the close aborts each signal, then awaits each cleanup newest first, once", async () => {
  const events: string[] = [];
  const signals: AbortSignal[] = [];
  const one: PluginApply = (ctx) => {
    signals.push(ctx.signal);
    return async () => {
      await new Promise((resolve) => setTimeout(resolve, 10));
      events.push("one");
    };
  };
  const two: PluginApply = async (ctx) => {
    signals.push(ctx.signal);
    return () => {
      events.push(`two ${signals.map((signal) => signal.aborted)}`);
    };
  };
  const three: PluginApply = (ctx) => {
    signals.push(ctx.signal);
    return () => {
      events.push("three");
      throw Object.create(null);
    };
  };
  const host = await createHost({
    plugins: [
      { name: "one", apply: one },
      { name: "two", apply: two },
      { name: "three", apply: three },
    ],
  });

  await host.close();
  await host.close();

  equal(events, ["three", "two true,true,true", "one"]);
  equal(
    host.notices.map((notice) => [notice.source, notice.level, notice.message]),
    [["three", "error", "the cleanup of the plugin failed: a value without a text form"]],
  );
});

test("a plugin that fails after its apply returned runs its cleanup once", async () => {
  const cleanups: boolean[] = [];
  const silent: PluginApply = (ctx) => () => {
    cleanups.push(ctx.signal.aborted);
  };

  equal(await failures(createHost({ plugins: [{ name: "silent", apply: silent, provides: ["a"] }] })), [
    "plugin silent did not load: TypeError: apply did not provide a of provides",
  ]);
  equal(cleanups, [true]);
});

test("a service passes to a later plugin, and a failed provider stops its users before they run", async () => {
  let count = 0;
  let ran = false;
  const host = createHost({
    plugins: [
      {
        name: "notes",
        provides: ["test.counts.v1"],
        apply: (ctx) => {
          ctx.provide("test.counts.v1", { count: 3 });
          return undefined;
        },
      },
      {
        name: "reader",
        uses: ["test.counts.v1"],
        apply: (ctx) => {
          count = ctx.get("test.counts.v1").count;
          return undefined;
        },
      },
      {
        name: "broken",
        provides: ["test.store.v1"],
        apply: () => {
          throw new Error("no store");
        },
      },
      {
        name: "middle",
        uses: ["test.store.v1"],
        provides: ["test.index.v1"],
        apply: () => {
          ran = true;
          return undefined;
        },
      },
      {
        name: "last",
        uses: ["test.index.v1"],
        apply: () => {
          ran = true;
          return undefined;
        },
      },
    ],
  });

  equal(await failures(host), [
    "plugin broken did not load: Error: no store",
    "plugin middle did not load: it uses 'test.store.v1', and plugin broken that provides it did not load",
    "plugin last did not load: it uses 'test.index.v1', and plugin middle that provides it did not load",
  ]);
  equal([count, ran], [3, false]);
});

test("the context refuses undeclared services, and apply must provide each declared one", async () => {
  const neither = await writePlugin("neither", {}, "export default function apply() {}");
  const host = createHost({
    plugins: [
      { name: "silent", provides: ["test.a.v1"], apply: () => undefined },
      {
        name: "reach",
        apply: (ctx) => {
          ctx.get("test.z.v1" as never);
          return undefined;
        },
      },
      {
        name: "other",
        provides: ["test.b.v1"],
        apply: (ctx) => {
          ctx.provide("test.c.v1" as never, 1 as never);
          return undefined;
        },
      },
      { name: "value", apply: (() => 5) as never },
      { folder: neither },
      { name: "number", session: 5 as never },
    ],
  });

  equal(await failures(host), [
    "plugin silent did not load: TypeError: apply did not provide test.a.v1 of provides",
    "plugin reach did not load: TypeError: get: plugin reach has no 'test.z.v1' in uses",
    "plugin other did not load: TypeError: provide: plugin other has no 'test.c.v1' in provides",
    "plugin value did not load: TypeError: apply must return nothing or a cleanup function",
    `plugin neither did not load: TypeError: ${neither}/index.ts exports neither apply nor session: a plugin entry exports one or both`,
    "plugin number did not load: TypeError: the session export is no function",
  ]);
});

test("a plugin needs no code, and yuke:tools gives no free define", async () => {
  const empty = await writePlugin("empty", {});
  await using host = await createHost({ plugins: [{ folder: empty }] });

  await writeTextFile(`${folder()}/late.ts`, 'import { define } from "yuke:tools";\ndefine;\n');

  const error = await rejects(import(`${folder()}/late.ts`));

  equal(host.notices, []);
  equal(
    [error instanceof Error && error.name, error instanceof Error && error.message.includes("'define'")],
    ["SyntaxError", true],
  );
});

test("notify sends a notice of the plugin and refuses an unknown level", async () => {
  let refused = "";
  const loud: PluginApply = (ctx) => {
    ctx.notify("warn", "careful");
    try {
      ctx.notify("loud" as never, "x");
    } catch (error) {
      refused = error instanceof Error ? error.message : String(error);
    }
    return undefined;
  };
  await using host = await createHost({ plugins: [{ name: "loud", apply: loud }] });

  equal(host.notices, [{ level: "warn", source: "loud", message: "careful" }]);
  equal(refused, "notify: 'loud' is not debug, info, warn, or error");
});

test("emit sends an event with the plugin as its extension and its data as JSON", async () => {
  const todo: PluginApply = (ctx) => {
    ctx.emit("changed", { version: 1, items: ["milk"] });
    ctx.emit("cleared");
    return undefined;
  };
  await using host = await createHost({ plugins: [{ name: "todo", apply: todo }] });

  equal(host.events, [
    { extension: "todo", event: "changed", data: { version: 1, items: ["milk"] } },
    { extension: "todo", event: "cleared", data: null },
  ]);
});

/** The options schema of the test plugins: one required string and two optional fields. */
const notesSchema = {
  type: "object",
  properties: {
    folder: { type: "string" },
    depth: { type: "integer", minimum: 1 },
    tags: { type: "array", items: { type: "string" } },
  },
  required: ["folder"],
} as const;

test("the checked options reach apply and each session as one frozen object", async () => {
  let applied: unknown;
  const sessions: unknown[] = [];
  let plain: unknown;
  await using host = await createHost({
    plugins: [
      {
        name: "notes",
        optionsSchema: notesSchema,
        options: { folder: "~/notes", depth: null, tags: ["a"] },
        apply: (ctx) => {
          applied = ctx.options;
          return undefined;
        },
        session: (s) => {
          sessions.push(s.options);
        },
      },
      {
        name: "plain",
        session: (s) => {
          plain = s.options;
        },
      },
    ],
  });

  await host.openSession();
  await host.openSession();

  const tags = (applied as { tags: unknown }).tags;
  equal(JSON.stringify(applied), '{"folder":"~/notes","tags":["a"]}');
  equal(
    [
      sessions.length,
      sessions.every((options) => options === applied),
      Object.isFrozen(applied),
      Object.isFrozen(tags),
    ],
    [2, true, true, true],
  );
  equal([JSON.stringify(plain), Object.isFrozen(plain)], ["{}", true]);
});

test("options that fail the check fail the load of that plugin before its apply", async () => {
  const applied: string[] = [];
  const checked = (name: string, options?: Record<string, unknown>) => ({
    name,
    optionsSchema: notesSchema,
    ...(options === undefined ? {} : { options }),
    apply: () => {
      applied.push(name);
      return undefined;
    },
  });
  const codeless = await writePlugin("codeless", {});
  const host = createHost({
    plugins: [
      checked("missing"),
      checked("wrong", { folder: "x", depth: 0 }),
      checked("extra", { folder: "x", colour: "red" }),
      { name: "unasked", options: { a: 1 }, apply: () => undefined },
      { folder: codeless, options: { a: 1 } },
      {
        name: "unchecked",
        optionsSchema: { type: "object", properties: { a: { type: "string", default: "b" } } } as never,
        apply: () => undefined,
      },
      checked("good", { folder: "x" }),
    ],
  });

  const failure = (name: string, text: string) => `plugin ${name} did not load: TypeError: ${text}`;
  equal(await failures(host), [
    failure("missing", "the options of the plugin: Set folder to a string."),
    failure("wrong", "the options of the plugin: Set depth to an integer of at least 1."),
    failure("extra", "the options of the plugin: Remove colour. The fields are: folder, depth, tags."),
    failure("unasked", "the plugin gets options, and it exports no optionsSchema"),
    failure("codeless", "the plugin gets options, and it exports no optionsSchema"),
    failure("unchecked", "optionsSchema.properties.a: yuke does not check the keyword 'default'"),
  ]);
  equal(applied, ["good"]);
});

// The given exports pass the same checks as an entry: the options schema, the frozen options, and the export shape.
test("given exports load through the checks of an entry", async () => {
  let seen: unknown[] = [];
  const host = createHost({
    plugins: [
      {
        name: "fine",
        optionsSchema: { type: "object", properties: { depth: { type: "number" } } },
        options: { depth: 2 },
        apply: (ctx) => {
          seen = [ctx.options.depth, Object.isFrozen(ctx.options), "root" in ctx];
          return undefined;
        },
      },
      { name: "empty" },
      { name: "unchecked", options: { depth: 2 }, apply: () => undefined },
      { name: "broken", apply: 1 as never },
    ],
  });

  equal(await failures(host), [
    "plugin empty did not load: TypeError: the given exports of plugin empty hold neither apply nor session",
    "plugin unchecked did not load: TypeError: the plugin gets options, and it exports no optionsSchema",
    "plugin broken did not load: TypeError: the apply export is no function",
  ]);
  equal(seen, [2, true, false]);
});
