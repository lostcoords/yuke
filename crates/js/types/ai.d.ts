// The declaration of the public module `yuke:ai`.

/**
 * Model requests for plugins, with the catalog and the credentials of the sessions.
 * - `generateText` takes a subset of the option names of the Vercel AI SDK. The values keep the yuke shapes: `prompt`
 *   takes blocks, not messages, and `reasoning`, `finishReason`, and `usage` have the types of `yuke:protocol`.
 * - A request offers no tools and runs no plugin hooks. The session keeps nothing of it.
 * - After an overload or a lost connection, the request sends its attempt again, as a turn does.
 * - A media block fails the request, because the request has no store of attachments.
 * - An abort of the `abortSignal` stops the request, and `generateText` rejects with the reason of the signal.
 * - A misuse throws a `TypeError`: an unknown option, an option of another type, a block of another shape, or a
 *   setting that JSON cannot hold.
 */
declare module "yuke:ai" {
  import type { Block, FinishReason, ModelReference, Settings, Usage } from "yuke:protocol";

  /**
   * The options of `generateText`. An option that is `undefined` is missing. A missing setting keeps the default of
   * the endpoint, and so does `null`.
   */
  export interface GenerateTextOptions {
    /** The model of the request. `s.model` names the model of the session. */
    model: ModelReference;
    /** The system prompt. Empty or missing instructions send no system prompt. */
    instructions?: string | undefined;
    /** The input of the request: a text as one user block, or blocks, oldest first. A media block fails the request. */
    prompt: string | readonly Block[];
    /** The output limit. */
    maxOutputTokens?: Settings["maxOutputTokens"] | undefined;
    /** The sampling temperature. */
    temperature?: Settings["temperature"] | undefined;
    /** The nucleus sampling mass. */
    topP?: Settings["topP"] | undefined;
    /** Whether and how hard the model thinks. */
    reasoning?: Settings["reasoning"] | undefined;
    /** A signal that stops the request. */
    abortSignal?: AbortSignal | undefined;
  }

  /** The answer of the model. */
  export interface GenerateTextResult {
    /** The text of the answer. A line feed joins two text blocks. */
    readonly text: string;
    /** The reason that the answer stopped. For `"tool_calls"`, yuke runs no tool call of the answer. */
    readonly finishReason: FinishReason;
    /** The token counts of the request. */
    readonly usage: Usage;
  }

  /** Send one request to a model, and wait for its answer. A failure of the request rejects with an `Error`. */
  export function generateText(options: GenerateTextOptions): Promise<GenerateTextResult>;
}
