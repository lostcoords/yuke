// The declaration of the public module `yuke:process`.

/**
 * `env` reads the environment of yuke, as `Deno.env.get` does. It does not change the environment.
 *
 * Programs, in the shape of `Deno.Command`: a program and its arguments, without a shell.
 * - Each program runs in its own process group. It gets no input, unless `spawn` pipes stdin.
 * - `output` runs a program until its end. `spawn` starts it, and gives its pipes as streams while it runs.
 * - `cwd` is required: a tool passes `context.folder`, and a session passes `s.folder`.
 * - An abort of the `signal` stops the group: SIGTERM, then SIGKILL after 2 seconds. The run, or the `status` of a
 *   spawn, then fulfills with the end of the program, as in Deno: a program that the signal ended has code 143 and the
 *   signal `"SIGTERM"`. A signal that aborted before the start rejects with its reason, and nothing runs.
 * - After the exit of the program, `output` waits for the end of stdout and stderr: a process that the program left
 *   can still write. An abort stops such a process too.
 * - The end of the runtime stops each program that runs.
 * - yuke sets no limit on the time or on the output.
 * - A relative `cwd` throws a `TypeError`.
 */
declare module "yuke:process" {
  /** The options of a command. An option that is `undefined` is missing. */
  export interface CommandOptions {
    /** The arguments. Each one reaches the program as it is. */
    args?: readonly string[] | undefined;
    /** The absolute folder of the program. */
    cwd: string;
    /** The environment variables that the program gets beside the environment of yuke. */
    env?: Readonly<Record<string, string>> | undefined;
    /** Leave out the environment of yuke, so the program gets only `env`. */
    clearEnv?: boolean | undefined;
    /** `"piped"` keeps the stream in the output, and `"null"` drops it. The default is `"piped"`. */
    stdout?: "piped" | "null" | undefined;
    /** As `stdout`. */
    stderr?: "piped" | "null" | undefined;
    /**
     * `"piped"` gives stdin as the stream `ChildProcess.stdin`, and `"null"` gives no input. The default is `"null"`.
     * yuke owns the terminal, so a program cannot inherit stdin. `output` with `"piped"` throws a `TypeError`.
     */
    stdin?: "piped" | "null" | undefined;
    /** A signal that stops the program. */
    signal?: AbortSignal | undefined;
  }

  /** How a program ended. */
  export interface CommandStatus {
    /** `code` is 0. */
    readonly success: boolean;
    /** The exit code, or 128 and the number of the signal that ended the program. */
    readonly code: number;
    /** The name of the signal that ended the program, such as `"SIGTERM"`, or `null`. */
    readonly signal: string | null;
  }

  /** How a program ended, and its output. */
  export interface CommandOutput extends CommandStatus {
    /** The bytes of stdout. They are empty for `"null"`. */
    readonly stdout: Uint8Array;
    /** The bytes of stderr. They are empty for `"null"`. */
    readonly stderr: Uint8Array;
  }

  /** The environment of the yuke process. A plugin reads it, and a program gets it unless `clearEnv` is set. */
  export const env: {
    /** The value of the variable `name`. `undefined` when the variable is missing or its value is not valid Unicode. */
    readonly get: (name: string) => string | undefined;
  };

  /**
   * A program that `spawn` started. Read or cancel `stdout` and `stderr`: a program that writes to a full pipe waits.
   * `await using` stops the program and waits for its end.
   */
  export interface ChildProcess extends AsyncDisposable {
    /**
     * The input of the program. A close of the stream or of its writer closes stdin, so the program reads the end of
     * its input. Each chunk is a `Uint8Array`. Without `stdin: "piped"`, the property throws a `TypeError`.
     */
    readonly stdin: WritableStream<Uint8Array>;
    /**
     * The bytes of stdout, in chunks. The stream ends when each process of the group closes stdout. A cancel closes
     * the pipe. Without `stdout: "piped"`, the property throws a `TypeError`.
     */
    readonly stdout: ReadableStream<Uint8Array>;
    /** As `stdout`, for stderr. */
    readonly stderr: ReadableStream<Uint8Array>;
    /** The process id of the program. It leads the process group. */
    readonly pid: number;
    /** The end of the program. It fulfills at the exit of the program, before the end of the streams. */
    readonly status: Promise<CommandStatus>;
    /**
     * Wait for the end of the program and of its streams, and give the rest of the output. A stream that a reader
     * holds throws a `TypeError`.
     */
    output: () => Promise<CommandOutput>;
    /**
     * Send the signal `signo` to the process group. The default is `"SIGTERM"`. After the end of the program, or for
     * an unknown signal, it throws a `TypeError`.
     */
    kill: (signo?: string) => void;
  }

  /** A program to run. Each `output` and each `spawn` starts it again. */
  export class Command {
    /** `command` is a name that the `PATH` finds, or a path. */
    constructor(command: string, options: CommandOptions);
    /**
     * Run the program until it ends, and give its end and its output. A program that does not start rejects. With
     * `stdin: "piped"`, it throws a `TypeError`.
     */
    output(): Promise<CommandOutput>;
    /**
     * Start the program, and give its pipes while it runs. The start waits until the program runs, as in Deno. A
     * program that does not start throws an `Error`. A `signal` that aborted throws its reason, and nothing runs.
     */
    spawn(): ChildProcess;
  }
}
