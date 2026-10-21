// Type checks of the author API. `tsc -p crates/js/tsconfig.json` runs them; nothing executes this file.
import type {
  PluginApply,
  PluginContext,
  PluginSession,
  PromptBuildAnswer,
  PromptBuildEvent,
  RoundAfterAnswer,
  SessionContext,
  ToolAfterAnswer,
  ToolBeforeAnswer,
  ToolBeforeEvent,
  ToolCall,
  ToolCallResult,
} from "yuke:plugins";
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
s.tools.define({
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
s.tools.define({
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

// `session` returns nothing, a cleanup, or a promise of either. `apply` returns nothing.
const session: PluginSession = async (scope) => {
  void scope.sessionId;
  return async () => {};
};
// @ts-expect-error: a cleanup is a function.
const valued: PluginSession = () => 5;
const plain: PluginSession = async (scope) => {
  await Promise.resolve(scope.folder);
};
const quiet: PluginSession = (scope) => {
  scope.notify("info", "x");
};
const apply: PluginApply = () => {};
// @ts-expect-error: `apply` returns nothing.
const valuedApply: PluginApply = () => 5;
void [session, valued, plain, quiet, apply, valuedApply];

// A service name must come from a declaration of `Services`, and its value must not be null.
assert<Equal<ReturnType<typeof ctx.get<"test.notes.v1">>, { readonly count: () => number }>>();
ctx.provide("test.notes.v1", { count: () => 1 });
// @ts-expect-error: no declaration adds this service.
ctx.get("test.unknown.v1");
// @ts-expect-error: a service value is not null.
ctx.provide("test.notes.v1", null);

// `yuke:fs` takes a base folder and a signal, and its failure has a code.
async function files(): Promise<void> {
  const fs = await import("yuke:fs");
  const text: string = await fs.readTextFile("state.json", { baseDir: ctx.dataDir, signal: ctx.signal });
  const bytes: Uint8Array = await fs.readFile("data.bin", { baseDir: ctx.dataDir, position: 0, length: 4 });
  const info: Date | null = (await fs.stat(ctx.root)).mtime;
  await fs.writeTextFile("state.json", text, { baseDir: ctx.dataDir, atomic: true, mode: 0o600 });
  // @ts-expect-error: the data of `writeFile` is bytes.
  await fs.writeFile("data.bin", "text", { baseDir: ctx.dataDir });
  void bytes;
  void info;
}
void files;

// `yuke:process` runs a program in a required folder, and its output is bytes.
async function programs(): Promise<void> {
  const { Command } = await import("yuke:process");
  const out = await new Command("git", { args: ["status"], cwd: ctx.root, signal: ctx.signal }).output();
  const ok: boolean = out.success;
  const stdout: Uint8Array = out.stdout;
  const signal: string | null = out.signal;
  // @ts-expect-error: a command needs its folder.
  new Command("git", { args: ["status"] });
  // @ts-expect-error: the output of a program never goes to the terminal of yuke.
  new Command("git", { cwd: ctx.root, stdout: "inherit" });
  void ok;
  void stdout;
  void signal;
}
void programs;

export { results };

// A `prompt.build` handler gets the sections, and answers new sections or nothing.
const remove: () => void = s.hook("prompt.build", (event) => {
  assert<Equal<typeof event, PromptBuildEvent>>();
  assert<Equal<typeof event.sections, Readonly<Record<string, string>>>>();
  // @ts-expect-error: a handler changes the sections through its answer.
  event.sections.rules = "Be brief.";
  return { sections: { ...event.sections, rules: "Be brief." } };
});
remove();
s.hook("prompt.build", async ({ sections }): Promise<PromptBuildAnswer> => {
  await Promise.resolve();
  const { environment: _, ...rest } = sections;
  return { sections: rest };
});
// @ts-expect-error: an answer is an object.
s.hook("prompt.build", () => "done");
// @ts-expect-error: no hook has this point.
s.hook("turn.start", () => undefined);

// A `tool.before` handler gets the call and blocks it with a reason, or returns nothing.
s.hook("tool.before", (event) => {
  assert<Equal<typeof event, ToolBeforeEvent>>();
  assert<Equal<typeof event.call, ToolCall>>();
  assert<Equal<typeof event.call.arguments, unknown>>();
  // @ts-expect-error: the call belongs to the model.
  event.call.name = "write";
  if (event.call.name === "exec") return { block: "exec needs the user" };
  return undefined;
});
s.hook("tool.before", async ({ call }): Promise<ToolBeforeAnswer | undefined> => {
  await Promise.resolve();
  return call.id === "" ? { block: "no id" } : undefined;
});
// @ts-expect-error: a block names its reason as a string.
s.hook("tool.before", () => ({ block: true }));

// A `tool.after` handler gets the call and the result, and answers the changed fields or nothing.
s.hook("tool.after", ({ call, result }) => {
  assert<Equal<typeof result, ToolCallResult>>();
  // @ts-expect-error: a handler changes the result through its answer.
  result.text = "";
  if (call.name !== "read") return undefined;
  return {
    text: result.text.slice(0, 100),
    media: [...result.media.slice(1), { mimeType: "image/png", path: "a.png" }],
  };
});
s.hook("tool.after", async (): Promise<ToolAfterAnswer | undefined> => {
  await Promise.resolve();
  return { isError: true };
});
// An optional field takes `undefined` as missing, as the runtime does.
declare const maybe: boolean | undefined;
s.hook("tool.after", () => ({ text: undefined, isError: maybe, media: undefined }));
s.hook("tool.after", ({ result }) => ({ media: [{ id: "0", mimeType: undefined, size: undefined }, ...result.media] }));
s.tools.define({
  name: "maybe",
  description: "d",
  concurrency: "serial",
  deferLoading: maybe,
  parameters: { type: "object", properties: {} },
  execute: () => ({ text: "x", isError: maybe, media: undefined }),
});
// A copy of an item keeps it, and so does its id alone.
s.hook("tool.after", ({ result }) => ({ media: [...result.media.map((item) => ({ ...item })), { id: "ab" }] }));
// @ts-expect-error: an answer has no field outside text, isError, and media.
s.hook("tool.after", () => ({ content: "x" }));
const mixed = { id: "ab", mimeType: "image/png", bytes: new Uint8Array() };
// @ts-expect-error: an item with an id keeps an item, so it has no path or bytes.
s.hook("tool.after", () => ({ media: [mixed] }));
// @ts-expect-error: a new media item needs a path or bytes.
s.hook("tool.after", () => ({ media: [{ mimeType: "image/png" }] }));

// A round.after handler reads the reason and the count, and answers a stop or a continue.
s.hook("round.after", ({ finishReason, continues }): RoundAfterAnswer | undefined => {
  if (finishReason === null) return undefined;
  return continues < 3 ? { continue: "Run the tests." } : { stop: true };
});
// @ts-expect-error: an answer is a stop or a continue, not both.
s.hook("round.after", () => ({ stop: true, continue: "x" }));
// @ts-expect-error: a stop is `true`.
s.hook("round.after", () => ({ stop: false }));

// The web globals declare what the runtime has, and no more.
assert<Equal<typeof DOMException.ABORT_ERR, 20>>();
assert<Equal<typeof Event.AT_TARGET, 2>>();
new TextDecoder("utf8");
// @ts-expect-error: the decoder decodes UTF-8 only.
new TextDecoder("utf-16le");
