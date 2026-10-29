// The declaration of the public module `yuke:test`.

/**
 * Tests for `yuke test`. A test file registers its tests at the top level.
 * - The runner runs the tests of a file one by one, in the order of their registration.
 * - Each test runs in a fresh runtime. No state of one test reaches the next test.
 * - A test passes when its function returns, or when its promise fulfills.
 * - A test fails when it throws, when its promise rejects, or when the runtime reports a fault while it runs, such as
 *   a rejection that no code handles. A test awaits its work, so a fault belongs to it.
 * - A test that runs longer than 5 seconds fails, and the runner stops its runtime. The next test still runs.
 * - Each assertion throws an `Error` when it fails.
 * - A stack line of a TypeScript file can name an earlier line than the source. The transpiler removes the type
 *   declarations and has no source map yet. Read the code at the failure to find the assertion.
 *
 * ```ts
 * import { assert, equal, rejects, test } from "yuke:test";
 *
 * test("a page holds its limit", async () => {
 *   equal(await page(2), { items: [1, 2], next: 3 });
 *   const error = await rejects(page(-1));
 *   assert(error instanceof RangeError);
 *   equal(error.message, "the limit is negative");
 * });
 * ```
 */
declare module "yuke:test" {
  import type { PluginApply, PluginSession, RoundFailureKind, ToolCall } from "yuke:plugins";
  import type {
    Block,
    ExtensionEventParams,
    FinishReason,
    InputKind,
    InputSource,
    NoticeParams,
    SessionId,
    SessionSettings,
    Settings,
    ToolDefinition,
  } from "yuke:protocol";
  import type { DisplayBlock, ObjectSchema, ToolMedia } from "yuke:tools";
  import type { Question, Transcript } from "yuke:transcript";
  import type { Cursor, KeyEvent, Mount, MouseEvent, Size, Startup, Tui, ViewFactory } from "yuke:tui";

  /** A color of a frame cell: a palette index from 0 to 255, or `#` and six lower-case hex digits. */
  export type ScreenColor = number | `#${string}`;

  /** The style of a frame cell: each color that is not the default, and each attribute that is on. */
  export interface CellStyle {
    readonly fg?: ScreenColor;
    readonly bg?: ScreenColor;
    readonly underlineColor?: ScreenColor;
    readonly bold?: true;
    readonly dim?: true;
    readonly italic?: true;
    readonly reverse?: true;
    readonly underline?: true;
  }

  export interface ScreenCell {
    readonly text: string;
    /** The cells of the grapheme. 0 is the second cell of a wide grapheme, with no text. */
    readonly width: 0 | 1 | 2;
    readonly style: CellStyle;
  }

  /** One drawn frame: the rows of cells, and the cursor in screen cells. */
  export interface Frame extends Size {
    readonly cells: readonly (readonly ScreenCell[])[];
    readonly cursor: Cursor | undefined;
  }

  /** The surface of a plugin in a frame test. `close()` removes its registrations and mounts, as a plugin stop does. */
  export interface TestSurface extends Mount {
    readonly tui: Tui;
  }

  /**
   * A terminal interface in a test: the real core, keymap, scene, and styles on a grid of cells. Each input method
   * handles its event, then draws a frame. `[Symbol.dispose]()` closes each surface.
   */
  export interface FrameTest extends Disposable {
    /** The last drawn frame. */
    readonly frame: Frame;
    /** The texts that `tui.copy` sent, the oldest first. */
    readonly copies: readonly string[];
    /** A new surface for the plugin `name`. */
    surface: (name: string) => TestSurface;
    draw: () => Frame;
    /** Press a key event, or the keys of a key spec such as `ctrl+k v`, one after the other. */
    key: (event: KeyEvent | string) => void;
    /** A mouse event in screen cells. */
    mouse: (event: MouseEvent) => void;
    paste: (text: string) => void;
    resize: (size: Size) => void;
    /** Send the start event of the frame loop. With `snapshot` from `snapshot()`, the saved panes come back. */
    start: (snapshot?: string) => void;
    /** The saved panes that a reload gives the start event of the next runtime. */
    snapshot: () => string;
  }

