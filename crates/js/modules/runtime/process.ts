/** The code of the public module `yuke:process`. Its declaration is `types/process.d.ts`, and the check at the end compares the two. */

import { addAbortStep, underSignal } from "yuke:internal/events";
import {
  type ProcessChild,
  type ProcessRequest,
  processClose,
  processEnv,
  processKill,
  processOutput,
  processRead,
  processSpawn,
  processStatus,
  processStop,
  processWrite,
} from "yuke:internal/native";
import { ReadableStream } from "yuke:internal/streams";
import { WritableStream } from "yuke:internal/writable";
import type { ChildProcess, CommandOptions, CommandOutput, CommandStatus } from "yuke:process";

export const env = { get: (name: string): string | undefined => processEnv(name) };

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
      pipes: {
        stdin: options.stdin === "piped",
        stdout: options.stdout !== "null",
        stderr: options.stderr !== "null",
      },
    };
    this.#signal = options.signal;
  }

  output(): Promise<CommandOutput> {
    // As in Deno, the throw comes before any start.
    if (this.#request.pipes.stdin) {
      throw new TypeError("Piped stdin is not supported for this function, use 'Command.spawn()' instead");
    }
    return underSignal(this.#signal, () => processOutput(this.#request)).then((end) =>
      Object.freeze({ success: end.code === 0, ...end }),
    );
  }

  spawn(): ChildProcess {
    this.#signal?.throwIfAborted();
    const { child, pid } = processSpawn(this.#request);
    return new Child(child, pid, this.#request, this.#signal);
  }
}

/** The stream of the output pipe `name` of `child`. Each read pulls one chunk, so nothing waits in a queue. */
function outputStream(child: ProcessChild, name: "stdout" | "stderr"): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>(
    {
      pull: async (controller: ReadableStreamDefaultController<Uint8Array>) => {
        const chunk = await processRead(child, name);
        if (chunk === undefined) controller.close();
        else controller.enqueue(chunk);
      },
      cancel: () => processClose(child, name),
    },
    { highWaterMark: 0 },
  );
}

/** Each chunk of `stream` joined, or no bytes without a stream. */
async function collect(stream: ReadableStream<Uint8Array> | undefined): Promise<Uint8Array> {
  if (stream === undefined) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  for await (const chunk of stream) chunks.push(chunk);
  const bytes = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

class Child implements ChildProcess {
  readonly pid: number;
  readonly status: Promise<CommandStatus>;
  readonly #native: ProcessChild;
  readonly #stdin: WritableStream<Uint8Array> | undefined;
  readonly #stdout: ReadableStream<Uint8Array> | undefined;
  readonly #stderr: ReadableStream<Uint8Array> | undefined;

  constructor(native: ProcessChild, pid: number, request: ProcessRequest, signal: AbortSignal | undefined) {
    this.#native = native;
    this.pid = pid;
    this.#stdin = request.pipes.stdin
      ? new WritableStream<Uint8Array>({
          write: (chunk: Uint8Array) => {
            if (!(chunk instanceof Uint8Array)) throw new TypeError("a chunk of stdin is not a Uint8Array");
            return processWrite(native, chunk);
          },
          close: () => processClose(native, "stdin"),
          abort: () => processClose(native, "stdin"),
        })
      : undefined;
    this.#stdout = request.pipes.stdout ? outputStream(native, "stdout") : undefined;
    this.#stderr = request.pipes.stderr ? outputStream(native, "stderr") : undefined;
    // An abort after the exit still stops a process that the program left, as in `output`.
    const removeStep = signal === undefined ? undefined : addAbortStep(signal, () => processStop(native));
    // The status holds the native child, so the program runs until its end even without a reference to this object.
    this.status = processStatus(native).then((end) => Object.freeze({ success: end.code === 0, ...end }));
    this.status.then(
      () => removeStep?.(),
      () => removeStep?.(),
    );
  }

  get stdin(): WritableStream<Uint8Array> {
    if (this.#stdin === undefined) throw new TypeError("Cannot get 'stdin': 'stdin' is not piped");
    return this.#stdin;
  }

  get stdout(): ReadableStream<Uint8Array> {
    if (this.#stdout === undefined) throw new TypeError("Cannot get 'stdout': 'stdout' is not piped");
    return this.#stdout;
  }

  get stderr(): ReadableStream<Uint8Array> {
    if (this.#stderr === undefined) throw new TypeError("Cannot get 'stderr': 'stderr' is not piped");
    return this.#stderr;
  }

  async output(): Promise<CommandOutput> {
    if (this.#stdout?.locked === true) throw new TypeError("Cannot collect output: 'stdout' is locked");
    if (this.#stderr?.locked === true) throw new TypeError("Cannot collect output: 'stderr' is locked");
    const [stdout, stderr, status] = await Promise.all([collect(this.#stdout), collect(this.#stderr), this.status]);
    return Object.freeze({ ...status, stdout, stderr });
  }

  kill(signo = "SIGTERM"): void {
    processKill(this.#native, signo);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    try {
      processKill(this.#native, "SIGTERM");
    } catch {
      // The program ended already.
    }
    await this.status;
  }
}

// The check against `types/process.d.ts` keeps this code and the declarations of the authors in step.
const declared = { Command, env } satisfies typeof import("yuke:process");
void declared;
