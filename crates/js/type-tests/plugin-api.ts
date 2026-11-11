// Type checks of the author API. `tsc -p crates/js/tsconfig.json` runs them; nothing executes this file.

import type { GenerateTextOptions } from "yuke:ai";
import type {
  Catalog,
  Frozen,
  PluginApply,
  PluginContext,
  PluginSession,
  PromptBuildAnswer,
  PromptBuildEvent,
  RoundAfterAnswer,
  RoundBeforeAnswer,
  SessionContext,
  Sessions,
  ToolAfterAnswer,
  ToolBeforeAnswer,
  ToolBeforeEvent,
  ToolCall,
  ToolCallResult,
} from "yuke:plugins";
import type { Block, FinishReason } from "yuke:protocol";
import type { Infer, ObjectSchema, ToolResult } from "yuke:tools";

/** `true` only when `A` and `B` are the same type. */
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;

/** A call that compiles only for `true`. */
declare function assert<T extends true>(): void;

declare const ctx: PluginContext;
declare const s: SessionContext;

declare module "yuke:plugins" {
  interface Services {
    "test.notes.v1": { readonly count: () => number };
  }
}

// An inline schema needs no `as const`. A required field is required, another is optional, and nested types follow.
s.tools.add({
  name: "summarize",
  description: "d",
  concurrency: "parallel",
  parameters: {
    type: "object",
    properties: {
      path: { type: "string" },
      entries: {
        type: "array",
        items: {
          type: "object",
          properties: { name: { type: "string" }, score: { type: "number" } },
          required: ["name"],
        },
      },
      options: {
        type: "object",
        properties: { enabled: { type: "boolean" }, count: { type: "integer", minimum: 1 } },
        required: ["enabled"],
      },
    },
    required: ["path", "entries"],
  },
  execute(args) {
    assert<
      Equal<
        typeof args,
        { path: string; entries: { name: string; score?: number }[]; options?: { enabled: boolean; count?: number } }
      >
    >();
    // @ts-expect-error: the schema has no field `missing`.
    args.missing;
    return "";
  },
});

// A schema constant keeps its types with `as const satisfies ObjectSchema`.
const counted = {
  type: "object",
  properties: { n: { type: "integer" } },
  required: ["n"],
} as const satisfies ObjectSchema;
assert<Equal<Infer<typeof counted>, { n: number }>>();

// A schema typed as `ObjectSchema` has lost its fields, and a `required` of type `string[]` makes no field required.
assert<Equal<Infer<ObjectSchema>, Record<string, unknown>>>();
const widened: { type: "object"; properties: { n: { type: "integer" } }; required: string[] } = {
  type: "object",
  properties: { n: { type: "integer" } },
  required: ["n"],
};
assert<Equal<Infer<typeof widened>, { n?: number }>>();

// A scalar schema with a union of types gives the union of values.
assert<
  Equal<
    Infer<{ type: "object"; properties: { flag: { type: "string" | "boolean" } }; required: ["flag"] }>,
    { flag: string | boolean }
  >
>();

// An inline `enum` gives the union of its values, and a list typed as `string[]` gives `string`.
s.tools.add({
  name: "sort",
  description: "d",
  concurrency: "parallel",
  parameters: {
    type: "object",
    properties: { order: { type: "string", enum: ["asc", "desc"] }, size: { type: "integer", enum: [1, 2] } },
    required: ["order"],
  },
  execute(args) {
    assert<Equal<typeof args, { order: "asc" | "desc"; size?: 1 | 2 }>>();
    return "";
  },
});
assert<
  Equal<
    Infer<{ type: "object"; properties: { order: { type: "string"; enum: string[] } }; required: ["order"] }>,
    {
      order: string;
    }
  >
>();
// @ts-expect-error: a boolean takes no `enum`.
const booleanEnum: ObjectSchema = { type: "object", properties: { flag: { type: "boolean", enum: [true] } } };
// @ts-expect-error: the values of an `enum` have the type of the schema.
const numberInStringEnum: ObjectSchema = { type: "object", properties: { order: { type: "string", enum: [1] } } };
void [booleanEnum, numberInStringEnum];

// A result is a string, or text with media and an error flag. A media file has a path or bytes, never both.
const results: ToolResult[] = [
  "done",
  { text: "", media: [{ mimeType: "image/png", bytes: new Uint8Array(1) }], isError: true },
  { text: "x", media: [{ mimeType: "image/png", path: "a.png" }] },
  // @ts-expect-error: a result names its text `text`.
  { output: "x" },
  // @ts-expect-error: a media file has one source.
  { text: "x", media: [{ mimeType: "image/png", path: "a.png", bytes: new Uint8Array(1) }] },
];

