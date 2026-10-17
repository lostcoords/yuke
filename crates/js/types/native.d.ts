// The native module: Rust functions for the built-in modules (crates/js/src/native).

declare module "yuke:internal/native" {
  import type { NoticeLevel } from "yuke:plugins";
  import type { ToolMedia } from "yuke:tools";

  /** The facts of one call. */
  export interface CallMetadata {
    readonly sessionId: string;
    readonly callId: string;
    /** The workspace folder of the session at the start of the call. */
    readonly folder: string;
  }

  /** The checked result of a call. */
  export interface Answer {
    readonly text: string;
    readonly isError: boolean;
    readonly media: readonly ToolMedia[];
  }

  /** The start of a call: the promise of its result, and the function that aborts its signal at a cancellation. */
  export interface Started {
    readonly answer: Promise<Answer>;
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

  /** The output and the cause of the end of a command: `exit`, `signal`, `timeout`, or `cancelled`. */
  export type CommandEnd = {
    /** stdout and stderr in the order of their writes. A cut keeps a head and a tail around a marker. */
    readonly output: string;
  } & (
    | { readonly cause: "exit"; readonly code: number }
    | { readonly cause: "signal"; readonly signal: number }
    /** The deadline stopped the command. */
    | { readonly cause: "timeout" }
    /** A cancel of the call, or its end, stopped the command. */
    | { readonly cause: "cancelled" }
  );

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
      readonly deferLoading: boolean;
      readonly owner: string | undefined;
    },
    start: (argumentsText: string, metadata: CallMetadata, output: (text: string) => void, session: Session) => Started,
  ): void;

  /** Remove each tool of the plugin `owner`. */
  export function removeTools(owner: string): void;

  /** Send a notice of the plugin `source`. A `sessionId` that is not a session id throws a `TypeError`. */
  export function notify(source: string, level: NoticeLevel, message: string, sessionId: string | undefined): void;

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
    | { readonly image: { readonly path: string; readonly mimeType: string } };

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
