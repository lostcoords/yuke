/** The code of the public module `yuke:ai`. Its declaration is `types/ai.d.ts`, and the check at the end compares the two. */

import type { GenerateTextResult } from "yuke:ai";
import { fieldsOf, jsonCopy } from "yuke:internal/define";
import { signalOf, underSignal } from "yuke:internal/events";
import { aiComplete } from "yuke:internal/native";

/** The settings among the options of `generateText`. */
const SETTINGS = ["maxOutputTokens", "temperature", "topP", "reasoning"] as const;

/** The names of the options of `generateText`. */
const OPTIONS = ["model", "instructions", "prompt", "abortSignal", ...SETTINGS] as const;

export async function generateText(options: unknown): Promise<GenerateTextResult> {
  const fields = fieldsOf(options, "the options", OPTIONS);
  const { model, instructions = "", prompt, abortSignal } = fields;
  const { provider, model: id } = fieldsOf(model, "the option model", ["provider", "model"]);
  if (typeof provider !== "string" || typeof id !== "string") {
    throw new TypeError("the option model has no string provider and model");
  }
  if (typeof instructions !== "string") throw new TypeError("the option instructions is not a string");
  const blocks = typeof prompt === "string" ? [{ user_text: prompt }] : prompt;
  if (!Array.isArray(blocks)) throw new TypeError("the option prompt is not a string or an array");
  const stop = signalOf(abortSignal);
  const request = {
    model: { provider, model: id },
    system: instructions,
    blocks,
    // The copy drops a missing setting. It refuses a number that is not finite, which JSON would make `null`.
    settings: jsonCopy(Object.fromEntries(SETTINGS.map((name) => [name, fields[name]])), "a setting"),
  };
  try {
    return Object.freeze(await underSignal(stop, () => aiComplete(request)));
  } catch (error) {
    // Only a stop of the request rejects with this record, so a failure before an abort keeps its error.
    const cancelled = typeof error === "object" && error !== null && "cancelled" in error;
    if (cancelled && stop !== undefined) throw stop.reason;
    throw error;
  }
}

// The check against `types/ai.d.ts` keeps this code and the declarations of the authors in step.
const declared = { generateText } satisfies typeof import("yuke:ai");
void declared;
