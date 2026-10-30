/** The code of the public module `yuke:process`. Its declaration is `types/process.d.ts`, and the check at the end compares the two. */

import { underSignal } from "yuke:internal/events";
import { type ProcessRequest, processOutput } from "yuke:internal/native";
import type { CommandOptions, CommandOutput } from "yuke:process";

export class Command {
  readonly #request: ProcessRequest;
  readonly #signal: AbortSignal | undefined;

  constructor(command: string, options: CommandOptions) {
    if (!options.cwd.startsWith("/")) throw new TypeError("the option cwd is not an absolute path");
    this.#request = {
      command,
      args: [...(options.args ?? [])],
      cwd: options.cwd,
      env: { ...options.env },
      clearEnv: options.clearEnv ?? false,
      stdout: options.stdout !== "null",
      stderr: options.stderr !== "null",
    };
    this.#signal = options.signal;
  }

  async output(): Promise<CommandOutput> {
    const end = await underSignal(this.#signal, () => processOutput(this.#request));
    return Object.freeze({ success: end.code === 0, ...end });
  }
}

// The check against `types/process.d.ts` keeps this code and the declarations of the authors in step.
const declared = { Command } satisfies typeof import("yuke:process");
void declared;
