/** The code of the public module `yuke:process`. Its declaration is `types/process.d.ts`, and the check at the end compares the two. */

import { addAbortStep } from "yuke:internal/events";
import {
  type ProcessChild,
  type ProcessRequest,
  processClose,
  processEnv,
  processKill,
  processRead,
  processSpawn,
  processStatus,
  processStop,
} from "yuke:internal/native";
import { isDisturbed, ReadableStream, readAll } from "yuke:internal/streams";
import type { ChildProcess, CommandOptions, CommandOutput, CommandStatus, Signal } from "yuke:process";

export const env = { get: (name: string): string | undefined => processEnv(name) };

export class Command {
  readonly #request: ProcessRequest;
  readonly #signal: AbortSignal | undefined;

  constructor(command: string, options: CommandOptions) {
    if (!options.cwd.startsWith("/")) throw new TypeError("the option cwd is not an absolute path");
    this.#request = {
      command,
      args: options.args ?? [],
      cwd: options.cwd,
      env: options.env ?? {},
      clearEnv: options.clearEnv ?? false,
      stdout: options.stdout !== "null",
      stderr: options.stderr !== "null",
    };
    this.#signal = options.signal;
  }

  // A run until the end is a spawn and its output. `async` turns a failed start into a rejection.
  async output(): Promise<CommandOutput> {
    return this.spawn().output();
  }

  spawn(): ChildProcess {
    this.#signal?.throwIfAborted();
    const spawned = processSpawn(this.#request);
    return new Child(spawned.child, spawned.pid, this.#request, this.#signal);
  }
}

/** `value`, or the `TypeError` of Deno for the stream `name` that is not piped. */
function piped<T>(name: "stdout" | "stderr", value: T | undefined): T {
  if (value === undefined) throw new TypeError(`Cannot get '${name}': '${name}' is not piped`);
  return value;
}

/** The stream of the output pipe `name` of `child`, and the promise of its end: a last read, a failure, or a cancel. */
function outputStream(
  child: ProcessChild,
  name: "stdout" | "stderr",
): { readonly stream: ReadableStream<Uint8Array>; readonly ended: Promise<void> } {
  const ended = Promise.withResolvers<void>();
  const stream = new ReadableStream<Uint8Array>(
    {
      pull: async (controller: ReadableStreamDefaultController<Uint8Array>) => {
        // After a cancel, `enqueue` and `close` throw, and the stream ignores that failure.
        const chunk = await processRead(child, name).catch((error: unknown) => {
          ended.resolve();
          throw error;
        });
        if (chunk !== undefined) return controller.enqueue(chunk);
        ended.resolve();
        controller.close();
      },
      cancel: () => {
        ended.resolve();
        processClose(child, name);
      },
    },
    // Each read pulls one chunk from the pipe, so nothing waits in a queue.
    { highWaterMark: 0 },
  );
  return { stream, ended: ended.promise };
}

class Child implements ChildProcess {
  readonly pid: number;
  readonly status: Promise<CommandStatus>;
  readonly #native: ProcessChild;
  readonly #stdout: ReadableStream<Uint8Array> | undefined;
  readonly #stderr: ReadableStream<Uint8Array> | undefined;

  constructor(native: ProcessChild, pid: number, request: ProcessRequest, signal: AbortSignal | undefined) {
    this.#native = native;
    this.pid = pid;
    // The status holds the native child, so the program runs until its end without a reference to this object.
    this.status = processStatus(native).then((status) => Object.freeze({ success: status.code === 0, ...status }));
    const stdout = request.stdout ? outputStream(native, "stdout") : undefined;
    const stderr = request.stderr ? outputStream(native, "stderr") : undefined;
    this.#stdout = stdout?.stream;
    this.#stderr = stderr?.stream;
    if (signal !== undefined) {
      const removeStep = addAbortStep(signal, () => processStop(native));
      // A process that the program left can hold a stream open after the exit, so the step waits for each stream that
      // a read started. A stream without a read ends the step at the exit, so a plugin that reads only `status` holds none.
      const settled = () =>
        Promise.all(
          [stdout, stderr].map((output) => (output && isDisturbed(output.stream) ? output.ended : undefined)),
        );
      void this.status.then(settled, settled).then(removeStep);
    }
  }

  get stdout(): ReadableStream<Uint8Array> {
    return piped("stdout", this.#stdout);
  }

  get stderr(): ReadableStream<Uint8Array> {
    return piped("stderr", this.#stderr);
  }

  async output(): Promise<CommandOutput> {
    if (this.#stdout?.locked === true) throw new TypeError("Cannot collect output: 'stdout' is locked");
    if (this.#stderr?.locked === true) throw new TypeError("Cannot collect output: 'stderr' is locked");
    const [stdout, stderr, status] = await Promise.all([
      this.#stdout && readAll(this.#stdout),
      this.#stderr && readAll(this.#stderr),
      this.status,
    ]);
    return Object.freeze({
      ...status,
      get stdout() {
        return piped("stdout", stdout);
      },
      get stderr() {
        return piped("stderr", stderr);
      },
    });
  }

  kill(signo: Signal = "SIGTERM"): void {
    processKill(this.#native, signo);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    processStop(this.#native);
    await this.status;
  }
}

// The check against `types/process.d.ts` keeps this code and the declarations of the authors in step.
const declared = { Command, env } satisfies typeof import("yuke:process");
void declared;
