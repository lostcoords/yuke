// The globals of the runtime besides the language: the timers of crates/js/src/timers.rs, the classes and objects of
// modules/internal/web.ts, and what QuickJS-NG adds.

/** The id of a timer. `setTimeout` and `setInterval` share one id space. */
type TimerId = number;

/** Run `callback` once after `delay` milliseconds with `args`. A missing, negative, or not finite delay is 0. */
declare function setTimeout<A extends unknown[]>(callback: (...args: A) => void, delay?: number, ...args: A): TimerId;
// biome-ignore lint/suspicious/noConfusingVoidType: a callback with one ignored parameter, such as the `resolve` of a promise, runs with no arguments.
declare function setTimeout(callback: (_: void) => void, delay?: number): TimerId;
/** Run `callback` every `delay` milliseconds until `clearInterval`. */
declare function setInterval<A extends unknown[]>(callback: (...args: A) => void, delay?: number, ...args: A): TimerId;
/** Stop a timer. An unknown id does nothing. */
declare function clearTimeout(id?: TimerId): void;
/** Stop a timer. An unknown id does nothing. */
declare function clearInterval(id?: TimerId): void;

/** Report `error` as a fault of the runtime without a throw, as the web `reportError` does. */
declare function reportError(error: unknown): void;

/** The error of the web platform that QuickJS-NG adds, for example an `AbortError` or a `TimeoutError`. */
interface DOMException extends Error {
  readonly name: string;
  readonly message: string;
  /** The legacy code of the name, for example 20 for `AbortError`, or 0. */
  readonly code: number;
  readonly INDEX_SIZE_ERR: 1;
  readonly DOMSTRING_SIZE_ERR: 2;
  readonly HIERARCHY_REQUEST_ERR: 3;
  readonly WRONG_DOCUMENT_ERR: 4;
  readonly INVALID_CHARACTER_ERR: 5;
  readonly NO_DATA_ALLOWED_ERR: 6;
  readonly NO_MODIFICATION_ALLOWED_ERR: 7;
  readonly NOT_FOUND_ERR: 8;
  readonly NOT_SUPPORTED_ERR: 9;
  readonly INUSE_ATTRIBUTE_ERR: 10;
  readonly INVALID_STATE_ERR: 11;
  readonly SYNTAX_ERR: 12;
  readonly INVALID_MODIFICATION_ERR: 13;
  readonly NAMESPACE_ERR: 14;
  readonly INVALID_ACCESS_ERR: 15;
  readonly VALIDATION_ERR: 16;
  readonly TYPE_MISMATCH_ERR: 17;
  readonly SECURITY_ERR: 18;
  readonly NETWORK_ERR: 19;
  readonly ABORT_ERR: 20;
  readonly URL_MISMATCH_ERR: 21;
  readonly QUOTA_EXCEEDED_ERR: 22;
  readonly TIMEOUT_ERR: 23;
  readonly INVALID_NODE_TYPE_ERR: 24;
  readonly DATA_CLONE_ERR: 25;
}

declare var DOMException: {
  readonly prototype: DOMException;
  /** The default message is empty, and the default name is `Error`. */
  new (message?: string, name?: string): DOMException;
  readonly INDEX_SIZE_ERR: 1;
  readonly DOMSTRING_SIZE_ERR: 2;
  readonly HIERARCHY_REQUEST_ERR: 3;
  readonly WRONG_DOCUMENT_ERR: 4;
  readonly INVALID_CHARACTER_ERR: 5;
  readonly NO_DATA_ALLOWED_ERR: 6;
  readonly NO_MODIFICATION_ALLOWED_ERR: 7;
  readonly NOT_FOUND_ERR: 8;
  readonly NOT_SUPPORTED_ERR: 9;
  readonly INUSE_ATTRIBUTE_ERR: 10;
  readonly INVALID_STATE_ERR: 11;
  readonly SYNTAX_ERR: 12;
  readonly INVALID_MODIFICATION_ERR: 13;
  readonly NAMESPACE_ERR: 14;
  readonly INVALID_ACCESS_ERR: 15;
  readonly VALIDATION_ERR: 16;
  readonly TYPE_MISMATCH_ERR: 17;
  readonly SECURITY_ERR: 18;
  readonly NETWORK_ERR: 19;
  readonly ABORT_ERR: 20;
  readonly URL_MISMATCH_ERR: 21;
  readonly QUOTA_EXCEEDED_ERR: 22;
  readonly TIMEOUT_ERR: 23;
  readonly INVALID_NODE_TYPE_ERR: 24;
  readonly DATA_CLONE_ERR: 25;
};

