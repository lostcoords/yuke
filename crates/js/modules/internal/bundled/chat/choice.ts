/** The saved pick of the bundled chat in `choice.json`: the model and the level of the first session of a pane. */

import { FileSystemError, readTextFile, writeTextFile } from "yuke:fs";
import type { ModelReference, ReasoningLevel } from "yuke:protocol";

export interface Choice {
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
  readonly #listeners = new Set<() => void>();
  readonly #read: Promise<void>;
  #choice: Choice | undefined;

  /** Read the pick. A missing file gives no pick, and another failure goes to `report`. */
  constructor(dataDir: string, report: (error: unknown) => void) {
    this.#dataDir = dataDir;
    this.#read = readTextFile("choice.json", { baseDir: dataDir, fatal: true })
      .then((text) => JSON.parse(text))
      .then(
        (value: unknown) => {
          this.#choice = choiceOf(value);
          this.#changed();
        },
        (error: unknown) => {
          if (!(error instanceof FileSystemError && error.code === "ENOENT")) report(error);
        },
      );
  }

  get current(): Choice | undefined {
    return this.#choice;
  }

  /** The pick after the first read. */
  async loaded(): Promise<Choice | undefined> {
    await this.#read;
    return this.#choice;
  }

  /** Save `choice`. A failed write keeps the old pick. */
  async save(choice: Choice): Promise<void> {
    await writeTextFile("choice.json", JSON.stringify(choice), { baseDir: this.#dataDir, atomic: true });
    this.#choice = choice;
    this.#changed();
  }

  onChange(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  #changed(): void {
    for (const listener of this.#listeners) listener();
  }
}
