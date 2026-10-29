// The native module: Rust functions for the built-in modules (crates/js/src/native).

declare module "yuke:internal/native" {
  import type { NoticeLevel } from "yuke:plugins";
  import type {
    Blob,
    Block,
    DisplayBlock,
    EventNumber,
    ExtensionEventParams,
    InputId,
    InteractionId,
    InteractionResponse,
    Job,
    ListCatalogResult,
    ListSessionsParams,
    ListSessionsResult,
    McpServer,
    NoticeParams,
    SessionId,
    SessionRow,
    SessionSettings,
    SessionSnapshot,
    SessionUpdate,
    StoredEvent,
    ToolHints,
  } from "yuke:protocol";
  import type { CallOutcome, Frame, ModelRequest } from "yuke:test";
  import type { ToolMedia } from "yuke:tools";
  import type { Cursor } from "yuke:tui";

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
    readonly display: readonly DisplayBlock[];
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
      readonly hints: ToolHints;
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

  /** The values of the getters of a `URL`. */
  export interface UrlParts {
    readonly href: string;
    readonly origin: string;
    readonly protocol: string;
    readonly username: string;
    readonly password: string;
    readonly host: string;
    readonly hostname: string;
    readonly port: string;
    readonly pathname: string;
    readonly search: string;
    readonly hash: string;
  }
  /** The components of a `URL` that `updateUrl` sets. */
  export type UrlComponent =
    | "protocol"
    | "username"
    | "password"
    | "host"
    | "hostname"
    | "port"
    | "pathname"
    | "search"
    | "hash";
  /** The URL of `input` against `base`, or `undefined` when `input` or `base` is not valid. */
  export function parseUrl(input: string, base: string | undefined): UrlParts | undefined;
  /** The URL `href` after the setter of `component` with `value`. These setters take each value. */
  export function updateUrl(href: string, component: "pathname" | "search" | "hash", value: string): UrlParts;
  /** The URL `href` after the setter of `component` with `value`, or `undefined` when the setter refuses `value`. */
  export function updateUrl(href: string, component: UrlComponent, value: string): UrlParts | undefined;
  /** The name-value pairs of `text`, an `application/x-www-form-urlencoded` string. */
  export function parseQuery(text: string): [name: string, value: string][];
  /** The `application/x-www-form-urlencoded` string of `pairs`. */
  export function serializeQuery(pairs: readonly (readonly [name: string, value: string])[]): string;

  /** The body of a fetched response. When QuickJS frees it, the connection closes. */
  export interface HttpBody {
    readonly __httpBody: never;
  }
  /** The head of a fetched response, and its body. Each header string holds one character for each byte. */
  export interface HttpHead {
    readonly status: number;
    readonly statusText: string;
    readonly headers: [name: string, value: string][];
    readonly body: HttpBody;
  }
  /**
   * Send one request and give its head. It follows no redirect. A failure rejects with `{ code, message }`, and a stop
   * with `{ cancelled: true }`.
   */
  export function httpSend(
    method: string,
    url: string,
    headers: readonly (readonly [name: string, value: string])[],
    body: Uint8Array,
  ): Operation<HttpHead>;
  /** The next chunk of `body`, or `undefined` at the end. It rejects as `httpSend` does. */
  export function httpRead(body: HttpBody): Operation<Uint8Array | undefined>;
  /** Close `body` and its connection. */
  export function httpClose(body: HttpBody): void;

  /** Send an entry of `console`, a notice from the source `console`. */
  export function writeConsole(level: NoticeLevel, text: string): void;

  /** Send a notice of the plugin `source`. A `sessionId` that is not a session id throws a `TypeError`. */
  export function notify(source: string, level: NoticeLevel, message: string, sessionId: string | undefined): void;

  /**
   * Send the event `event` of the plugin `extension` to the clients. `data` is the JSON text of the data. A `sessionId`
   * that is not a session id throws a `TypeError`.
   */
  export function emit(extension: string, event: string, data: string, sessionId: string | undefined): void;

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

  /** The PNG bytes of the clipboard image, or `undefined` without an image. The read runs off the thread. */
  export function clipboardReadImage(): Promise<Uint8Array | undefined>;

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

