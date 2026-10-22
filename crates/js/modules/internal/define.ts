import { checkArguments, checkParameters } from "yuke:internal/arguments";
import { bindCall } from "yuke:internal/call";
import { hostOperation } from "yuke:internal/events";
import { type Answer, register } from "yuke:internal/native";
import type { Infer, ObjectSchema, Tool, ToolContext, ToolMedia } from "yuke:tools";

/**
 * Define `tool` for the open session `open`, or for every session without `open`, and return its id. A name that the
 * session already has throws a `TypeError`. A plugin defines its tools with `s.tools.define` of its `session`.
 */
export function defineTool<const S extends ObjectSchema>(tool: Tool<S>, open?: number): number {
  const execute = tool.execute;
  if (typeof execute !== "function") throw new TypeError("execute is not a function");
  // The model and the argument check use this one checked copy, so a later change of `tool` changes neither.
  const text = JSON.stringify(tool.parameters) as string | undefined;
  const parameters: unknown = text === undefined ? undefined : JSON.parse(text);
  checkParameters(parameters);
  const description = {
    name: tool.name,
    description: tool.description,
    parameters: JSON.stringify(parameters),
    concurrency: tool.concurrency,
    deferLoading: tool.deferLoading === true,
    open,
  };
  return register(description, ({ arguments: args, sessionId, callId, folder, output, call }) =>
    hostOperation(async (signal, abort) => {
      const context: ToolContext = { sessionId, callId, folder, signal, output };
      bindCall(context, call);
      try {
        return answerOf(await execute(checkArguments(parameters, args) as Infer<S>, context));
      } finally {
        abort("The tool call has ended");
      }
    }, "The tool call was cancelled"),
  );
}

/** The fields of a result object and of one media item. */
const RESULT_FIELDS = ["text", "media", "isError"];
const MEDIA_FIELDS = ["mimeType", "path", "bytes"];

/** The checked result of `execute`. A value of another shape throws a `TypeError`. */
function answerOf(result: unknown): Answer {
  if (typeof result === "string") return { text: result, isError: false, media: [] };
  const fields = fieldsOf(result, "the result", RESULT_FIELDS);
  if (typeof fields.text !== "string") throw new TypeError("the result text is not a string");
  if (fields.isError !== undefined && typeof fields.isError !== "boolean") {
    throw new TypeError("the result isError is not a boolean");
  }
  const list = fields.media === undefined ? [] : fields.media;
  if (!Array.isArray(list)) throw new TypeError("the result media is not an array");
  // An index loop, so a hole of a sparse array fails as a value that is not an object.
  const media: ToolMedia[] = [];
  for (let index = 0; index < list.length; index += 1) media.push(mediaOf(list[index], `the result media[${index}]`));
  return { text: fields.text, isError: fields.isError === true, media };
}

/** The checked copy of the media item `value`. `place` names it in the error. A value of another shape throws. */
export function mediaOf(value: unknown, place: string): ToolMedia {
  const fields = fieldsOf(value, place, MEDIA_FIELDS);
  const mimeType = fields.mimeType;
  if (typeof mimeType !== "string") throw new TypeError(`${place}.mimeType is not a string`);
  if (Object.hasOwn(fields, "path") === Object.hasOwn(fields, "bytes")) {
    throw new TypeError(`${place} needs exactly one of path and bytes`);
  }
  if (Object.hasOwn(fields, "path")) {
    if (typeof fields.path !== "string") throw new TypeError(`${place}.path is not a string`);
    return { mimeType, path: fields.path };
  }
  if (!(ArrayBuffer.isView(fields.bytes) && fields.bytes instanceof Uint8Array))
    throw new TypeError(`${place}.bytes is not a Uint8Array`);
  // A copy through the constructor, so a later change of the bytes by the plugin does not change the result.
  return { mimeType, bytes: new Uint8Array(fields.bytes) };
}

/**
 * A copy of the own fields of the object `value`. A value that is not an object, a symbol key, or a field outside
 * `names` throws. An inherited field does not count.
 */
export function fieldsOf(value: unknown, place: string, names: readonly string[]): Readonly<Record<string, unknown>> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new TypeError(`${place} is not an object`);
  }
  const fields: Record<string, unknown> = {};
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== "string") throw new TypeError(`${place} has a symbol key`);
    if (!names.includes(key)) throw new TypeError(`${place} has the unknown field '${key}'`);
    fields[key] = (value as Record<string, unknown>)[key];
  }
  return fields;
}
