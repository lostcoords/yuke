/** The saved pick of the bundled chat in `choice.json`: the model and the level of the first session of a pane. */

import { FileSystemError, readTextFile, writeTextFile } from "yuke:fs";
import type { ModelReference, ReasoningLevel } from "yuke:protocol";

interface Choice {
  readonly model: ModelReference;
  readonly reasoning: ReasoningLevel;
}

/** The pick of `value`, a parsed `choice.json`, or `undefined` when it has another shape. */
function choiceOf(value: unknown): Choice | undefined {
  const choice = value as { model?: { provider?: unknown; model?: unknown }; reasoning?: unknown } | null;
  const valid =
    typeof choice?.model?.provider === "string" &&
    typeof choice.model.model === "string" &&
    typeof choice.reasoning === "string";
  return valid ? (value as Choice) : undefined;
}

/**
 * The pick of the folder `dataDir`. It reads the file once, and a save keeps the new pick. A pick of another yuke
 * process shows after a reload.
 */
export class SavedChoice {
  readonly #dataDir: string;
  #choice: Choice | undefined;

  private constructor(dataDir: string, choice: Choice | undefined) {
    this.#dataDir = dataDir;
    this.#choice = choice;
  }

  /** Load the pick. A missing file gives no pick, and another failure goes to `report`. */
  static async load(dataDir: string, report: (error: unknown) => void): Promise<SavedChoice> {
    let choice: Choice | undefined;
    try {
      choice = choiceOf(JSON.parse(await readTextFile("choice.json", { cwd: dataDir, fatal: true })));
    } catch (error) {
      if (!(error instanceof FileSystemError && error.code === "ENOENT")) report(error);
    }
    return new SavedChoice(dataDir, choice);
  }

  get current(): Choice | undefined {
    return this.#choice;
  }

  /** Save `choice`. A failed write keeps the old pick. */
  async save(choice: Choice): Promise<void> {
    await writeTextFile("choice.json", JSON.stringify(choice), { cwd: this.#dataDir, atomic: true });
    this.#choice = choice;
  }
}