  /**
   * A frame test of `size`. `create` makes the root view. Without it, the root is the pane tree. `startup` is the
   * `tui.startup` of each surface. The default is `{ cwd: "/" }`.
   */
  export function createFrame(size: Size, create?: ViewFactory, startup?: Startup): FrameTest;

  /** Add the test `name`. The runner awaits the promise of `fn`. */
  export function test(name: string, fn: () => void | Promise<void>): void;

  /** Fail when `condition` is falsy. After the call, TypeScript knows that `condition` is truthy. */
  export function assert(condition: unknown, message?: string): asserts condition;

  /**
   * Fail when `actual` differs from `expected`. The comparison is deep and strict:
   * - Primitives compare with `Object.is`, so `NaN` equals `NaN`, and `-0` differs from `0`.
   * - Two objects need the same prototype.
   * - Arrays and typed arrays compare their elements.
   * - Maps compare their entries, and a key matches by identity. Sets compare their values. Dates compare their times.
   * - Errors also compare their name and message.
   * - Other objects compare their own enumerable keys, also symbols. A missing key differs from a key with the value
   *   `undefined`.
   *
   * The failure names the first path that differs, with both values. `message` comes first in it.
   */
  export function equal(actual: unknown, expected: unknown, message?: string): void;

  /** Call `fn`, and return what it throws. Fail when `fn` returns. */
  export function throws(fn: () => unknown): unknown;

  /** Await `promise`, and return its reason. Fail when `promise` fulfills. */
  export function rejects(promise: Promise<unknown>): Promise<unknown>;

  /** The scratch folder of the test: an empty folder for this test alone. Its path has no symbolic link. */
  export function folder(): string;
  // The host of plugins under test: an app with a scripted model, in the runtime of the test.

  /**
   * A plugin under test: its exports as a value, or a folder with its `plugin.json`. `import.meta.dirname` names the
   * folder of the module that holds the code: the entry of a folder, or the module that defines the exports.
   */
  export type PluginUnderTest =
    | {
        /** The name of the plugin, as in a manifest. */
        readonly name: string;
        // `any` lets a plugin keep the option type of its exports.
        // biome-ignore lint/suspicious/noExplicitAny: the options of each plugin have their own type.
        readonly apply?: PluginApply<any>;
        // biome-ignore lint/suspicious/noExplicitAny: the options of each plugin have their own type.
        readonly session?: PluginSession<any>;
        /** The schema of `options`, as the `optionsSchema` export of an entry. */
        readonly optionsSchema?: ObjectSchema;
        readonly options?: Readonly<Record<string, unknown>>;
        readonly uses?: readonly string[];
        readonly provides?: readonly string[];
      }
    | {
        /** The absolute folder of the plugin. The host reads its `plugin.json`, as for a plugin in `config.json`. */
        readonly folder: string;
        readonly options?: Readonly<Record<string, unknown>>;
      };

  /** One scripted answer of the fake model. Make it with `reply`. */
  export type Reply =
    | { readonly kind: "text"; readonly text: string; readonly inputTokens: number }
    | {
        readonly kind: "toolCalls";
        readonly text: string;
        readonly calls: readonly ScriptedCall[];
        readonly inputTokens: number;
      }
    | { readonly kind: "cut"; readonly calls: readonly ScriptedCall[] }
    | { readonly kind: "overloaded" }
    | { readonly kind: "overflow" }
    | { readonly kind: "failed"; readonly text: string }
    | { readonly kind: "stall"; readonly text: string };

  /** One tool call of a scripted answer. */
  export interface ScriptedCall {
    readonly name: string;
    readonly args: unknown;
  }

  /** The options of an answer: the input tokens of its usage, for a test of the context window. */
  export interface ReplyOptions {
    readonly inputTokens?: number;
  }

  /** The options of an answer with calls. */
  export interface CallsOptions extends ReplyOptions {
    /** The text of the answer before its calls. */
    readonly text?: string;
  }

