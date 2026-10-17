// The globals of the runtime besides the language: the timers of crates/js/src/timers.rs, the classes of
// modules/internal/events.ts, and what QuickJS-NG adds.

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
}

declare var DOMException: {
  readonly prototype: DOMException;
  /** The default message is empty, and the default name is `Error`. */
  new (message?: string, name?: string): DOMException;
};

/** The clock of `Event.timeStamp`. */
declare var performance: {
  /** The milliseconds since the start of the runtime, with fractions. */
  readonly now: () => number;
};

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
  /** 2 (at the target) during a dispatch, 0 otherwise. A target has no tree, so it has no other phase. */
  readonly eventPhase: number;
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
