// Type checks of `yuke:test`. `tsc -p crates/js/tsconfig.json` runs them; nothing executes this file.

import { assert, rejects, test, throws } from "yuke:test";
import type * as Runtime from "../modules/runtime/test.ts";

/** `true` only when `A` and `B` are the same type. */
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;

/** A call that compiles only for `true`. */
declare function check<T extends true>(): void;

// The runtime module exports exactly the declared values, so the registry of the runner stays private.
check<Equal<keyof typeof Runtime, keyof typeof import("yuke:test")>>();

// `assert` narrows, so a test reads the fields of what `throws` and `rejects` return.
export async function narrow(): Promise<void> {
  const error = throws(() => JSON.parse("{"));
  assert(error instanceof SyntaxError);
  check<Equal<typeof error, SyntaxError>>();
  const reason = await rejects(Promise.reject(new RangeError("low")));
  // @ts-expect-error: a reason is unknown until a check narrows it.
  void reason.message;
}

// @ts-expect-error: a test takes no options.
test("a name", { timeout: 1 }, () => {});
