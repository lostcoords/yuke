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

  /** One file operation in flight: its promise, and the function that asks it to stop at its next check. */
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
  export function fsReadTextFile(path: string, baseDir: string | undefined): Operation<string>;
  export function fsWriteFile(
    path: string,
    baseDir: string | undefined,
    data: Uint8Array | string,
    atomic: boolean,
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
