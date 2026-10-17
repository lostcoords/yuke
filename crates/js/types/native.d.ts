// The native module: Rust functions for the built-in modules (crates/js/src/native).

declare module "yuke:internal/native" {
  /** The start of a call: the promise of its answer, and the function that aborts its signal at a cancel. */
  export interface Started {
    readonly answer: Promise<unknown>;
    readonly abort: () => void;
  }

  /** A started job: its id and its log file. */
  export interface StartedJob {
    readonly id: string;
    readonly log: string;
  }

  /** The result of a stop: how the job ended, for example `stopped` or `exited 0`, and its log file. */
  export interface StoppedJob {
    readonly label: string;
    readonly log: string;
  }

  /** How a command ended. */
  export interface CommandEnd {
    /** stdout and stderr in the order of their writes. A cut keeps a head and a tail around a marker. */
    readonly output: string;
    /** The exit code, when the command exited. */
    readonly code: number | undefined;
    /** The signal that ended the command. */
    readonly signal: number | undefined;
    /** The deadline stopped the command. */
    readonly timedOut: boolean;
    /** The abort of the signal, or the end of the call, stopped the command. */
    readonly stopped: boolean;
  }

  /** The native functions that need the session or the life of a call. */
  export interface Session {
    /**
     * Run `command` in the workspace folder with a shell. Each chunk of output goes to `onOutput`. A cancel of the call
     * and the end of the call stop the command.
     */
    readonly exec: (
      command: string,
      limits: { readonly timeoutMs: number; readonly maxBytes: number },
      onOutput: (text: string) => void,
    ) => Promise<CommandEnd>;
    /** Start `command` in the workspace folder as a job. Its end reaches the session as a message. */
    readonly startJob: (command: string) => Promise<StartedJob>;
    /** Stop the job `id` of the session. `undefined` when the session has no such job. */
    readonly stopJob: (id: string) => Promise<StoppedJob | undefined>;
    /** The ids of the running jobs of the session. */
    readonly runningJobs: () => string[];
  }

  /**
   * Add a tool to the registry of the runtime, for the plugin `owner` or for yuke itself. A second tool with the same
   * name throws a `TypeError`.
   */
  export function register(
    tool: {
      readonly name: string;
      readonly description: string;
      /** The JSON text of the schema of the arguments. */
      readonly parameters: string;
      readonly concurrency: "serial" | "parallel";
      readonly defer: boolean;
      readonly owner: string | undefined;
    },
    start: (
      argumentsText: string,
      callId: string,
      folder: string,
      output: (text: string) => void,
      session: Session,
    ) => Started,
  ): void;

  /** Remove each tool of the plugin `owner`. */
  export function removeTools(owner: string): void;

  /** Send a notice of the plugin `source`. A `sessionId` that is not a session id throws a `TypeError`. */
  export function notify(source: string, level: string, message: string, sessionId: string | undefined): void;

  /** Numbered lines, or an image. */
  export type Lines =
    | {
        /** Each line as `N: text` and a line feed. */
        readonly text: string;
        /** The first line that the read left out. */
        readonly next: number | undefined;
        /** A line that the read cut, because it alone is longer than the limit. */
        readonly cut: number | undefined;
      }
    | { readonly image: { readonly path: string; readonly mime: string } };

  /** At most `limit` lines from line `offset`, while they fit in `maxBytes`. */
  export function readLines(
    path: string,
    folder: string,
    offset: number,
    limit: number,
    maxBytes: number,
  ): Promise<Lines>;
  /** The whole file as text. */
  export function readText(path: string, folder: string): Promise<string>;
  /** Write the file and make its missing parent folders. Answers the byte count. */
  export function writeText(path: string, folder: string, text: string): Promise<number>;
}