  /** The makers of the scripted answers. */
  export const reply: {
    /** A complete answer with the text `text`. */
    readonly text: (text: string, options?: ReplyOptions) => Reply;
    /** A complete answer that calls the tool `name` with `args`. */
    readonly toolCall: (name: string, args: unknown, options?: CallsOptions) => Reply;
    /** A complete answer with several calls. */
    readonly toolCalls: (calls: readonly ScriptedCall[], options?: CallsOptions) => Reply;
    /** An answer with calls that the output limit cut. */
    readonly cut: (calls: readonly ScriptedCall[]) => Reply;
    /** An overload error before any output. The retry policy of yuke sends the request again. */
    readonly overloaded: () => Reply;
    /** A context overflow before any output. The retry policy skips it, so the `round.retry` hooks get the failure. */
    readonly overflow: () => Reply;
    /** An answer that streams `text`, then fails. The request fails without a retry. */
    readonly failed: (text: string) => Reply;
    /** An answer that streams `text` and never ends, for a test of a cancel. */
    readonly stall: (text?: string) => Reply;
  };

  /** One request that the fake model got. */
  export interface ModelRequest {
    readonly system: string;
    /**
     * Each message of the request in the order and with the roles of its protocol. The text holds the text parts and
     * the tool result contents, one per line. The OpenAI Responses protocol gives a tool result the role `tool`.
     */
    readonly messages: readonly { readonly role: string; readonly text: string }[];
    /** The names of the tools of the request. */
    readonly tools: readonly string[];
    /** The body as the provider got it. */
    readonly body: unknown;
  }

  /** A question that a plugin asked in a session of the host. */
  export interface TestQuestion extends Question {
    readonly sessionId: SessionId;
  }

  /** What `createHost` gets. */
  export interface HostOptions {
    /** The plugins under test, in load order. */
    readonly plugins: readonly PluginUnderTest[];
    /**
     * The replies of the fake model of the sessions, in order. Each request takes the next reply. The host writes the
     * reply in the stream format of the protocol of the request. A request after the last reply fails. A reply without
     * a request fails the test at the close of the host.
     */
    readonly replies?: readonly Reply[];
    /**
     * The answer to each question. Give `true` or `false` for `confirm`. Give a text for `select` and `input`.
     * `undefined` cancels the question. Without the function, each question gets `undefined`, as with no client. A
     * promise keeps the question open until it settles.
     */
    readonly answer?: (question: TestQuestion) => boolean | string | undefined | Promise<boolean | string | undefined>;
  }

  /**
   * Start a host for the plugins under test. The host is an app of yuke with an in-memory store and no bundled plugins.
   * It does not wait before a retry. A test creates one host. The end of the test closes it.
   */
  export function createHost(options: HostOptions): Promise<Host>;

  /** The host of a test. `await using` closes it at the end of its block. */
  export interface Host extends AsyncDisposable {
    /** The notices of the plugins and of the app so far. */
    readonly notices: readonly NoticeParams[];
    /** The events of the plugins so far. */
    readonly events: readonly ExtensionEventParams[];
    /** The questions of the plugins so far. */
    readonly questions: readonly TestQuestion[];
    /** The requests that the fake model got so far. */
    readonly requests: readonly ModelRequest[];
    /**
     * Create a session and open it. The model defaults to `minimax/MiniMax-M3`. The settings default to the endpoint
     * defaults. The workspace defaults to the folder of the test. The host has no login, so a provider with a login
     * fails.
     */
    readonly openSession: (settings?: Partial<SessionSettings>) => Promise<TestSession>;
    /**
     * Close the sessions and the plugins. Then check the fake model. A reply without a request fails the test, also
     * when the test catches the rejection. A second call gives the same promise.
     */
    readonly close: () => Promise<void>;
  }

  /**
   * The plain data of a round, for `round.before` and `round.retry`. The host makes the functions of the event. The
   * model of the round is the model of the session, as in a turn.
   */
  export interface TestRound {
    readonly context: readonly Block[];
    /**
     * The context window of the round. `null` gives a round with no known window. Without it, the round has the
     * window of the model of the session.
     */
    readonly window?: number | null;
    readonly inputTokens?: number | null;
    readonly system?: string;
    readonly tools?: readonly ToolDefinition[];
    readonly settings?: Settings;
  }