/** Run `callback` as a microtask: after the current script, before the next timer. */
declare function queueMicrotask(callback: () => void): void;
/** The binary string of the base64 text `data`. A text that is not base64 throws a `DOMException`. */
declare function atob(data: string): string;
/** The base64 text of the binary string `data`. A character above U+00FF throws a `DOMException`. */
declare function btoa(data: string): string;

/** The clock of the runtime. */
declare var performance: {
  /** The epoch time of the start of the runtime, in milliseconds. */
  readonly timeOrigin: number;
  /** The milliseconds since `timeOrigin`, with fractions, on a clock that never goes back. */
  readonly now: () => number;
  readonly toJSON: () => { readonly timeOrigin: number };
};

/**
 * The entries of a script for the operator, on stderr in the app. An entry is never a notice: use `notify` of a
 * context for that. Each call formats `data` with `%s`, `%d`, `%i`, `%f`, `%o`, `%O`, `%c`, and `%%`, and it never throws.
 */
declare var console: {
  /** A debug entry, as `debug`. */
  log: (...data: unknown[]) => void;
  debug: (...data: unknown[]) => void;
  info: (...data: unknown[]) => void;
  warn: (...data: unknown[]) => void;
  error: (...data: unknown[]) => void;
};

/** An encoder of text to UTF-8. */
declare class TextEncoder {
  constructor();
  readonly encoding: "utf-8";
  /** The UTF-8 bytes of `input`. A lone surrogate becomes U+FFFD. */
  encode(input?: string): Uint8Array;
  /**
   * Write as many whole UTF-8 characters of `source` as fit in `destination`. `read` counts the UTF-16 units of `source`
   * that went into `destination`, and `written` counts the bytes. A resizable buffer throws a `TypeError`.
   */
  encodeInto(source: string, destination: Uint8Array): { read: number; written: number };
}

/** The labels of UTF-8 in the Encoding Standard. The runtime also accepts them in another case or with ASCII spaces. */
type Utf8Label = "unicode-1-1-utf-8" | "unicode11utf8" | "unicode20utf8" | "utf-8" | "utf8" | "x-unicode20utf8";

/** A decoder of UTF-8 bytes to text. yuke decodes UTF-8 only: another encoding label throws a `RangeError`. */
declare class TextDecoder {
  constructor(label?: Utf8Label, options?: { fatal?: boolean | undefined; ignoreBOM?: boolean | undefined });
  readonly encoding: "utf-8";
  /** Whether an invalid sequence throws a `TypeError`. Otherwise it becomes U+FFFD. */
  readonly fatal: boolean;
  /** Keep a byte order mark at the start of the text. Otherwise the decode removes it. */
  readonly ignoreBOM: boolean;
  /**
   * The text of `input`. With `stream: true`, an incomplete sequence at the end waits for the next call. A detached
   * buffer has no bytes, and a resizable buffer throws a `TypeError`.
   */
  decode(input?: ArrayBuffer | SharedArrayBuffer | ArrayBufferView, options?: { stream?: boolean | undefined }): string;
}

/** The flags of a new event. Each flag is `false` when it is missing. */
interface EventInit {
  bubbles?: boolean | undefined;
  cancelable?: boolean | undefined;
  composed?: boolean | undefined;
}

/** The flags of a new custom event, and its `detail`. */
interface CustomEventInit<T = unknown> extends EventInit {
  detail?: T | undefined;
}