// Model tools belong to a session, and services to the process. A notice of the process names no session.
// @ts-expect-error: the process context defines no tool.
ctx.tools;
// @ts-expect-error: a notice of the process takes no session id.
ctx.notify("info", "x", "session");
// @ts-expect-error: a session publishes no service.
s.provide;
s.notify("info", "x");

// `session` and `apply` return nothing, a cleanup, or a promise of either.
const session: PluginSession = async (scope) => {
  void scope.sessionId;
  return async () => {};
};
// @ts-expect-error: a cleanup is a function.
const valued: PluginSession = () => 5;
const plain: PluginSession = async (scope) => {
  await Promise.resolve(scope.cwd);
};
const quiet: PluginSession = (scope) => {
  scope.notify("info", "x");
};
const apply: PluginApply = () => {};
const cleaned: PluginApply = async (context) => {
  void context.signal;
  return () => {};
};
// @ts-expect-error: a cleanup is a function.
const valuedApply: PluginApply = () => 5;
void [session, valued, plain, quiet, apply, cleaned, valuedApply];

// A service name must come from a declaration of `Services`, and its value must not be null.
assert<Equal<ReturnType<typeof ctx.get<"test.notes.v1">>, { readonly count: () => number }>>();
ctx.provide("test.notes.v1", { count: () => 1 });
// @ts-expect-error: no declaration adds this service.
ctx.get("test.unknown.v1");
// @ts-expect-error: a service value is not null.
ctx.provide("test.notes.v1", null);

// The sessions and the catalog of yuke are services that are never undefined, in each mode.
assert<Equal<ReturnType<typeof ctx.get<"sessions">>, Sessions>>();
assert<Equal<ReturnType<typeof ctx.get<"catalog">>, Catalog>>();
// @ts-expect-error: the credentials are no service of the plugins.
ctx.get("auth");
// @ts-expect-error: no plugin provides a service of yuke.
ctx.provide("catalog", { list: async () => ({ providers: [] }) });
export async function drive(sessions: Sessions): Promise<void> {
  const handle = await sessions.open("id", { tail: 50, onEvent: (event) => void event });
  await handle.sendMessage({ content: [{ user_text: "hi" }] });
  // @ts-expect-error: an input holds blocks, not a text.
  await handle.sendMessage("hi");
  // @ts-expect-error: the snapshot needs a tail.
  await sessions.open("id", { onEvent: () => undefined });
  // @ts-expect-error: the callback is `onEvent`.
  await sessions.open("id", { tail: 0, event: () => undefined });
  // A close ends this hold only, and `using` closes the handle too. `sessions.closeForAll` closes the session for each holder.
  handle.close();
  {
    using held = await sessions.open("id", { tail: 0, onEvent: () => undefined });
    void held.id;
  }
  await sessions.closeForAll(handle.id);
}

// `yuke:fs` takes a base folder and a signal, and its failure has a code.
async function files(): Promise<void> {
  const fs = await import("yuke:fs");
  const text: string = await fs.readTextFile("state.json", { cwd: ctx.dataDir, signal: ctx.signal });
  const bytes: Uint8Array = await fs.readFile("data.bin", { cwd: ctx.dataDir, position: 0, length: 4 });
  // A module finds the files beside it through `import.meta`. A built-in module has no folder.
  const here: string | undefined = import.meta.dirname;
  // @ts-expect-error: `dirname` can be undefined.
  const folder: string = import.meta.dirname;
  const url: string = import.meta.url;
  const info: Date | null = (await fs.stat("prompt.md", { cwd: here ?? ctx.dataDir })).mtime;
  await fs.writeTextFile("state.json", text, { cwd: ctx.dataDir, atomic: true, mode: 0o600 });
  // @ts-expect-error: the data of `writeFile` is bytes.
  await fs.writeFile("data.bin", "text", { cwd: ctx.dataDir });
  void bytes;
  void info;
  void folder;
  void url;
}
void files;

// `yuke:process` runs a program in a required folder, and its output is bytes.
async function programs(): Promise<void> {
  const { Command } = await import("yuke:process");
  const out = await new Command("git", { args: ["status"], cwd: ctx.dataDir, signal: ctx.signal }).output();
  const ok: boolean = out.success;
  const stdout: Uint8Array = out.stdout;
  const signal: string | null = out.signal;
  // @ts-expect-error: a command needs its folder.
  new Command("git", { args: ["status"] });
  // @ts-expect-error: the output of a program never goes to the terminal of yuke.
  new Command("git", { cwd: ctx.dataDir, stdout: "inherit" });
  void ok;
  void stdout;
  void signal;
}
void programs;