  /**
   * The natives of the round of a `round.before` or `round.retry` request.
   * - `context` gives a new copy of the blocks of the context before the round.
   * - `tokens` gives the estimated tokens of each block of the view: `head`, then the last `kept` blocks of the
   *   context. A head that is not a list of blocks throws a `TypeError`.
   * - `sideRequest` sends the request of the round with the oldest `blocks` blocks of the view, then `prompt`. The view
   *   is `head`, then the last `kept` blocks of the context. A head that is not a list of blocks throws a `TypeError`. A failed request
   *   rejects with an `Error`, and a stop with `{ cancelled: true }`.
   */
  export interface RoundNatives {
    readonly context: () => import("yuke:protocol").Block[];
    readonly tokens: (head: readonly unknown[], kept: number) => number[];
    readonly sideRequest: (options: {
      readonly head: readonly unknown[];
      readonly kept: number;
      readonly blocks: number;
      readonly prompt: string;
      readonly maxOutputTokens: number | undefined;
    }) => Operation<import("yuke:plugins").SideRequestResult>;
  }

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

  /** A color of the terminal grid: a palette index from 0 to 255, `#` and six hex digits, or `reset`. */
  export type TermColor = number | `#${string}` | "reset";
  /** A style of the terminal grid. */
  export interface TermStyle {
    readonly fg?: TermColor;
    readonly bg?: TermColor;
    /** The underline color. It does not turn the underline on. */
    readonly ul?: TermColor;
    readonly bold?: boolean;
    readonly dim?: boolean;
    readonly italic?: boolean;
    readonly reverse?: boolean;
    readonly underline?: boolean;
  }
  /** Start the frame loop with `event` and `draw`. A second call throws. Without a display, it and the grid calls throw. */
  export function termRun(event: (event: object) => void, draw: () => void): void;
  /** Ask for a frame in `delay` milliseconds. The earliest ask wins. */
  export function termRequestFrame(delay: number): void;
  /** Blank a rectangle of the next frame with `style`. */
  export function termFill(x: number, y: number, width: number, height: number, style: TermStyle | undefined): void;
  /** Write `text`, a well-formed string, on one row of the next frame, and return the column after it. */
  export function termText(x: number, y: number, text: string, style: TermStyle | undefined): number;
  /** Show the cursor of the next frame, or hide it with `undefined`. */
  export function termCursor(cursor: Cursor | undefined): void;
  /** Send `text`, a well-formed string, to the clipboard of the terminal with OSC 52. */
  export function termCopy(text: string): void;
  /** A grid of cells that no terminal shows, for the frame tests. It draws with the rules of the terminal grid. */
  export class TestScreen {
    constructor(columns: number, rows: number);
    /** Change the size and blank the grid. */
    resize(columns: number, rows: number): void;
    /** Blank the grid and hide the cursor. */
    clear(): void;
    text(x: number, y: number, text: string, style: TermStyle | undefined): number;
    fill(x: number, y: number, width: number, height: number, style: TermStyle | undefined): void;
    cursor(cursor: Cursor | undefined): void;
    /** The cells and the cursor. A hidden cursor gives no `cursor` key. */
    frame(): Omit<Frame, "cursor"> & { readonly cursor?: Cursor };
  }
  /** Ask the host to quit. */
  export function termQuit(): void;
  /** Ask the host to give the terminal to the shell until it resumes yuke. */
  export function termSuspend(): void;
  /** Ask the host to load the plugins again in a new runtime, whose start event gets `snapshot`. */
  export function termReload(snapshot: string): void;
  /** The columns and the rows of the grid. */
  export function termSize(): [columns: number, rows: number];
  /** The light or dark class of the terminal background. */
  export function termBackground(): "dark" | "light";
  /** True when the terminal draws 24-bit color. */
  export function termTruecolor(): boolean;
  /** How the terminal interface started, as the JSON text of a `Startup` of `yuke:tui`. */
  export function termStartup(): string;
  /** The cells of `text`, a well-formed string. */
  export function termMeasure(text: string): number;
  /** The UTF-16 offset, the UTF-16 length, and the cells of each grapheme of `text`. */
  export function termGraphemes(text: string): Int32Array;
  /** The UTF-16 length of the longest grapheme prefix of `text` that fits in `cells`. */
  export function termFit(text: string, cells: number): number;
  /** The rows of `text` at `width` cells, as `[start, end, soft]` UTF-16 triples: all, or the first `head` rows. */
  export function termWrap(text: string, width: number, head: number): Int32Array;

