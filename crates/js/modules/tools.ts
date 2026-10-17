import type { ObjectSchema } from "yuke:internal/arguments";

export type { ArraySchema, ObjectSchema, ScalarSchema, Schema } from "yuke:internal/arguments";

/** The most bytes of the content of one tool output. A cut adds one line that tells the model what the cut left out. */
export const OUTPUT_BYTES = 50 * 1024;

/** What a call gives its tool besides the arguments. */
export interface ToolContext {
  /** The id of the call. */
  readonly callId: string;
  /** The workspace folder of the session. Relative paths and commands start here. */
  readonly folder: string;
  /** Aborts when the turn cancels the call, and when the call ends. The reason is a `DOMException` named `AbortError`. */
  readonly signal: AbortSignal;
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
  /**
   * `true` keeps the tool out of each request until the model finds it with the tool search. Use it for a tool that
   * the model rarely needs. The default is `false`.
   */
  readonly defer?: boolean;
  readonly execute: (args: Record<string, unknown>, context: ToolContext) => ToolAnswer | Promise<ToolAnswer>;
}