// `yuke:net` connects to a Unix socket, its stream gives bytes, and its failure narrows to a code.
async function sockets(): Promise<void> {
  const { connect, ConnectionError } = await import("yuke:net");
  try {
    using connection = await connect({ path: "/tmp/h.sock", signal: ctx.signal });
    await connection.write(new TextEncoder().encode("ping\n"));
    for await (const chunk of connection.readable) {
      const bytes: Uint8Array = chunk;
      void bytes;
    }
  } catch (error) {
    const code: string | undefined = error instanceof ConnectionError ? error.code : undefined;
    void code;
  }
  // @ts-expect-error: a write takes bytes.
  await (await connect({ path: "/tmp/h.sock" })).write("ping");
}
void sockets;

// `yuke:ai` needs a model, takes a text or blocks, and its answer has the finish reason and the usage.
async function models(): Promise<void> {
  const { generateText } = await import("yuke:ai");
  const prompt: Block[] = [{ user_text: "Hi." }];
  const answer = await generateText({ model: s.settings.model, prompt, maxOutputTokens: 100, signal: s.signal });
  await generateText({ model: s.settings.model, instructions: "Be brief.", prompt: "Hi." });
  await generateText({ model: s.settings.model, prompt: "Hi.", reasoning: { effort: "high" } });
  await generateText({
    model: s.settings.model,
    prompt: "Describe.",
    attachments: [
      { mimeType: "image/png", bytes: new Uint8Array() },
      { mimeType: "image/png", path: "/tmp/shot.png" },
    ],
  });
  // @ts-expect-error: an attachment holds bytes or a path.
  await generateText({ model: s.settings.model, prompt: "Describe.", attachments: [{ mimeType: "image/png" }] });
  const text: string = answer.text;
  assert<Equal<typeof answer.finishReason, FinishReason>>();
  const input: number | null = answer.usage.input;
  // @ts-expect-error: a request names its model.
  await generateText({ prompt });
  // @ts-expect-error: a setting has its type.
  await generateText({ model: s.settings.model, prompt, temperature: "hot" });
  assert<Equal<typeof answer.output, undefined>>();
  const { Output, NoObjectGeneratedError } = await import("yuke:ai");
  const schema = {
    type: "object",
    properties: { summary: { type: "string" }, count: { type: "integer" } },
    required: ["summary"],
  } as const;
  const shaped = await generateText({ model: s.settings.model, prompt, output: Output.object({ schema }) });
  assert<Equal<typeof shaped.output, { summary: string; count?: number }>>();
  // Options of the wide type can hold an output, so the checked object has no known type.
  const wide: GenerateTextOptions = { model: s.settings.model, prompt, output: Output.object({ schema }) };
  const unknownOutput = await generateText(wide);
  assert<Equal<typeof unknownOutput.output, unknown>>();
  // @ts-expect-error: an output schema is an object schema.
  Output.object({ schema: { type: "string" } });
  // @ts-expect-error: only `Output.object` gives the type of `output`.
  await generateText<{ summary: string }>({ model: s.settings.model, prompt });
  // @ts-expect-error: only `Output.object` makes an output.
  await generateText({ model: s.settings.model, prompt, output: { schema, name: "response" } });
  const failure: unknown = undefined;
  if (failure instanceof NoObjectGeneratedError) {
    const kept: string = failure.text;
    void kept;
  }
  void text;
  void input;
}
void models;

export { results };

// A `prompt.build` handler gets the sections, and answers new sections or nothing.
const remove: () => void = s.addHook("prompt.build", (event) => {
  assert<Equal<typeof event, PromptBuildEvent>>();
  assert<Equal<typeof event.sections, Readonly<Record<string, string>>>>();
  // @ts-expect-error: a handler changes the sections through its answer.
  event.sections.rules = "Be brief.";
  return { sections: { ...event.sections, rules: "Be brief." } };
});
remove();
s.addHook("prompt.build", async ({ sections }): Promise<PromptBuildAnswer> => {
  await Promise.resolve();
  const { environment: _, ...rest } = sections;
  return { sections: rest };
});
// @ts-expect-error: an answer is an object.
s.addHook("prompt.build", () => "done");
// @ts-expect-error: an input answer has one decision.
s.addHook("input.before", () => ({ handled: true as const, deny: "no" }));
// @ts-expect-error: no hook has this point.
s.addHook("turn.start", () => undefined);

// A `tool.before` handler gets the call and denies it with a reason, or returns nothing.
s.addHook("tool.before", (event) => {
  assert<Equal<typeof event, ToolBeforeEvent>>();
  assert<Equal<typeof event.call, ToolCall>>();
  assert<Equal<typeof event.call.arguments, unknown>>();
  // @ts-expect-error: the call belongs to the model.
  event.call.name = "write";
  if (event.call.name === "exec") return { deny: "exec needs the user" };
  return undefined;
});
s.addHook("tool.before", async ({ call }): Promise<ToolBeforeAnswer | undefined> => {
  await Promise.resolve();
  return call.callId === "" ? { deny: "no id" } : undefined;
});
// @ts-expect-error: a denial names its reason as a string.
s.addHook("tool.before", () => ({ deny: true }));

