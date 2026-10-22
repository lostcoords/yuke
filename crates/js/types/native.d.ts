// The native module: Rust functions for the built-in modules (crates/js/src/native).

declare module "yuke:internal/native" {
  import type { NoticeLevel } from "yuke:plugins";
  import type { ToolMedia } from "yuke:tools";

  /** What the start function of a tool gets for one call. */
  export interface CallRequest {
    /** The parsed JSON arguments of the model. */
    readonly arguments: unknown;
    readonly sessionId: string;
    readonly callId: string;
    /** The workspace folder of the session at the start of the call. */
    readonly folder: string;
    /** Send one text of the call to the consumer. */
    readonly output: (text: string) => void;
    readonly call: CallHost;
  }

  /** The checked result of a call. */
  export interface Answer {
    readonly text: string;
    readonly isError: boolean;
    readonly media: readonly ToolMedia[];
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
  export interface CallHost {
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
   * Add a tool to the registry of the runtime, for the open session `open`, or for every session without `open`, and
   * return its id. A name that the session already has, or a session that is closed, throws a `TypeError`.
   */
  export function register(
    tool: {
      readonly name: string;
      readonly description: string;
      /** The JSON text of the schema of the arguments. */
      readonly parameters: string;
      readonly concurrency: "serial" | "parallel";
      readonly deferLoading: boolean;
      readonly open: number | undefined;
    },
    start: (request: CallRequest) => Operation<Answer>,
  ): number;

  /** Remove the tools of `ids`. */
  export function unregister(ids: readonly number[]): void;

  /** The UTF-8 bytes of `text`, a well-formed string. */
  export function encodeText(text: string): Uint8Array;
  /** The UTF-8 bytes of the longest start of `text` that fits in `capacity` bytes, and its length in UTF-16 units. */
  export function encodeTextInto(text: string, capacity: number): { readonly bytes: Uint8Array; readonly read: number };
  /**
   * The UTF-8 text of `bytes`. A fatal decode throws a `TypeError` at an invalid sequence. With `stream`, `rest`
   * counts the bytes of an incomplete sequence at the end, which stay undecoded.
   */
  export function decodeText(
    bytes: Uint8Array,
    fatal: boolean,
    stream: boolean,
  ): { readonly text: string; readonly rest: number };
  /** Write a line of `console` for the operator. */
  export function writeConsole(level: NoticeLevel, text: string): void;

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

  /** What `processOutput` runs: a program with its arguments, without a shell. */
  export interface ProcessRequest {
    readonly command: string;
    readonly args: readonly string[];
    /** The absolute folder of the program. */
    readonly cwd: string;
    readonly env: Readonly<Record<string, string>>;
    readonly clearEnv: boolean;
    /** Whether the answer keeps stdout, and stderr. A stream that it does not keep goes to the null device. */
    readonly stdout: boolean;
    readonly stderr: boolean;
  }

  /** How a program ended, and its output. */
  export interface ProcessEnd {
    /** The exit code, or 128 and the number of the signal that ended the program. */
    readonly code: number;
    /** The name of the signal that ended the program, such as `SIGTERM`. */
    readonly signal: string | null;
    readonly stdout: Uint8Array;
    readonly stderr: Uint8Array;
  }

  /**
   * Run `request` in its own process group. A program that does not start rejects with an `Error`. The cancel stops
   * the group: SIGTERM, then SIGKILL after 2 seconds; the promise then fulfills with the end of the signal.
   */
  export function processOutput(request: ProcessRequest): Operation<ProcessEnd>;

  /**
   * Send one request of a plugin to `model`. `settings` holds the settings that the caller gives; each other setting
   * keeps the default of the endpoint. A block of another shape or a bad setting throws a `TypeError`. A failed request rejects with an
   * `Error`, and a stop with `{ cancelled: true }`.
   */
  export function aiComplete(request: {
    readonly model: { readonly provider: string; readonly model: string };
    readonly system: string;
    readonly blocks: readonly unknown[];
    readonly settings: object;
    /** Each path is absolute. A path that does not read rejects with an `Error` that names the path. */
    readonly attachments: readonly ToolMedia[];
  }): Operation<Omit<import("yuke:ai").GenerateTextResult, "output">>;

  /** One operation in flight: its promise, and the function that asks it to stop. */
  export interface Operation<T> {
    readonly promise: Promise<T>;
    readonly cancel: () => void;
  }

  /** The kind of a path, without a follow of a symbolic link for `isSymlink`. */
  export interface Kind {
    readonly isFile: boolean;
    readonly isDirectory: boolean;
    readonly isSymlink: boolean;
  }

  /**
   * The file operations of `yuke:fs`. A relative path needs the absolute `baseDir`; a bad path throws a `TypeError`. A
   * failure rejects with `{ code, message, path, destination }`, and a stop with `{ cancelled: true }`.
   */
  export function fsReadFile(
    path: string,
    baseDir: string | undefined,
    position: number,
    length: number | undefined,
  ): Operation<Uint8Array>;
  export function fsReadTextFile(path: string, baseDir: string | undefined, fatal: boolean): Operation<string>;
  /** `atomic` comes only with `create`. */
  export function fsWriteFile(
    path: string,
    baseDir: string | undefined,
    data: Uint8Array | string,
    placement: "replace" | "append" | "atomic",
    creation: "create" | "existing" | "new",
    mode: number | undefined,
  ): Operation<undefined>;
  export function fsReadDir(
    path: string,
    baseDir: string | undefined,
  ): Operation<readonly (Kind & { readonly name: string })[]>;
  export function fsStat(
    path: string,
    baseDir: string | undefined,
    follow: boolean,
  ): Operation<Kind & { readonly size: number; readonly mtime: number | undefined }>;
  export function fsMkdir(
    path: string,
    baseDir: string | undefined,
    recursive: boolean,
    mode: number | undefined,
  ): Operation<undefined>;
  export function fsRemove(
    path: string,
    baseDir: string | undefined,
    recursive: boolean,
    force: boolean,
  ): Operation<undefined>;
  export function fsRename(source: string, destination: string, baseDir: string | undefined): Operation<undefined>;

  /** At most `limit` lines from line `offset`, while they fit in `maxBytes`. */
  export function readLines(
    path: string,
    folder: string,
    offset: number,
    limit: number,
    maxBytes: number,
  ): Promise<Lines>;
}
