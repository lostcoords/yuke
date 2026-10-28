import { checkArguments, checkParameters } from "yuke:internal/arguments";
import { bindCall } from "yuke:internal/call";
import { hostOperation } from "yuke:internal/events";
import { type Answer, register } from "yuke:internal/native";
import { displayOf, fieldsOf, hintsOf, mediaOf } from "yuke:internal/values";
import type { Infer, ObjectSchema, Tool, ToolContext, ToolHints, ToolMedia } from "yuke:tools";

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
  const hints = hintsOf(tool.hints as ToolHints | undefined, parameters as ObjectSchema);
  const description = {
    name: tool.name,
    description: tool.description,
    parameters: JSON.stringify(parameters),
    concurrency: tool.concurrency,
    deferLoading: tool.deferLoading === true,
    hints,
    open,
  };
  return register(description, (request) =>
    hostOperation(async (signal, abort) => {
      const { arguments: args, sessionId, callId, folder, output, call } = request;
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

/** The fields of a result object. */
const RESULT_FIELDS = ["text", "media", "isError", "display"];

/** The checked result of `execute`. A value of another shape throws a `TypeError`. */
function answerOf(result: unknown): Answer {
  if (typeof result === "string") return { text: result, isError: false, media: [], display: [] };
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
  const display = fields.display === undefined ? [] : displayOf(fields.display, "the result display");
  return { text: fields.text, isError: fields.isError === true, media, display };
}
