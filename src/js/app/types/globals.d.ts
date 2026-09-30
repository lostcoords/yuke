/** QuickJS encodes a string of byte values (0 to 255) as base64. */
declare function btoa(data: string): string;
/** Runs `callback` once after `ms` milliseconds, never inside this call. A missing, negative, or non-finite delay runs in the next pump. */
declare function setTimeout<A extends unknown[]>(callback: (...args: A) => void, ms?: number, ...args: A): number;
// A callback with one ignored parameter, such as a promise's `resolve`, runs with no arguments.
declare function setTimeout(callback: (_: void) => void, ms?: number): number;
/** Runs `callback` every `ms` milliseconds until `clearInterval`. */
declare function setInterval<A extends unknown[]>(callback: (...args: A) => void, ms?: number, ...args: A): number;
/** Stops a timer. An unknown or fired id does nothing. */
declare function clearTimeout(id: number | undefined): void;
/** Stops a timer. It shares one id space with `clearTimeout`. */
declare function clearInterval(id: number | undefined): void;
/** Posts the values as one `debug` notification from the source "console". A debug line never toasts: it shows in the notification history, in `yuke check`, and in `yuke.log`. */
declare function print(...values: unknown[]): void;
/** Posts the values as one notification from the source "console". `log` and `debug` post at the `debug` level; `info`, `warn`, and `error` post at their own level. */
declare var console: {
  log(...values: unknown[]): void;
  debug(...values: unknown[]): void;
  info(...values: unknown[]): void;
  warn(...values: unknown[]): void;
  error(...values: unknown[]): void;
};
