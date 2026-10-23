/** The code of the public module `yuke:process`. Its declaration is `types/process.d.ts`, and the check at the end compares the two. */

import { fieldsOf } from "yuke:internal/define";
import { signalOf, underSignal } from "yuke:internal/events";
import { type ProcessRequest, processOutput } from "yuke:internal/native";
import type { CommandOutput } from "yuke:process";

/** The names of the options of a command. */
const OPTIONS = ["args", "cwd", "env", "clearEnv", "stdin", "stdout", "stderr", "signal"] as const;

/** Whether `value` keeps a stream: `"piped"` or a missing value keeps it, and `"null"` drops it. */
function keeps(value: unknown, name: string): boolean {
  if (value === undefined || value === "piped") return true;
  if (value === "null") return false;
  throw new TypeError(`the option ${name} is not "piped" or "null"`);
}

/** The request of `command` with `options` after the checks, and its signal. Each misuse throws a `TypeError`. */
function requestOf(command: unknown, options: unknown): { request: ProcessRequest; signal: AbortSignal | undefined } {
  if (typeof command !== "string") throw new TypeError("the command is not a string");
  const fields = fieldsOf(options, "the options", OPTIONS);
  const { args = [], cwd, env = {}, clearEnv = false, stdin, signal } = fields;
  if (!Array.isArray(args) || !args.every((arg) => typeof arg === "string")) {
    throw new TypeError("the option args is not an array of strings");
  }
  if (typeof cwd !== "string" || !cwd.startsWith("/")) throw new TypeError("the option cwd is not an absolute path");
  if (typeof env !== "object" || env === null || Array.isArray(env))
    throw new TypeError("the option env is not an object");
  const variables = Object.entries(env);
  if (
    !variables.every((variable) => {
      const [, value] = variable;
      return typeof value === "string";
    })
  ) {
    throw new TypeError("the option env has a value that is not a string");
  }
  if (typeof clearEnv !== "boolean") throw new TypeError("the option clearEnv is not a boolean");
  if (stdin !== undefined && stdin !== "null") throw new TypeError('the option stdin is not "null"');
  const request: ProcessRequest = {
    command,
    args: [...(args as string[])],
    cwd,
    env: Object.fromEntries(variables) as Record<string, string>,
    clearEnv,
    stdout: keeps(fields.stdout, "stdout"),
    stderr: keeps(fields.stderr, "stderr"),
  };
  return { request, signal: signalOf(signal) };
}

export class Command {
  readonly #request: ProcessRequest;
  readonly #signal: AbortSignal | undefined;

  constructor(command: string, options: unknown) {
    const { request, signal } = requestOf(command, options);
    this.#request = request;
    this.#signal = signal;
  }

  async output(): Promise<CommandOutput> {
    const end = await underSignal(this.#signal, () => processOutput(this.#request));
    return Object.freeze({ success: end.code === 0, ...end });
  }
}

// The check against `types/process.d.ts` keeps this code and the declarations of the authors in step.
const declared = { Command } satisfies typeof import("yuke:process");
void declared;
