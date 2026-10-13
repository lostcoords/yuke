import { checkArguments, checkSchema, type ObjectSchema } from "yuke:internal/arguments";
import { register } from "yuke:internal/native/tools";
import { CallSignal } from "yuke:internal/signal";

export type { ArraySchema, ObjectSchema, ScalarSchema, Schema } from "yuke:internal/arguments";
export type { CallSignal } from "yuke:internal/signal";

/** The most bytes of the content of one tool output. A cut adds one line that tells the model what the cut left out. */
export const OUTPUT_BYTES = 50 * 1024;

/** What a call gives its tool besides the arguments. */
export interface ToolContext {
  /** The id of the call. */
  readonly callId: string;
  /** The workspace folder of the session. Relative paths and commands start here. */
  readonly folder: string;
  /** The signal that aborts when the turn cancels the call, and when the call ends. */
  readonly signal: CallSignal;
  /** Show `text` to the user while the call runs. The model does not receive it. */
  readonly output: (text: string) => void;
}

/** A file that an answer attaches, for example an image. */
export interface MediaFile {
  /** The path of the file. A relative path starts in the workspace folder. */
  readonly path: string;
  /** The media type, for example `image/png`. */
  readonly mime: string;
}

/** The answer of a call: the text for the model, with attached files or without. */
export type ToolAnswer = string | { readonly output: string; readonly media?: readonly MediaFile[] };

/** A tool that the model can call. A throw of `execute` is an error result with the message of the error. */
export interface Tool {
  readonly name: string;
  readonly description: string;
  /** The schema of the arguments. A call with arguments that do not fit it fails before `execute`. */
  readonly parameters: ObjectSchema;
  /** `parallel` lets the calls run together with other parallel calls. `serial` runs each call alone. */
  readonly concurrency: "serial" | "parallel";
  readonly execute: (args: Record<string, unknown>, context: ToolContext) => ToolAnswer | Promise<ToolAnswer>;
}

/** Define `tool`. A second tool with the same name throws a `TypeError`. */
export function define(tool: Tool): void {
  checkSchema(tool.parameters);
  register(
    tool.name,
    tool.description,
    JSON.stringify(tool.parameters),
    tool.concurrency,
    (text, callId, folder, output) => {
      const signal = new CallSignal();
      const answer = run(tool, text, { callId, folder, signal, output });
      return { answer, abort: (reason: unknown) => signal.abort(reason) };
    },
  );
}

async function run(tool: Tool, text: string, context: ToolContext): Promise<ToolAnswer> {
  try {
    return await tool.execute(checkArguments(tool.parameters, JSON.parse(text)), context);
  } finally {
    context.signal.abort(new DOMException("The tool call has ended", "AbortError"));
  }
}
