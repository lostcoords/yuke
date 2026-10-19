// Type checks of the author API. `tsc -p crates/js/tsconfig.json` runs them; nothing executes this file.
import type { PluginApply, PluginContext, PluginSession, PromptBuild, SessionContext } from "yuke:plugins";
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

export { results };

// A `prompt.build` handler gets the sections and the signal, edits the sections, and returns nothing.
const remove: () => void = s.hook("prompt.build", (build) => {
  assert<Equal<typeof build, PromptBuild>>();
  assert<Equal<typeof build.sections, Record<string, string>>>();
  build.sections.rules = "Be brief.";
  // @ts-expect-error: the signal belongs to the host.
  build.signal = new AbortController().signal;
});
remove();
s.hook("prompt.build", async (build) => {
  await Promise.resolve();
  delete build.sections.environment;
});
// @ts-expect-error: a handler returns nothing.
s.hook("prompt.build", () => "done");
// @ts-expect-error: no hook has this point.
s.hook("turn.start", () => undefined);