  /** One event of a view: its snapshot first, then each later update, then the close of its session. */
  export type ViewEvent = { readonly snapshot: SessionSnapshot } | { readonly update: SessionUpdate } | "closed";
  /** Deliver the events of the views of this runtime to `deliver`, in batches of `[key, event]` pairs. Call it once. */
  export function sessionsListen(deliver: (batch: readonly (readonly [number, ViewEvent])[]) => void): void;
  /** Wait until the listener got each event that the feed holds now. */
  export function sessionsFlush(): Promise<void>;
  /** Open the session `id` when it is not open, hold it, and watch it as the view `key` with its last `tail` events. */
  export function sessionsOpen(request: readonly [key: number, id: SessionId, tail: number]): Promise<void>;
  /** End the hold and the view `key`. */
  export function sessionsRelease(key: number): void;
  export function sessionsCreate(settings: SessionSettings): Promise<SessionId>;
  export function sessionsFork(request: readonly [id: SessionId, through: EventNumber | null]): Promise<SessionId>;
  export function sessionsList(params: ListSessionsParams): Promise<ListSessionsResult>;
  export function sessionsGet(id: SessionId): Promise<SessionRow>;
  export function sessionsRemove(id: SessionId): Promise<null>;
  export function sessionsEvents(
    request: readonly [id: SessionId, before: EventNumber | null, limit: number],
  ): Promise<StoredEvent[]>;
  /** Send `content` as a message of the user. The model reads `modelContent` in place of `content` when it is set. */
  export function sessionInput(
    request: readonly [id: SessionId, content: readonly Block[], modelContent: readonly Block[] | null],
  ): Promise<InputId>;
  /** Send a notification of `plugin`: the user sees `display`, and the model reads `text`. */
  export function sessionNotify(
    request: readonly [id: SessionId, plugin: string, display: string, text: string],
  ): Promise<InputId>;
  export function sessionIdle(id: SessionId): Promise<null>;
  export function sessionSetSettings(request: readonly [id: SessionId, settings: SessionSettings]): Promise<null>;
  export function sessionRemoveInput(request: readonly [id: SessionId, inputId: InputId]): Promise<boolean>;
  /** Save `bytes` in the store of session `id`. Bytes over the attachment limit throw before the store gets them. */
  export function sessionPutBlob(id: SessionId, bytes: Uint8Array): Promise<Blob>;
  export function sessionStopJob(request: readonly [id: SessionId, jobId: string]): Promise<null>;
  export function sessionClose(request: readonly [id: SessionId, stopJobs: boolean]): Promise<null>;
  export function sessionCancel(id: SessionId): void;
  export function sessionRespond(
    request: readonly [id: SessionId, interactionId: InteractionId, response: InteractionResponse],
  ): void;
  export function sessionJobs(id: SessionId): Job[];
  export function sessionMcpServers(id: SessionId): McpServer[];
  export function catalogList(all: boolean): Promise<ListCatalogResult>;

  /** What the host of a test recorded. */
  export interface HostRecord {
    readonly notices: NoticeParams[];
    readonly events: ExtensionEventParams[];
    readonly requests: ModelRequest[];
  }

  /** Load the plugins and the model script of the host of a test. The given plugins hold their exports already. */
  export function testHostCreate(request: unknown): Operation<undefined>;
  /** What the host of the test recorded so far. */
  export function testHostRecord(): HostRecord;
  /** Close the sessions and the plugins of the host, then check the model script. */
  export function testHostClose(request: null): Operation<undefined>;
  /** Wait until the host got each report of the runtime before this call. */
  export function testHostSettle(): Promise<undefined>;
  /** Run the hook point `point` of the session `id` with `event`. The answer is the decision of the host. */
  export function testHostRun(request: readonly [id: SessionId, point: string, event: unknown]): Operation<unknown>;
  /** Call the tool `tool` of the session `id` with `args`. The answer has the live texts of the call in order. */
  export function testHostCall(request: readonly [id: SessionId, tool: string, args: unknown]): Operation<CallOutcome>;
}
