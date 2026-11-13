/** The code of the public module `yuke:ai`. Its declaration is `types/ai.d.ts`, and the check at the end compares the two. */

import type { GenerateTextOptions, GenerateTextResult, ObjectOutput, TextAnswer } from "yuke:ai";
import { checkArguments } from "yuke:internal/arguments";
import { underStop } from "yuke:internal/events";
import { aiComplete } from "yuke:internal/native";
import type { FinishReason, Usage } from "yuke:protocol";
import type { Infer, ObjectSchema, Schema } from "yuke:tools";

export const Output = Object.freeze({
  object<const S extends ObjectSchema>(options: { schema: S; name?: string }): ObjectOutput<Infer<S>> {
    const output = Object.freeze({ schema: options.schema, name: options.name ?? "response" });
    // The brand of the type exists only for TypeScript.
    return output as unknown as ObjectOutput<Infer<S>>;
  },
});

/**
 * `schema` in the form that each provider takes. Anthropic refuses a bound and an object without
 * `additionalProperties: false`, so each object gets it, and each bound moves into the description.
 */
function providerSchema(schema: Schema): Record<string, unknown> {
  const { minimum, maximum, ...rest } = schema as Schema & { minimum?: number; maximum?: number };
  const sent: Record<string, unknown> = rest;
  const bounds = JSON.stringify({ minimum, maximum });
  if (bounds !== "{}") sent.description = schema.description === undefined ? bounds : `${schema.description} ${bounds}`;
  if (schema.type === "array") sent.items = providerSchema(schema.items);
  if (schema.type === "object") {
    sent.properties = Object.fromEntries(
      Object.entries(schema.properties).map((entry) => {
        const [name, property] = entry;
        return [name, providerSchema(property)];
      }),
    );
    sent.additionalProperties = false;
  }
  return sent;
}

export class NoObjectGeneratedError extends Error {
  readonly text: string;
  readonly finishReason: FinishReason;
  readonly usage: Usage;

  constructor(message: string, options: { cause: unknown; text: string; finishReason: FinishReason; usage: Usage }) {
    super(message, { cause: options.cause });
    this.name = "NoObjectGeneratedError";
    this.text = options.text;
    this.finishReason = options.finishReason;
    this.usage = options.usage;
  }
}

export function generateText<T>(
  options: GenerateTextOptions & { output: ObjectOutput<T> },
): Promise<GenerateTextResult<T>>;
export function generateText(options: GenerateTextOptions): Promise<GenerateTextResult>;
export async function generateText(options: GenerateTextOptions): Promise<GenerateTextResult<unknown>> {
  const output = options.output;
  const settings: Record<string, unknown> = {
    maxOutputTokens: options.maxOutputTokens,
    temperature: options.temperature,
    topP: options.topP,
    reasoning: options.reasoning,
  };
  if (output !== undefined) {
    // OpenAI strict mode needs each field required, so yuke sends no strict mode and checks the answer itself.
    settings.outputSchema = { name: output.name, schema: JSON.stringify(providerSchema(output.schema)), strict: false };
  }
  const request = {
    model: options.model,
    system: options.instructions ?? "",
    blocks: typeof options.prompt === "string" ? [{ kind: "userText", text: options.prompt }] : options.prompt,
    attachments: options.attachments ?? [],
    // The native side reads JSON, which leaves out a missing setting.
    settings,
  };
  const answer = await underStop(options.signal, () => aiComplete(request));
  return Object.freeze({ ...answer, output: output === undefined ? undefined : objectOf(output.schema, answer) });
}

/** Parse the text of `answer`, and check it against `schema`. A failure throws a `NoObjectGeneratedError`. */
function objectOf(schema: ObjectSchema, answer: TextAnswer): unknown {
  try {
    if (answer.finishReason !== "stop") throw new Error(`the answer stopped with ${answer.finishReason}`);
    return checkArguments(schema, JSON.parse(answer.text));
  } catch (cause) {
    throw new NoObjectGeneratedError("the answer is not the requested object", { cause, ...answer });
  }
}

// The check against `types/ai.d.ts` keeps this code and the declarations of the authors in step.
const declared = { generateText, Output, NoObjectGeneratedError } satisfies typeof import("yuke:ai");
void declared;