// A `tool.after` handler gets the call and the result, and answers the changed fields or nothing.
s.addHook("tool.after", ({ call, result }) => {
  assert<Equal<typeof result, ToolCallResult>>();
  // @ts-expect-error: a handler changes the result through its answer.
  result.text = "";
  if (call.name !== "read") return undefined;
  return {
    text: result.text.slice(0, 100),
    media: [...result.media.slice(1), { mimeType: "image/png", path: "a.png" }],
  };
});
s.addHook("tool.after", async (): Promise<ToolAfterAnswer | undefined> => {
  await Promise.resolve();
  return { isError: true };
});
// An optional field takes `undefined` as missing, as the runtime does.
declare const maybe: boolean | undefined;
s.addHook("tool.after", () => ({ text: undefined, isError: maybe, media: undefined }));
s.addHook("tool.after", ({ result }) => ({
  media: [{ id: "0", mimeType: undefined, size: undefined }, ...result.media],
}));
s.tools.add({
  name: "maybe",
  description: "d",
  concurrency: "serial",
  deferLoading: maybe,
  parameters: { type: "object", properties: {} },
  execute: () => ({ text: "x", isError: maybe, media: undefined }),
});
// A copy of an item keeps it, and so does its id alone.
s.addHook("tool.after", ({ result }) => ({ media: [...result.media.map((item) => ({ ...item })), { id: "ab" }] }));
// @ts-expect-error: an answer has no field outside text, isError, and media.
s.addHook("tool.after", () => ({ content: "x" }));
const mixed = { id: "ab", mimeType: "image/png", bytes: new Uint8Array() };
// @ts-expect-error: an item with an id keeps an item, so it has no path or bytes.
s.addHook("tool.after", () => ({ media: [mixed] }));
// @ts-expect-error: a new media item needs a path or bytes.
s.addHook("tool.after", () => ({ media: [{ mimeType: "image/png" }] }));

// A round.before handler reads the context window and the tokens, and answers a summary of the old blocks.
s.addHook("round.before", (event): RoundBeforeAnswer | undefined => {
  const window = event.contextWindow;
  if (window === null || event.contextTokens < window * 0.8) return undefined;
  const tokens: number[] = event.blockTokens();
  const count: number = event.blockCount;
  const summary: Block = { user_text: `${event.blocks().length} of ${count} blocks, ${tokens.length} estimates.` };
  return { replace: { head: [summary], keep: 4 }, settings: { temperature: 0 } };
});
// @ts-expect-error: a block holds one known kind.
s.addHook("round.before", () => ({ replace: { head: [{ text: "x" }], keep: 0 } }));
// @ts-expect-error: a model names its provider and its model.
s.addHook("round.before", () => ({ model: { model: "x" } }));

// A round.after handler reads the reason and the count, and answers a stop or a continue.
s.addHook("round.after", ({ finishReason, continues }): RoundAfterAnswer | undefined => {
  if (finishReason === null) return undefined;
  return continues < 3 ? { continue: "Run the tests." } : { stop: true };
});
// @ts-expect-error: an answer is a stop or a continue, not both.
s.addHook("round.after", () => ({ stop: true, continue: "x" }));
// @ts-expect-error: a stop is `true`.
s.addHook("round.after", () => ({ stop: false }));

// The web globals declare what the runtime has, and no more.
new TextDecoder("utf8");
new TextDecoder("utf-16le");

// The options of a plugin have the type of its `optionsSchema`, and both contexts read them.
export const optionsSchema = {
  type: "object",
  properties: {
    folder: { type: "string" },
    depth: { type: "integer" },
    tags: { type: "array", items: { type: "string" } },
  },
  required: ["folder"],
} as const satisfies ObjectSchema;
type Options = Infer<typeof optionsSchema>;
export const applyWithOptions: PluginApply<Options> = (context) => {
  assert<Equal<typeof context.options.folder, string>>();
  assert<Equal<typeof context.options.depth, number | undefined>>();
  // @ts-expect-error: the options are read-only.
  context.options.folder = "x";
  // @ts-expect-error: the nested values of the options are read-only too.
  context.options.tags?.push("x");
  return undefined;
};
export const sessionWithOptions: PluginSession<Options> = (session) => {
  assert<Equal<typeof session.options, Frozen<Options>>>();
  return undefined;
};
// @ts-expect-error: a plugin without options has no option field.
export const noOption: string = ctx.options.folder;

// Each definition and each name removal has its own disposer.
assert<Equal<ReturnType<SessionContext["tools"]["add"]>, () => void>>();
assert<Equal<ReturnType<SessionContext["tools"]["remove"]>, () => void>>();
s.tools.remove("read");
// @ts-expect-error A tool name is a string.
s.tools.remove(1);
