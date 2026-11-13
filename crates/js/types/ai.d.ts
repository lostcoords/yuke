// The declaration of the public module `yuke:ai`.

/**
 * Model requests for plugins, with the catalog and the credentials of the sessions.
 * - `generateText` takes a subset of the option names of the Vercel AI SDK. The values keep the yuke shapes: `prompt`
 *   takes blocks, not messages, and `reasoning`, `finishReason`, and `usage` have the types of `yuke:protocol`.
 * - A request offers no tools and runs no plugin hooks. The session keeps nothing of it.
 * - After an overload or a lost connection, the request sends its attempt again, as a turn does.
 * - A media block of the prompt fails the request, because the request cannot read the store of a session. Pass new
 *   media as `attachments`.
 * - An abort of the `signal` stops the request, and `generateText` rejects with the reason of the signal.
 * - A block of another shape or a setting of another type throws a `TypeError`. yuke ignores an unknown option.
 */
declare module "yuke:ai" {
  import type { Block, FinishReason, ModelReference, ReasoningSettings, RequestSettings, Usage } from "yuke:protocol";
  import type { Infer, ObjectSchema, ToolMedia } from "yuke:tools";

  /** The key of the brand that carries the object type of an `ObjectOutput`. Only TypeScript sees it. */
  const objectType: unique symbol;

  // biome-ignore lint/complexity/noUselessEmptyExport: without it, an ambient module exports `objectType` too.
  export {};

  /** A request for a JSON object of a schema. */
  export interface ObjectOutput<T> {
    /** The schema of the object, in the dialect of the `inputSchema` of a tool. */
    readonly schema: ObjectSchema;
    /** The name of the schema. OpenAI needs it, and Anthropic ignores it. */
    readonly name: string;
    readonly [objectType]: T;
  }

  /** The kinds of output that `generateText` can request. */
  export const Output: {
    /**
     * Request a JSON object that matches `schema`. An inline schema keeps its types, and a schema in a constant needs
     * `as const`. yuke checks the answer against the keywords of `Schema` and ignores others. The default `name`
     * is `response`. OpenAI takes a name of 1 to 64 letters, digits, `_`, or `-`.
     */
    readonly object: <const S extends ObjectSchema>(options: { schema: S; name?: string }) => ObjectOutput<Infer<S>>;
  };

  /**
   * The answer is not a JSON object that matches the schema, or it did not finish with `"stop"`. The error keeps the
   * answer, and `cause` tells what failed.
   */
  export class NoObjectGeneratedError extends Error {
    constructor(message: string, options: { cause: unknown; text: string; finishReason: FinishReason; usage: Usage });
    /** The text of the answer. */
    readonly text: string;
    /** The reason that the answer stopped, for example `"length"` or `"refusal"`. */
    readonly finishReason: FinishReason;
    /** The token counts of the request. */
    readonly usage: Usage;
  }

  /**
   * The options of `generateText`. An option that is `undefined` is missing. A missing setting keeps the default of
   * the endpoint, and so does `null`.
   */
  export interface GenerateTextOptions {
    /** The model of the request. `s.settings.model` names the model of the session. */
    model: ModelReference;
    /** The system prompt. Empty or missing instructions send no system prompt. */
    instructions?: string | undefined;
    /** The input of the request: a text as one user block, or blocks, oldest first. A media block fails the request. */
    prompt: string | readonly Block[];
    /**
     * The media after the prompt, in order, in the shape of the media of a tool result. A `path` is absolute.
     * The session keeps nothing of them. An image works with each provider. Another type depends on the provider:
     * OpenAI needs a file name for a document, so it fails there.
     */
    attachments?: readonly ToolMedia[] | undefined;
    /** The output limit. */
    maxOutputTokens?: RequestSettings["maxOutputTokens"] | undefined;
    /** The sampling temperature. */
    temperature?: RequestSettings["temperature"] | undefined;
    /** The nucleus sampling mass. */
    topP?: RequestSettings["topP"] | undefined;
    /** Whether and how hard the model thinks. A missing field keeps the default of the endpoint. */
    reasoning?: Partial<ReasoningSettings> | undefined;
    /**
     * A request for a JSON object, from `Output.object`. The provider gets the schema, and yuke checks the answer
     * against it. An answer that does not match throws a `NoObjectGeneratedError`.
     */
    output?: ObjectOutput<unknown> | undefined;
    /** A signal that stops the request. */
    signal?: AbortSignal | undefined;
  }

  /** The answer of a model to one request, of `generateText` and of `sideRequest`. */
  export interface TextAnswer {
    /** The text of the answer. A line feed joins two text blocks. A call of a tool is not in it. */
    readonly text: string;
    /** The reason that the answer stopped. For `"toolCalls"`, yuke runs no tool call of the answer. */
    readonly finishReason: FinishReason;
    /** The token counts of the request. */
    readonly usage: Usage;
  }

  /** The answer of `generateText`. */
  export interface GenerateTextResult<T = undefined> extends TextAnswer {
    /** The checked object of an `output` request, or `undefined` without one. */
    readonly output: T;
  }

  /**
   * Send one request to a model, and wait for its answer. A failure of the request rejects with an `Error`. An
   * `output` gives the type of the checked object. Options of the wide type `GenerateTextOptions` give `unknown`.
   */
  export function generateText<T>(
    options: GenerateTextOptions & { output: ObjectOutput<T> },
  ): Promise<GenerateTextResult<T>>;
  export function generateText(
    options: GenerateTextOptions & { output?: undefined },
  ): Promise<GenerateTextResult<undefined>>;
  export function generateText(options: GenerateTextOptions): Promise<GenerateTextResult<unknown>>;
}
