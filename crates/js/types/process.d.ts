// The declaration of the public module `yuke:process`.

/**
 * Programs, in the shape of `Deno.Command`: a program and its arguments, without a shell.
 * - Each program runs in its own process group, and it gets no input.
 * - `cwd` is required: a tool passes `context.folder`, and a session passes `s.folder`.
 * - An abort of the `signal` stops the group: SIGTERM, then SIGKILL after 2 seconds. The run then fulfills with the
 *   end of the program, as in Deno: a program that the signal ended has code 143 and the signal `"SIGTERM"`. A signal
 *   that aborted before the start rejects with its reason, and nothing runs.
 * - After the exit of the program, the run waits for the end of stdout and stderr: a process that the program left
 *   can still write. An abort stops such a process too.
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
    /** A signal that stops the program. */
    signal?: AbortSignal | undefined;
  }

  /** How a program ended, and its output. */
  export interface CommandOutput {
    /** `code` is 0. */
    readonly success: boolean;
    /** The exit code, or 128 and the number of the signal that ended the program. */
    readonly code: number;
    /** The name of the signal that ended the program, such as `"SIGTERM"`, or `null`. */
    readonly signal: string | null;
    /** The bytes of stdout. They are empty for `"null"`. */
    readonly stdout: Uint8Array;
    /** The bytes of stderr. They are empty for `"null"`. */
    readonly stderr: Uint8Array;
  }

  /** A program to run. Each `output` starts it again. */
  export class Command {
    /** `command` is a name that the `PATH` finds, or a path. */
    constructor(command: string, options: CommandOptions);
    /** Run the program until it ends, and give its end and its output. A program that does not start rejects. */
    output(): Promise<CommandOutput>;
  }
}
