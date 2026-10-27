// The declaration of the public module `yuke:test`.

/**
 * Tests for `yuke test`. A test file registers its tests at the top level. The runner gives each file a fresh runtime,
 * and it runs the tests of the file one by one, in the order of their registration.
 * - A test passes when its function returns, or when its promise fulfills.
 * - A test fails when it throws, when its promise rejects, or when the runtime reports a fault while it runs, such as
 *   a rejection that no code handles. A test awaits its work, so a fault belongs to it.
 * - A test that runs longer than 5 seconds stops the runtime of its file. The later tests of the file do not run.
 * - Each assertion throws an `Error` when it fails.
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
}