  /** The event of each hook point for `run`, as plain data. */
  export interface HookEvents {
    readonly "tool.before": { readonly call: ToolCall };
    readonly "tool.after": {
      readonly call: ToolCall;
      /** The result of the call. The host stores each media item, as for the result of a tool. */
      readonly result: {
        readonly text: string;
        readonly isError: boolean;
        readonly media?: readonly ToolMedia[];
        readonly display?: readonly DisplayBlock[];
      };
    };
    readonly "round.before": TestRound;
    readonly "round.retry": TestRound & {
      readonly failure: { readonly kind: RoundFailureKind };
      readonly retries?: number;
    };
    readonly "round.after": {
      readonly text: string;
      readonly finishReason?: FinishReason | null;
      readonly continues?: number;
    };
    readonly "input.before": {
      readonly source: InputSource;
      readonly kind: InputKind;
      /** The blocks of the input. The host stores each media item, and the handlers get it as a media block. */
      readonly blocks: readonly (Block | ToolMedia)[];
    };
    readonly "prompt.build": { readonly sections: Readonly<Record<string, string>> };
  }

  /** The plan of a round as the host keeps it. */
  export interface RoundPlan {
    readonly replace?: { readonly head: readonly Block[]; readonly keep: number };
    /** The id of the model of the round. */
    readonly model?: string;
    readonly settings?: Settings;
  }

  /** The decision of the host at each hook point, after each handler ran. */
  export interface HookResults {
    readonly "tool.before": "run" | { readonly block: string };
    readonly "tool.after": ToolOutcome;
    readonly "round.before": RoundPlan;
    readonly "round.retry": RoundPlan | undefined;
    readonly "round.after": "proceed" | "stop";
    readonly "input.before":
      | "keep"
      | "remove"
      | { readonly replace: { readonly blocks: readonly (Block | TestMedia)[] } };
    readonly "prompt.build": { readonly sections: Readonly<Record<string, string>> };
  }

  /** A media item that the host gives back, with its bytes from the store. */
  export interface TestMedia {
    readonly mimeType: string;
    readonly size: number;
    readonly bytes: Uint8Array;
  }

  /** The result of a tool call. */
  export interface ToolOutcome {
    readonly text: string;
    readonly isError: boolean;
    readonly media: readonly TestMedia[];
    /** What a chat shows in place of the text. */
    readonly display: readonly DisplayBlock[];
  }

  /** The result of `call`. */
  export interface CallOutcome extends ToolOutcome {
    /** The live texts of the call, in order. */
    readonly output: readonly string[];
  }

  /** The options of an operation of a session. An abort of `signal` cancels it, and it rejects with the reason. */
  export interface OperationOptions {
    readonly signal?: AbortSignal;
  }

  /** A session of the host. */
  export interface TestSession {
    readonly id: SessionId;
    /** The conversation of the session. Each operation returns after the transcript got each update before its end. */
    readonly transcript: Transcript;
    /** Send `text` as a message of the user, and wait until the session is idle again. */
    readonly send: (text: string, options?: OperationOptions) => Promise<void>;
    /**
     * Run the hook point `point` with `event`, as a turn does, and return the decision of the host. A handler sees the
     * same event as in a turn. A `continue` answer of `round.after` adds its input to the session.
     */
    readonly run: <K extends keyof HookEvents>(
      point: K,
      event: HookEvents[K],
      options?: OperationOptions,
    ) => Promise<HookResults[K]>;
    /** Call the tool `tool` with `args`, as a turn does. */
    readonly call: (tool: string, args: unknown, options?: OperationOptions) => Promise<CallOutcome>;
    /** The settings of the session now. */
    readonly settings: SessionSettings;
    /** Save `settings` as the settings of the session. It fails while a turn runs or input waits. */
    readonly setSettings: (settings: SessionSettings) => Promise<void>;
    /** Close the session, and stop its background jobs. Its tools and its open questions end, and its cleanups run. */
    readonly close: () => Promise<void>;
  }
}
