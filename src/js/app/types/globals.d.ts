/** QuickJS encodes a string of byte values (0 to 255) as base64. */
declare function btoa(data: string): string;
/** Runs `callback` once after `ms` milliseconds, never inside this call. A missing, negative, or non-finite delay runs in the next pump. */
declare function setTimeout<A extends unknown[]>(callback: (...args: A) => void, ms?: number, ...args: A): number;
/** Runs `callback` every `ms` milliseconds until `clearInterval`. */
declare function setInterval<A extends unknown[]>(callback: (...args: A) => void, ms?: number, ...args: A): number;
/** Stops a timer. An unknown or fired id does nothing. */
declare function clearTimeout(id: number | undefined): void;
/** Stops a timer. It shares one id space with `clearTimeout`. */
declare function clearInterval(id: number | undefined): void;