/** An event that an `EventTarget` dispatches to its listeners. */
declare class Event {
  /** A missing `type` throws a `TypeError`. */
  constructor(type: string, eventInit?: EventInit);
  readonly type: string;
  /** The target of the last dispatch, or `null` before the first dispatch. */
  readonly target: EventTarget | null;
  /** The target whose listeners run now, or `null` outside a dispatch. */
  readonly currentTarget: EventTarget | null;
  /** `AT_TARGET` (2) during a dispatch, `NONE` (0) otherwise. A target has no tree, so it has no other phase. */
  readonly eventPhase: number;
  static readonly NONE: 0;
  static readonly CAPTURING_PHASE: 1;
  static readonly AT_TARGET: 2;
  static readonly BUBBLING_PHASE: 3;
  readonly NONE: 0;
  readonly CAPTURING_PHASE: 1;
  readonly AT_TARGET: 2;
  readonly BUBBLING_PHASE: 3;
  readonly bubbles: boolean;
  readonly cancelable: boolean;
  readonly composed: boolean;
  /** Whether a listener called `preventDefault` on a cancelable event. */
  readonly defaultPrevented: boolean;
  /** `true` for an event that the runtime dispatches, for example the `abort` event of a signal. */
  readonly isTrusted: boolean;
  /** The `performance.now()` time of the construction. */
  readonly timeStamp: number;
  /** The current target in an array during a dispatch, an empty array otherwise. */
  composedPath(): EventTarget[];
  /** Stop the dispatch after this pass. A dispatch has two passes: the capture listeners, then the other listeners. */
  stopPropagation(): void;
  /** Stop the dispatch after this listener. */
  stopImmediatePropagation(): void;
  /** Cancel a cancelable event. A passive listener cannot cancel it. */
  preventDefault(): void;
}

/** An event with a `detail` value. */
declare class CustomEvent<T = unknown> extends Event {
  constructor(type: string, eventInit?: CustomEventInit<T>);
  /** The `detail` of the init, or `null`. */
  readonly detail: T | null;
}

/** A listener function. Its `this` is the target. */
type EventListener = (this: EventTarget, event: Event) => void;

/** A listener object. Each call reads `handleEvent` again, and its `this` is the object. */
interface EventListenerObject {
  handleEvent: (this: EventListenerObject, event: Event) => void;
}

type EventListenerOrEventListenerObject = EventListener | EventListenerObject;

interface EventListenerOptions {
  /** Run the listener in the capture pass, before the other listeners. A remove must give the same flag. */
  capture?: boolean | undefined;
}

interface AddEventListenerOptions extends EventListenerOptions {
  /** Remove the listener before its first call. */
  once?: boolean | undefined;
  /** The listener cannot cancel the event. */
  passive?: boolean | undefined;
  /** Remove the listener when this signal aborts. An aborted signal adds no listener. */
  signal?: AbortSignal | undefined;
}

/** A target of events. A dispatch is synchronous: each listener runs before `dispatchEvent` returns. */
declare class EventTarget {
  constructor();
  /**
   * Add `callback` for events of `type`. A second add with the same type, callback, and capture flag does nothing. A
   * throw of a listener goes to `reportError`, and the next listener runs.
   */
  addEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions,
  ): void;
  /** Remove the listener with this type, callback, and capture flag. */
  removeEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | EventListenerOptions,
  ): void;
  /**
   * Dispatch `event` to the listeners. Returns `false` when a listener canceled it. An event in a dispatch throws a
   * `DOMException` named `InvalidStateError`.
   */
  dispatchEvent(event: Event): boolean;
}

/** The state of one abort. Its owner aborts it: an `AbortController`, a static method, or yuke. */
interface AbortSignal extends EventTarget {
  readonly aborted: boolean;
  /** `undefined` before the abort. After it, the value that the abort gave, or a `DOMException` named `AbortError`. */
  readonly reason: unknown;
  /** Throw `reason` when the signal has aborted. */
  throwIfAborted: (this: AbortSignal) => void;
  /** One handler of the `abort` event. A handler that a script sets after the abort does not run. */
  onabort: ((this: AbortSignal, event: Event) => unknown) | null;
}

declare var AbortSignal: {
  readonly prototype: AbortSignal;
  /** A signal that has aborted with `reason`. `undefined` gives a `DOMException` named `AbortError`. */
  abort: (reason?: unknown) => AbortSignal;
  /** A signal that aborts with the reason of the first of `signals` that aborts. */
  any: (signals: Iterable<AbortSignal>) => AbortSignal;
  /**
   * A signal that aborts with a `DOMException` named `TimeoutError` after `milliseconds`. The fraction is dropped.
   * A value that is not finite or not in 0..2^53-1 throws a `TypeError`.
   */
  timeout: (milliseconds: number) => AbortSignal;
};

/** The owner of one signal. Give `signal` to the work, and call `abort` to stop the work. */
declare class AbortController {
  constructor();
  /** Each read gives the same signal. */
  readonly signal: AbortSignal;
  /** Abort the signal with `reason`, once. `undefined` gives a `DOMException` named `AbortError`. */
  abort(reason?: unknown): void;
}
