// The globals of the runtime besides the language: the timers of crates/js/src/timers.rs, and what QuickJS-NG adds.

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

/** The error of the web platform that QuickJS-NG adds, for example an `AbortError`. */
declare class DOMException extends Error {
  constructor(message?: string, name?: string);
  readonly code: number;
}
