// The declaration of the public module `yuke:process`.

/**
 * `env` reads the environment of yuke, as `Deno.env.get` does. It does not change the environment.
 *
 * Programs, in the shape of `Deno.Command` and `Deno.ChildProcess`: a program and its arguments, without a shell.
 * - Each program runs in its own process group, and it gets no input.
 * - `output` runs a program until its end. `spawn` starts it and gives its output while it runs.
 * - `cwd` is required: a tool passes `context.folder`, and a session passes `s.folder`.
 * - An abort of the `signal` stops the group: SIGTERM, then SIGKILL after 2 seconds. The status then fulfills, as in
 *   Deno: a program that the signal ended has code 143 and the signal `"SIGTERM"`. A
 *   signal that aborted before the start throws its reason from `spawn` and rejects `output`, and nothing runs.
 * - After the exit of the program, stdout and stderr end only when each process that holds them ends: a process that
 *   the program left can still write. An abort stops such a process too, while a read of the stream goes on.
 * - The end of the runtime stops a program that still runs.
 * - yuke sets no limit on the time or on the output.
 * - A relative `cwd` throws a `TypeError`.
 */
declare module "yuke:process" {
  /** The name of a signal, as in `Deno.Signal`. */
  export type Signal =
    | "SIGHUP"
    | "SIGINT"
    | "SIGQUIT"
    | "SIGILL"
    | "SIGTRAP"
    | "SIGABRT"
    | "SIGBUS"
    | "SIGFPE"
    | "SIGKILL"
    | "SIGUSR1"
    | "SIGSEGV"
    | "SIGUSR2"
    | "SIGPIPE"
    | "SIGALRM"
    | "SIGTERM"
    | "SIGCHLD"
    | "SIGCONT"
    | "SIGSTOP"
    | "SIGTSTP"
    | "SIGTTIN"
    | "SIGTTOU"
    | "SIGURG"
    | "SIGXCPU"
    | "SIGXFSZ"
    | "SIGVTALRM"
    | "SIGPROF"
    | "SIGWINCH"
    | "SIGIO"
    | "SIGSYS";

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
    /** `"piped"` gives the stream to the plugin, and `"null"` drops it. The default is `"piped"`. */
    stdout?: "piped" | "null" | undefined;
    /** As `stdout`. */
    stderr?: "piped" | "null" | undefined;
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
    readonly signal: Signal | null;
  }

  /** How a program ended, and its output. */
  export interface CommandOutput extends CommandStatus {
    /** The bytes of stdout. The getter throws a `TypeError` for `"null"`, as in Deno. */
    readonly stdout: Uint8Array;
    /** The bytes of stderr. The getter throws a `TypeError` for `"null"`, as in Deno. */
    readonly stderr: Uint8Array;
  }

  /** The environment of the yuke process. A plugin reads it, and a program gets it unless `clearEnv` is set. */
  export const env: {
    /** The value of the variable `name`. `undefined` when the variable is missing or its value is not valid Unicode. */
    readonly get: (name: string) => string | undefined;
  };

  /** A spawned program. `await using` stops it, and waits for its end. */
  export interface ChildProcess extends AsyncDisposable {
    /** The process id of the program. Its process group has the same id. */
    readonly pid: number;
    /** The bytes of stdout, in chunks. A cancel closes the pipe, so a later write of the program fails. */
    readonly stdout: ReadableStream<Uint8Array>;
    /** As `stdout`. */
    readonly stderr: ReadableStream<Uint8Array>;
    /** How the program ended. It fulfills at the exit of the program, before the end of its streams. */
    readonly status: Promise<CommandStatus>;
    /** Wait for the exit of the program and the end of its streams, and give its output. A locked stream throws a `TypeError`. */
    output: () => Promise<CommandOutput>;
    /** Send the signal `signo` to the process group. The default is `"SIGTERM"`. A call after the exit throws a `TypeError`. */
    kill: (signo?: Signal) => void;
  }

  /** A program to run. Each `output` and each `spawn` starts it again. */
  export class Command {
    /** `command` is a name that the `PATH` finds, or a path. */
    constructor(command: string, options: CommandOptions);
    /** Run the program until it ends, and give its end and its output. A program that does not start rejects. */
    output(): Promise<CommandOutput>;
    /**
     * Start the program, and give its child. A program that does not start throws an `Error`. The getter `stdout` or
     * `stderr` throws a `TypeError` when that stream is `"null"`.
     */
    spawn(): ChildProcess;
  }
}
