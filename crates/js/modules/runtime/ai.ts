/** The code of the public module `yuke:ai`. Its declaration is `types/ai.d.ts`, and the check at the end compares the two. */

import type { GenerateTextOptions, GenerateTextResult, ObjectOutput } from "yuke:ai";
import { checkArguments, checkParameters } from "yuke:internal/arguments";
import { fieldsOf, jsonCopy, mediaOf } from "yuke:internal/define";
import { signalOf, underStop } from "yuke:internal/events";
import { aiComplete } from "yuke:internal/native";
import type { FinishReason, Usage } from "yuke:protocol";
import type { Infer, ObjectSchema, Schema } from "yuke:tools";

/** The settings among the options of `generateText`. */
const SETTINGS = ["maxOutputTokens", "temperature", "topP", "reasoning"] as const;

/** The names of the options of `generateText`. */
const OPTIONS = ["model", "instructions", "prompt", "attachments", "output", "abortSignal", ...SETTINGS] as const;

/** A schema name that OpenAI takes. */
const NAME = /^[A-Za-z0-9_-]{1,64}$/;

/** The checked schema of each value that `Output.object` returns, so a later change of the value changes nothing. */
const schemas = new WeakMap<object, { checked: ObjectSchema; sent: string }>();

export const Output = Object.freeze({
  object<const S extends ObjectSchema>(options: { schema: S; name?: string }): ObjectOutput<Infer<S>> {
    const { schema, name = "response" } = fieldsOf(options, "the options of Output.object", ["schema", "name"]);
    checkParameters(schema, "schema");
    if (typeof name !== "string" || !NAME.test(name)) {
      throw new TypeError("the option name is not 1 to 64 letters, digits, _, or -");
    }
    const checked = jsonCopy(schema, "the schema");
    const output = Object.freeze({ schema: jsonCopy(schema, "the schema"), name });
    schemas.set(output, { checked, sent: JSON.stringify(providerSchema(checked)) });
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
      Object.entries(schema.properties).map(([name, property]) => [name, providerSchema(property)]),
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
  const fields = fieldsOf(options, "the options", OPTIONS);
  const { model, instructions = "", prompt, attachments = [], output, abortSignal } = fields;
  const { provider, model: id } = fieldsOf(model, "the option model", ["provider", "model"]);
  if (typeof provider !== "string" || typeof id !== "string") {
    throw new TypeError("the option model has no string provider and model");
  }
  if (typeof instructions !== "string") throw new TypeError("the option instructions is not a string");
  const blocks = typeof prompt === "string" ? [{ user_text: prompt }] : prompt;
  if (!Array.isArray(blocks)) throw new TypeError("the option prompt is not a string or an array");
  if (!Array.isArray(attachments)) throw new TypeError("the option attachments is not an array");
  const media = attachments.map((item: unknown, index) => mediaOf(item, `attachments[${index}]`));
  const schema = typeof output === "object" && output !== null ? schemas.get(output) : undefined;
  if (output !== undefined && schema === undefined) {
    throw new TypeError("the option output is not a value of Output.object");
  }
  const settings: Record<string, unknown> = Object.fromEntries(SETTINGS.map((name) => [name, fields[name]]));
  if (schema !== undefined) {
    // OpenAI strict mode needs each field required, so yuke sends no strict mode and checks the answer itself.
    settings.outputSchema = { name: (output as ObjectOutput<unknown>).name, schema: schema.sent, strict: false };
  }
  const stop = signalOf(abortSignal);
  const request = {
    model: { provider, model: id },
    system: instructions,
    blocks,
    attachments: media,
    // The copy drops a missing setting. It refuses a number that is not finite, which JSON would make `null`.
    settings: jsonCopy(settings, "a setting"),
  };
  const answer = await underStop(stop, () => aiComplete(request));
  return Object.freeze({ ...answer, output: schema === undefined ? undefined : objectOf(schema.checked, answer) });
}

/** Parse the text of `answer`, and check it against `schema`. A failure throws a `NoObjectGeneratedError`. */
function objectOf(schema: ObjectSchema, answer: Omit<GenerateTextResult, "output">): unknown {
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
